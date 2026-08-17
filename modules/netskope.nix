{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.netskope;
  enr = cfg.enrollment;
  optStr = s: if s == null then "" else s;
  enrollmentConfigured = cfg.tenantHost != "" && enr.orgKeyFile != null;

  # The system trust store in OpenSSL's hashed-directory layout.
  #
  # The client asks OpenSSL to verify peers with a CApath of /etc/ssl/certs and NO
  # CAfile -- verified on a real host: "peer Set SSL CA locations, file: , dir:
  # /etc/ssl/certs" (it picks a CAfile only on Fedora/RHEL, gated on
  # /etc/{fedora,redhat}-release). A CApath is looked up through
  # <subject-hash>.<seq> symlinks, which Debian and friends generate; NixOS'
  # /etc/ssl/certs holds only ca-bundle.crt and ca-certificates.crt and no hashed
  # links, so the client finds ZERO trust anchors and every TLS handshake fails:
  #
  #   peer cert verify err: 19, errMsg: self-signed certificate in certificate
  #   chain, depth: 2, subject: /OU=GlobalSign Root CA - R3/...
  #   curl_easy_perform failed, code 60
  #
  # That is what broke enrollment (and every config/branding fetch the daemon
  # makes). SSL_CERT_DIR, SSL_CERT_FILE and CURL_CA_BUNDLE are all ignored -- the
  # path is compiled in -- so the fix is to give the client's units a rehashed
  # /etc/ssl/certs via BindReadOnlyPaths, leaving the rest of the system alone.
  #
  # Derived from security.pki.caBundle, so `trustCA`'s tenant CA is included
  # automatically. Both bundle files are kept alongside the hashed links, making
  # this a superset of the real directory rather than a replacement for it.
  caCertDir = pkgs.runCommandLocal "netskope-ca-hashed" { } ''
    mkdir -p $out
    cd $out
    # `openssl rehash` skips any file that does not hold exactly one certificate, so
    # cut strictly between the BEGIN/END markers -- the human-readable labels the
    # bundle puts between certificates would otherwise ride along and be rejected.
    awk '/-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("ca-%04d.pem", n) }
         f { print > f }
         /-----END CERTIFICATE-----/ { f = "" }' ${config.security.pki.caBundle}
    ${pkgs.openssl.bin}/bin/openssl rehash $out
    ln -s ${config.security.pki.caBundle} ca-bundle.crt
    ln -s ${config.security.pki.caBundle} ca-certificates.crt
  '';

  # The helper commands the daemon shells out to, at the one path it looks for them.
  #
  # It resolves them as /usr/sbin/<name>, NOT through PATH. That was established the
  # hard way, by running the daemon against a throwaway copy of its app dir and
  # watching nsdebuglog: with iproute2 on the unit's PATH it still logged "Command ip
  # not found!", and it still did with /usr/bin/ip in place; adding /usr/sbin/ip is
  # what silenced it and let "reset stAgent route rules" run. (systemd.services.*.path
  # is therefore useless here -- it was tried, shipped, and did nothing.)
  #
  # Deliberately absent: update-ca-certificates. Its presence would send the CA
  # installer down its Debian branch, into a /usr/local/share/ca-certificates that
  # does not exist here -- see the CA notes on stagentd.service.
  fhsTools = pkgs.runCommandLocal "netskope-fhs-tools" { } ''
    mkdir -p $out
    # Steering: the client drives its TUN device with `ip route`/`ip rule` and
    # programs the mangle table.
    ln -s ${pkgs.iproute2}/bin/ip $out/ip
    ln -s ${pkgs.iptables}/bin/iptables $out/iptables
    ln -s ${pkgs.iptables}/bin/ip6tables $out/ip6tables
    # Device make/model/serial reported to the tenant; falls back to sysfs, but the
    # daemon probes for it on every config cycle.
    ln -s ${pkgs.dmidecode}/bin/dmidecode $out/dmidecode
    # Flushing the DNS cache when steering changes.
    ln -s ${config.systemd.package}/bin/resolvectl $out/resolvectl
  '';

  # Stand-in for the distro tool that rebuilds the system trust store from its
  # anchors directory -- see the CA-install notes on stagentd.service below.
  caTrustShim = pkgs.writeShellScript "netskope-update-ca-trust" ''
    # Nothing to regenerate: this system's trust store is built from
    # security.pki.certificateFiles at activation, not from a mutable anchors dir.
    # Succeeding here is the point -- it is what lets the client finish its config
    # update. Trusting the tenant CA system-wide stays an explicit opt-in via
    # services.netskope.trustCA.
    echo "netskope: CA anchors updated; system trust is declarative (services.netskope.trustCA)" >&2
    exit 0
  '';
in
{
  options.services.netskope = {
    enable = lib.mkEnableOption "the Netskope client daemon (stAgentSvc)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/netskope-client.nix {
        inherit (cfg) enableTray tenant hash;
        url = cfg.sourceUrl;
      };
      defaultText = lib.literalExpression "netskope-client (built from tenant/hash/sourceUrl)";
      description = ''
        The netskope-client package to run. By default it is built from the
        `tenant`/`hash`/`sourceUrl` options; override to supply a custom build
        (e.g. `pkgs.netskope-client.override { srcOverride = ./NSClient.run; }`).
        The argument is `srcOverride`, not `src`, because callPackage would
        auto-fill an argument named `src` from nixpkgs' throwing `pkgs.src` alias.
      '';
    };

    tenant = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "lselectric";
      description = ''
        Short tenant name. When set, the installer is fetched (no auth) from
        https://download-<tenant>.goskope.com/dlr/linux/get using `hash`, and
        `tenantHost` defaults to addon-<tenant>.goskope.com. Leave null to supply
        the installer offline (requireFile) or via a custom `package`.
      '';
    };

    hash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sha256-lOAsV+/zV1KNZBraDw8qa7nL4SDu0GH3who7fgLhQTI=";
      description = ''
        Hash (SRI or sha256 hex) of the fetched NSClient.run. Required when `tenant`
        or `sourceUrl` is set. It changes when Netskope pushes a new client version
        to your tenant -- update it then (e.g. `nix store prefetch-file`).
      '';
    };

    sourceUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Override the installer download URL (e.g. an internal mirror). Requires
        `hash`; takes precedence over `tenant`.
      '';
    };

    statePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/netskope";
      description = ''
        Directory holding all of the client's mutable state: its device identity
        (`.mid`, `provisioning`), its config (`nsconfig.json`, `nsuser.conf`), the
        enrollment result (`nsbranding.json`), and the `data/` + `logs/` subdirs.

        The client hard-codes /opt/netskope/stagent and writes state there, so the
        module keeps the real directory at `''${statePath}/app` and bind-mounts it
        onto that path (see netskope-setup.service for why it must be a bind mount
        and not a symlink).

        On an impermanent / tmpfs-root host this is the one and only path to
        persist -- e.g. with nix-community/impermanence:

          environment.persistence."/persist".directories = [ "/var/lib/netskope" ];

        Nothing under /opt needs persisting; those files are refreshed from the Nix
        store on every activation. Without persistence the client loses its identity
        and enrollment on every boot and re-registers as a brand-new device.
      '';
    };

    enableTray = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build and run the per-user tray UI: the `stagentapp` (watchdog) and `stagentui`
        (tray icon) user services, plus a launcher entry. Disable on headless hosts to
        drop the heavy GTK/WebKit closure.
      '';
    };

    trustCA = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Trust the tenant's SSL-inspection CA system-wide, so that browsers, curl, git
        and everything else keep working once steering is live. This is a MITM
        certificate, so it is opt-in and deliberately off by default.

        No certificate file is required. The enrolled client fetches its tenant CA at
        runtime and writes it to `''${statePath}/ca-anchors/`, and this option makes
        the system trust whatever it finds there -- so it follows CA rotation on its
        own, and nobody has to commit a tenant certificate to their configuration.

        The mechanism is a bind mount over /etc/ssl/certs, because a NixOS trust store
        is assembled at build time from `security.pki.certificateFiles` and a file the
        client only fetches at runtime can never feed it. See netskope-ca-trust.service.

        `caCertFile` remains available for the case where you do have the certificate
        at evaluation time and would rather bake it in.
      '';
    };

    caCertFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./nstenantcert.crt";
      description = ''
        Optional: a Netskope CA (PEM) to bake into the system trust store at build
        time, in addition to whatever `trustCA` picks up at runtime.

        You do not need this. `trustCA` alone trusts the certificate the client itself
        downloads, which is the only copy most hosts will ever have. Set this only if
        you want the CA trusted before the client has ever enrolled, or you would
        rather pin it declaratively -- and note it must be readable at *evaluation*
        time, so under flakes it has to live inside the flake.

        To obtain a copy for that purpose: an enrolled host has it at
        `''${statePath}/ca-anchors/nstenantcert.crt` (SSL inspection) and
        `nscacert.crt` (the Netskope root); otherwise the tenant admin console. The
        client's own encrypted copies under `''${statePath}/app/data/*.pem.enc` are
        not directly usable.
      '';
    };

    tenantHost = lib.mkOption {
      type = lib.types.str;
      default = if cfg.tenant == null then "" else "${cfg.tenant}.goskope.com";
      defaultText = lib.literalExpression ''"<tenant>.goskope.com" when `tenant` is set, else ""'';
      example = "<tenant>.goskope.com";
      description = ''
        Tenant hostname -- the client's -H/--tenantHostname. This is the BARE tenant
        host (`corp.goskope.com`), NOT the addon host: the client derives the addon
        host itself by prefixing `addon-`. Passing `addon-corp.goskope.com` here
        makes it look up `addon-addon-corp.goskope.com`, which resolves nothing and
        fails enrollment with a DNS error ("Could not resolve hostname") -- verified
        on a real host, and asserted against below, because Windows deployment
        strings put the *addon* host in `host=` and are the obvious thing to copy.

        Defaults to <tenant>.goskope.com when `tenant` is set; override for regional
        variants (eu./de./au.goskope.com). Leave empty to package the client without
        declarative enrollment.
      '';
    };

    enrollment = {
      orgKeyFile = lib.mkOption {
        # NB: string, not path -- a `path` would be copied into the world-readable
        # /nix/store when interpolated. This is an absolute path resolved at runtime.
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/secrets/netskope-orgkey";
        description = ''
          Absolute path to a runtime file containing the organization key -- the
          value deployed as `token=` on Windows; the client's -o/--orgkey. Loaded
          via systemd credentials at runtime; the key never enters the Nix store.
        '';
      };

      authTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/secrets/netskope-authtoken";
        description = ''
          Absolute path to a runtime file containing the secure-enrollment auth
          token -- Windows `enrollauthtoken=`; the client's -a/--enroll-auth-token.
          Loaded via systemd credentials at runtime.
        '';
      };

      encryptTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional absolute path to a runtime file containing the secure-enrollment
          encrypt token (-e/--enroll-encrypt-token), if your tenant requires it.
          Loaded via systemd credentials.
        '';
      };

      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "user@example.com";
        description = ''
          User email for email-mode enrollment (-m/--email). Set either this or
          `upn`: an org key + auth token alone is NOT enough. With both unset the
          client silently picks UPN mode, tries to derive the AD domain by running
          `realm list`, and fails ("Can't find domain from: realm list") on any host
          that is not domain-joined -- so on a typical NixOS box this is the option
          that makes enrollment work. Verified against a live tenant.
        '';
      };

      upn = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          UPN for enrollment (-u/--upn), as an alternative to `email`. Note that UPN
          mode resolves the AD domain through realmd's `realm list`, so it needs a
          domain-joined host with realmd installed; prefer `email` otherwise.
        '';
      };
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start the daemon (and the tray) at boot. Set to false to leave the client
        installed but dormant, brought up on demand with `systemctl start stagentd`.

        This is the escape hatch for bringing steering up on a machine you depend on.
        The moment the client's tunnel connects it captures all web traffic, and if
        that goes wrong the recovery is a reboot into an older generation: the tenant
        can forbid `stAgentCli disable` (allowClientDisabling=false), and the daemon
        restores its rules on restart. With autoStart = false the same mistake is one
        `systemctl stop stagentd` away, and a reboot always comes up clean.

        Note that a dormant client is also an unenrolled and un-updated one -- nothing
        polls the tenant until you start it.
      '';
    };

    autoUpdate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow the client to self-update. Off by default and effectively unsupported
        on NixOS: the client lives in the immutable /nix/store and cannot replace
        its own binaries. Update by bumping the packaged NSClient.run instead.
        (Windows deployments use autoupdate=on; on NixOS that responsibility moves
        to the Nix package.)
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ------------------------------------------------------------------
    # SCOPE. Packaging (#5), writable-state relocation (#7), CA trust (#8), and
    # declarative token/org-key enrollment (#6) are implemented. Remaining:
    #
    #   #9   option-schema polish (client source: requireFile / URL / tenant) + a
    #        NixOS VM test
    #   #10  build + runtime verification on a real Nix host
    #
    # The enrollment handshake has now been exercised against the live tenant on a
    # real host (installerutil run against a throwaway copy of the app dir in a user
    # namespace, so no system state was touched): it returns "Successfully downloaded
    # branding file by email id" and writes nsbranding.json.enc. Getting there fixed
    # four defects in this module, each documented at its site: the addon- prefix in
    # tenantHost, the empty MyRunFileName, the missing email/upn, and the unusable
    # OpenSSL CApath. What remains unverified is what happens AFTER the branding file
    # lands -- the daemon's own secure-enrollment (usercert) and steering setup.
    # ------------------------------------------------------------------

    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "services.netskope: Netskope ships no Linux client for ${pkgs.stdenv.hostPlatform.system} (x86_64-linux only).";
      }
      {
        assertion = (enr.orgKeyFile != null) -> (cfg.tenantHost != "");
        message = "services.netskope.enrollment.orgKeyFile is set but services.netskope.tenantHost is empty — set the tenant host.";
      }
      {
        # Catches the copy-from-Windows mistake: `host=addon-corp.goskope.com` in a
        # Windows deployment string is the addon host, but the client prefixes
        # `addon-` itself, so passing it through yields addon-addon-corp.goskope.com
        # and enrollment dies on DNS. Fail at eval instead.
        assertion = !(lib.hasPrefix "addon-" cfg.tenantHost);
        message = "services.netskope.tenantHost is \"${cfg.tenantHost}\" — drop the `addon-` prefix and use the bare tenant hostname (e.g. corp.goskope.com). The client derives the addon host itself, so this would resolve addon-${cfg.tenantHost} and fail enrollment with \"Could not resolve hostname\".";
      }
      {
        assertion = enrollmentConfigured -> (enr.email != null || enr.upn != null);
        message = "services.netskope.enrollment needs `email` (or `upn`) alongside orgKeyFile/authTokenFile. With neither set the client falls back to UPN mode and resolves the AD domain via `realm list`, which fails on a host that is not domain-joined — enrollment then never completes.";
      }
    ];

    warnings =
      lib.optional cfg.autoUpdate "services.netskope.autoUpdate has no real effect on NixOS: the client cannot self-update the immutable store. Bump the packaged NSClient.run instead."
      ++
        lib.optional
          (
            config.networking.firewall.enable
            && builtins.elem config.networking.firewall.checkReversePath [
              true
              "strict"
            ]
          )
          ''
            services.netskope is enabled with networking.firewall.checkReversePath set to strict.
            Steering is asymmetric -- replies come back in on the sta0 tunnel while the route to
            their source is via the physical interface -- so a strict reverse-path filter DROPs
            every steered reply. Measured on a real host: DNS, TCP and TLS all dead within ~27s
            of the tunnel coming up, with no way back short of killing the daemon. This module
            defaults the option to "loose"; something in your configuration has forced it back.
          ''
      ++ lib.optional (cfg.enable && !cfg.trustCA) ''
        services.netskope.trustCA is off. Once steering is live the tenant re-signs every
        HTTPS connection with its own CA, so browsers, curl and git will fail with
        "self-signed certificate in certificate chain" until that CA is trusted. Setting
        trustCA = true is enough -- it trusts the certificate the client downloads for
        itself, with no certificate file to supply.
      '';

    environment.systemPackages = [
      cfg.package
    ]
    # Launcher entry for the tray UI. Upstream install.sh drops this into
    # /usr/share/applications; here it rides in via systemPackages, which
    # XDG_DATA_DIRS already covers. Its Exec/Icon point at the bind-mounted /opt path,
    # so no rewriting is needed. Deliberately NOT installed into /etc/xdg/autostart:
    # the UI's lifecycle belongs to the stagentui user service below, and an autostart
    # entry would race it for a second instance.
    ++ lib.optional cfg.enableTray (
      pkgs.runCommandLocal "netskope-stagentui-desktop" { } ''
        install -Dm644 ${cfg.package}/opt/netskope/stagent/stagentui.desktop \
          "$out/share/applications/stagentui.desktop"
      ''
    );

    # Optional build-time half of CA trust: only when someone has the certificate at
    # evaluation time and wants it pinned. The runtime half below is what actually
    # makes `trustCA` work for everyone else.
    security.pki.certificateFiles = lib.mkIf (cfg.caCertFile != null) [ cfg.caCertFile ];

    # Runtime CA trust (issue #8), the half that does not need a certificate in your
    # configuration.
    #
    # Netskope's SSL inspection re-signs every HTTPS connection once steering is live
    # -- verified against a live tenant: the issuer becomes
    # CN=ns-swg.ca.<tenant>.goskope.com, curl against the system trust store fails
    # with "self-signed certificate in certificate chain" (60), and the same request
    # with the tenant CA returns 200. So without this the client works and the rest of
    # the desktop does not.
    #
    # The awkward part is that a NixOS trust store is assembled at BUILD time, from
    # security.pki.certificateFiles, while the only copy of the tenant CA most hosts
    # will ever have is fetched by the client at RUNTIME (it lands in
    # ''${statePath}/ca-anchors -- see stagentd.service). A runtime file cannot feed a
    # build-time bundle, and under flakes it cannot even be read at eval ("access to
    # absolute path ... is forbidden in pure evaluation mode"). Requiring every user to
    # copy their tenant's certificate into their own configuration is not a solution.
    #
    # So: assemble the bundle at runtime -- the system's own CA bundle plus whatever
    # the client has fetched -- and bind-mount it over /etc/ssl/certs. That follows CA
    # rotation for free, since the client rewrites the anchors and this unit is
    # retriggered by a path unit when it does.
    systemd.services.netskope-ca-trust = lib.mkIf cfg.trustCA {
      description = "Trust the Netskope tenant CA system-wide";
      wantedBy = [ "multi-user.target" ];
      requires = [ "netskope-setup.service" ];
      after = [ "netskope-setup.service" ];
      before = [ "stagentd.service" ];
      unitConfig.RequiresMountsFor = cfg.statePath;
      path = [ pkgs.util-linux ];
      # No RemainAfterExit: the unit must be able to run again when the path unit
      # below fires on a CA rotation, and the bind mount outlives the process anyway.
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        dir="${cfg.statePath}/ca-trust"
        install -d -m 0755 "$dir"

        # Start from the system bundle, then append the client's anchors. Written to a
        # temporary name and moved into place so nothing ever observes a half-written
        # trust store -- this directory is /etc/ssl/certs for the whole machine.
        : > "$dir/.bundle.tmp"
        cat ${config.security.pki.caBundle} >> "$dir/.bundle.tmp"
        for f in "${cfg.statePath}"/ca-anchors/*.crt; do
          [ -e "$f" ] || continue   # nothing fetched yet: bundle == system bundle
          printf '\n' >> "$dir/.bundle.tmp"
          cat "$f" >> "$dir/.bundle.tmp"
        done
        chmod 0644 "$dir/.bundle.tmp"
        cp "$dir/.bundle.tmp" "$dir/.certificates.tmp"
        mv -f "$dir/.bundle.tmp" "$dir/ca-bundle.crt"
        mv -f "$dir/.certificates.tmp" "$dir/ca-certificates.crt"

        # Also provide the hashed layout, for anything using this as an OpenSSL CApath
        # rather than a CAfile -- the Netskope client itself is one such consumer.
        rm -f "$dir"/*.pem "$dir"/*.0
        ${pkgs.gawk}/bin/awk -v d="$dir" '
          /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/ca-%04d.pem", d, n) }
          f { print > f }
          /-----END CERTIFICATE-----/ { f = "" }' "$dir/ca-bundle.crt"
        # stderr too: rehash warns about the two bundle files, which hold many certs
        # each and are meant to be skipped. Not worth a warning on every boot.
        ${pkgs.openssl.bin}/bin/openssl rehash "$dir" >/dev/null 2>&1

        # Mount last, and only once: if generation failed above, set -e means we never
        # get here and /etc/ssl/certs is left alone rather than replaced with rubble.
        if ! mountpoint -q /etc/ssl/certs; then
          mount --bind "$dir" /etc/ssl/certs
        fi
      '';
    };

    # The client rewrites its anchors when the tenant rotates its CA. Rebuild then,
    # rather than only at boot; the mount picks the new contents up in place.
    systemd.paths.netskope-ca-trust = lib.mkIf cfg.trustCA {
      description = "Watch for Netskope tenant CA rotation";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = "${cfg.statePath}/ca-anchors";
        Unit = "netskope-ca-trust.service";
      };
    };

    # NixOS' reverse-path filter has to be loosened or steering takes the whole
    # network down with it.
    #
    # networking.firewall.checkReversePath defaults to true, which installs
    #
    #   -A nixos-fw-rpfilter -m rpfilter --validmark -j RETURN
    #   ... -A nixos-fw-rpfilter -j DROP
    #
    # in mangle PREROUTING -- strict mode. Steering is asymmetric by construction:
    # packets leave through the sta0 tunnel device (fwmark 0x5 -> table 9 -> default
    # dev sta0) and their replies come back in on sta0, while the route to those
    # source addresses is via the physical interface. Strict rpfilter therefore DROPs
    # every reply.
    #
    # Measured on a real host, with the client steering: strict rpfilter took DNS,
    # TCP and TLS to zero within ~27s -- total loss, recoverable only by killing the
    # daemon -- while unsteered ICMP kept flowing, which is the signature of the
    # steered traffic specifically being dropped on the way back. The same run with
    # this set to loose held all three up for the full window.
    #
    # mkDefault, so a host that has thought about it can still say otherwise -- the
    # same approach nixpkgs' own tailscale module takes for the same reason.
    networking.firewall.checkReversePath = lib.mkDefault "loose";

    # Writable-state relocation (issue #7) and impermanence support.
    #
    # Two hard constraints come from the proprietary client:
    #
    #  1. It hard-codes /opt/netskope/stagent and both READS its shipped files and
    #     WRITES runtime state under that same path -- device identity (.mid,
    #     provisioning), config (nsconfig.json, nsuser.conf), the enrollment result
    #     (nsbranding.json), the data/ + logs/ subdirs, and the svc socket.
    #  2. Its IPC layer (NSCom2) authenticates peers by resolving the connecting
    #     process's /proc/<pid>/exe and matching it against a hard-coded allowlist of
    #     /opt/netskope/stagent/{stAgentApp,stAgentCli,stAgentUI,nsdiag,bwansvc}.
    #
    # (2) rules out the obvious packaging approach. Symlinking the binaries in from
    # the store makes /proc/<pid>/exe resolve to the store path, so stAgentSvc
    # rejects every peer -- "NSCOM2 invalid client connection from /nix/store/...",
    # "handleNewClient failed -8". The daemon still starts and looks healthy, but the
    # tray never appears and stAgentCli reports "Failed to connect to Netskope Client
    # service". The shipped files must be REAL FILES at the hard-coded path.
    #
    # Strategy: keep the real directory at ''${statePath}/app -- populated by copying
    # the shipped files out of the store, refreshed when the package changes -- and
    # bind-mount it onto /opt/netskope/stagent. A bind mount, unlike a symlink,
    # preserves the visible path, so /proc/<pid>/exe reads back as
    # /opt/netskope/stagent/... and the peer check passes.
    #
    # This is also what makes the module work unchanged on a tmpfs root: every
    # mutable file lives under the single statePath, so persisting that one directory
    # is all an impermanent host has to do, and /opt stays fully disposable. Reaching
    # state through the /opt bind mount has a second benefit -- a locked-down (0700)
    # statePath no longer blocks the per-user stAgentUI/stAgentCli from traversing
    # into data/ for nsusercert.p12, because they never walk the statePath itself.
    systemd.services.netskope-setup = {
      description = "Prepare /opt/netskope/stagent (Netskope state relocation)";
      wantedBy = [ "multi-user.target" ];
      before = [ "stagentd.service" ];
      path = [ pkgs.util-linux ]; # mount, mountpoint
      unitConfig.RequiresMountsFor = cfg.statePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        src="${cfg.package}/opt/netskope/stagent"
        app="${cfg.statePath}/app"
        dst="/opt/netskope/stagent"
        stamp="$app/.nix-generation"

        # Modes follow upstream install.sh, which does `chmod 755` on the app dir and
        # logs/ and `mkdir -p -m 755 data`. data/ must not be root-only: stAgentUI and
        # stAgentCli run as the logged-in user and read data/nsusercert.p12, and a
        # 0700 data/ fails them with EACCES.
        install -d -m 0755 "$app" "$app/data" "$app/logs"

        # Bind source for the daemon's CA anchors dir (see stagentd.service). Kept
        # beside the app dir rather than inside it, since it is not part of the
        # client's own tree, and 0755 so the tenant CA the client drops here can be
        # read back out for services.netskope.caCertFile.
        install -d -m 0755 "${cfg.statePath}/ca-anchors"

        # Refresh the shipped files whenever the package changes. Only names that came
        # from the store are removed, so the client's own state (.mid, provisioning,
        # nsconfig.json, nsbranding.json, ...) survives a version bump untouched.
        if [ "$(cat "$stamp" 2>/dev/null || true)" != "$src" ]; then
          for f in "$src"/*; do
            rm -rf "$app/$(basename "$f")"
          done
          cp -a "$src"/. "$app"/
          # Store files are read-only; the client rewrites some of them in place.
          chmod -R u+w "$app"
          printf %s "$src" > "$stamp"
        fi

        # Bind-mount onto the path the client hard-codes. Guarded so that a
        # nixos-rebuild switch which re-runs this unit does not stack mounts.
        install -d -m 0755 /opt/netskope "$dst"
        if ! mountpoint -q "$dst"; then
          mount --bind "$app" "$dst"
        fi
      '';
    };

    # Declarative token/org-key enrollment (issue #6).
    #
    # Mirrors install.sh: installerutil fetches the tenant branding/enrollment
    # config from a JSON envelope (TenantHostname + Orgkey + EnrollAuthToken), then
    # the daemon completes device enrollment. Secrets are read from root-only
    # systemd credential files at runtime -- their values never enter the unit
    # definition, the Nix store, or nixos-rebuild logs. Only created when a tenant
    # host and org key are configured.
    #
    # NOTE: the exact enrollment handshake is pending real-host verification (#10);
    # the option surface and secret handling are the settled part.
    systemd.services.netskope-enroll = lib.mkIf enrollmentConfigured {
      description = "Enroll the Netskope client with the ${cfg.tenantHost} tenant";
      wantedBy = [ "multi-user.target" ];
      requires = [ "netskope-setup.service" ];
      after = [
        "netskope-setup.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      before = [ "stagentd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # installerutil resolves its siblings relative to the app dir, and must be
        # the copy at this path (not the store) for the IPC peer check -- see
        # netskope-setup.service.
        WorkingDirectory = "/opt/netskope/stagent";
        # Without this every request the client makes fails TLS verification -- see
        # caCertDir above for why NixOS' /etc/ssl/certs is unusable as an OpenSSL
        # CApath.
        BindReadOnlyPaths = [ "${caCertDir}:/etc/ssl/certs" ];
        LoadCredential = [
          "orgkey:${enr.orgKeyFile}"
        ]
        ++ lib.optional (enr.authTokenFile != null) "authtoken:${enr.authTokenFile}"
        ++ lib.optional (enr.encryptTokenFile != null) "encrypttoken:${enr.encryptTokenFile}";
      };
      script = ''
        set -eu
        appPath=/opt/netskope/stagent

        # Idempotency marker. install.sh treats the downloaded branding file as the
        # "enroll config ready" signal (isEnrollConfigReady), so that is what we
        # check. NB: an earlier version of this unit looked for a `.eetk` token.
        # There IS such a file -- the client stats $appPath/.eetk.enc on every
        # enrollment attempt -- but the name is composed at runtime and appears in no
        # binary's string table, and it is a secure-enrollment token cache rather
        # than an "already enrolled" marker, so it is the wrong thing to gate on.
        # A successful enrollment writes nsbranding.json.enc (encrypted branding is
        # the default on a modern tenant), hence all three names below.
        if [ -e "$appPath/nsbranding.json" ] \
          || [ -e "$appPath/nsbranding.json.enc" ] \
          || [ -e "$appPath/nsidpconfig.json" ]; then
          echo "netskope: already enrolled (branding file present), skipping"
          exit 0
        fi

        orgkey="$(cat "$CREDENTIALS_DIRECTORY/orgkey")"
        authtoken=""
        [ -e "$CREDENTIALS_DIRECTORY/authtoken" ] && authtoken="$(cat "$CREDENTIALS_DIRECTORY/authtoken")"
        encrypttoken=""
        [ -e "$CREDENTIALS_DIRECTORY/encrypttoken" ] && encrypttoken="$(cat "$CREDENTIALS_DIRECTORY/encrypttoken")"

        report="enroll.$$"

        # install.sh's enrollment envelope, verbatim field set.
        #
        # MyRunFileName must be NON-EMPTY. installerutil validates the field before
        # doing anything else and bails with "Invalid options, MyRunFileName not
        # found!" (exit 1, not a single packet sent) when it is "" -- which is how
        # this unit used to fail. Upstream passes the path of the NSClient.run that
        # unpacked itself; nothing ever opens the file (verified with a path that
        # does not exist), so a stable placeholder is all it wants.
        json="{\"LoginUser\":\"root\",\"ReportFileName\":\"$report\",\"MyRunFileName\":\"$appPath/NSClient.run\",\"TenantHostname\":\"${cfg.tenantHost}\",\"Orgkey\":\"$orgkey\",\"UserEmail\":\"${optStr enr.email}\",\"UserUpn\":\"${optStr enr.upn}\",\"IdpMode\":\"\",\"TenantName\":\"\",\"TenantDomain\":\"\",\"EnrollAuthToken\":\"$authtoken\",\"EnrollEncryptToken\":\"$encrypttoken\",\"InstallTags\":\"\"}"

        "$appPath/installerutil" "--download_branding_file" "$json"

        # installerutil exits 0 even when the tenant rejects the enrollment; it
        # reports through a file under logs/ (install.sh cats it). Surface that, then
        # verify the branding file actually landed -- otherwise this unit "succeeds"
        # with the client still unenrolled and RemainAfterExit stops it retrying.
        if [ -f "$appPath/logs/$report" ]; then
          cat "$appPath/logs/$report"
          rm -f "$appPath/logs/$report"
        fi

        if [ ! -e "$appPath/nsbranding.json" ] \
          && [ ! -e "$appPath/nsbranding.json.enc" ] \
          && [ ! -e "$appPath/nsidpconfig.json" ]; then
          echo "netskope: enrollment failed - no branding file downloaded from ${cfg.tenantHost}" >&2
          exit 1
        fi
      '';
    };

    systemd.services.stagentd = {
      description = "Netskope client daemon";
      # Gated on autoStart: starting this is what puts the client in the traffic
      # path, so it is the one unit worth being able to hold back. netskope-setup
      # and netskope-enroll still run at boot -- they only materialise /opt and
      # fetch branding, and `systemctl start stagentd` pulls setup in anyway.
      wantedBy = lib.optional cfg.autoStart "multi-user.target";
      requires = [ "netskope-setup.service" ];
      after = [
        "network-online.target"
        "netskope-setup.service"
      ]
      ++ lib.optional enrollmentConfigured "netskope-enroll.service";
      wants = [ "network-online.target" ] ++ lib.optional enrollmentConfigured "netskope-enroll.service";
      # The client uses BOTH lookup mechanisms, so it needs both halves. Its net
      # tooling is resolved as /usr/sbin/<name> and ignores PATH entirely (see
      # fhsTools) -- but some calls just hand a bare name to a shell, and those do
      # use PATH. With no `path` set, the journal fills with
      #
      #   stAgentSvc[2966]: sh: line 1: systemd-resolved: command not found
      #
      # from its DNS-cache flush. Set both; neither alone is sufficient.
      path = [
        config.systemd.package # resolvectl, for the DNS flush
        pkgs.iproute2
        pkgs.iptables
        pkgs.dmidecode
      ];
      serviceConfig = {
        Type = "simple";
        # Launch via the materialised /opt path (not the store) so the client's
        # hard-coded /opt/netskope/stagent state lookups resolve to writable dirs.
        ExecStart = "/opt/netskope/stagent/stAgentSvc";
        WorkingDirectory = "/opt/netskope/stagent";

        # Two mount tweaks, both confined to this unit's namespace -- nothing new
        # appears on the host.
        #
        # 1. The rehashed trust dir the enroll unit also needs (see caCertDir): the
        #    daemon re-fetches branding, config and the tenant CA on its own
        #    schedule, all over TLS.
        #
        # 2. The CA the daemon installs ITSELF. Once enrolled it downloads the
        #    Netskope root and tenant CAs and tries to add them to the system trust
        #    store through FHS paths that do not exist here, and it treats failure
        #    as fatal to the whole config update -- verified on a real host:
        #
        #      failed to open file for writing:
        #        /etc/pki/ca-trust/source/anchors/nscacert.crt, err: 2
        #      cert system ca cert is not installed
        #      Install CA failed, ca rotation status 2, 0
        #      config update failed, retry in 9 minutes
        #
        #    ...so the client never converges: enrollment succeeds, then every
        #    config cycle rolls back nine minutes later.
        #
        #    cert.cpp picks its layout by probing for /usr/sbin/update-ca-certificates
        #    (Debian: write /usr/local/share/ca-certificates, then run that tool) and
        #    otherwise falls back to the RHEL pair, /etc/pki/ca-trust/source/anchors
        #    plus /usr/bin/update-ca-trust. Blanking /usr makes that choice ours
        #    rather than the host's, so give it the RHEL layout: a writable anchors
        #    dir under statePath and a shim for the refresh tool.
        #
        #    The anchors dir is where the tenant CA lands in PEM form, which is the
        #    answer to caCertFile's chicken-and-egg problem -- the installer ships no
        #    CA, but an enrolled client writes one to
        #    ''${statePath}/ca-anchors/nstenantcert.crt.
        # 3. Steering itself. Without /usr/sbin/ip the failure is quiet and easy to
        #    misread: the TLS tunnel to the POP comes up and is logged as established
        #    with an assigned IP, and only THEN does the filter device that actually
        #    intercepts traffic fail, so the daemon keeps running and looks healthy
        #    while steering nothing --
        #
        #      tunnel.cpp:988      TLS Tunnel established to gateway: ..., pop: US-STL1
        #      nsNetTool.cpp:79    Command ip not found!
        #      tunnelMgr.cpp:1288  failed to start filter device
        #      tunnel.cpp:447      TLS received nsssl_closed, tunnel destroyed
        #
        #    -- and stAgentCli reports only "Internet Security disabled due to error".
        BindReadOnlyPaths = [
          "${caCertDir}:/etc/ssl/certs"
          "${caTrustShim}:/usr/bin/update-ca-trust"
          "${fhsTools}:/usr/sbin"
        ];
        BindPaths = [ "${cfg.statePath}/ca-anchors:/etc/pki/ca-trust/source/anchors" ];
        # Empty tmpfs mount points for the two trees above to be created in. /usr
        # holds nothing the daemon uses (on NixOS it is just /usr/bin/env), and
        # /etc/pki/ca-trust is unused here -- NixOS' own bundle lives in
        # /etc/pki/tls, which stays visible.
        TemporaryFileSystem = [
          "/usr:ro"
          "/etc/pki/ca-trust:ro"
        ];
        Restart = "always";
        RestartSec = 10;
      };
    };

    # Per-user tray UI (#4).
    #
    # This is two processes, not one: stAgentApp is the watchdog / session IPC broker,
    # and stAgentUI is the actual GTK tray icon. Upstream splits their lifecycles --
    # stagentapp.service runs the watchdog, while the UI is autostarted by the desktop
    # session from /etc/xdg/autostart/stagentui.desktop, with stAgentApp otherwise
    # launching it through /usr/bin/gtk-launch. Neither route works here: this module
    # installs no XDG autostart entry, and gtk-launch does not exist at that
    # hard-coded path on NixOS. So the watchdog ran happily forever and no tray icon
    # ever appeared -- while stAgentUI, run by hand, works perfectly ("UISystemTray
    # Show system tray icon"). Its /bin/ps and /bin/grep lookups fail on NixOS but are
    # non-fatal; it registers its icon regardless, so no FHS shim is needed.
    #
    # Hand the UI's lifecycle to systemd instead of depending on the compositor's
    # autostart handling or an FHS path.
    systemd.user.services = lib.mkIf cfg.enableTray {
      stagentapp = {
        description = "Netskope client tray agent (watchdog)";
        # No point drawing a tray for a daemon that is not running -- see autoStart.
        wantedBy = lib.optional cfg.autoStart "graphical-session.target";
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "/opt/netskope/stagent/stAgentApp";
          WorkingDirectory = "/opt/netskope/stagent";
          # The client refuses IPC peers whose LD_LIBRARY_PATH holds "non-standard"
          # paths -- "invalid client connection ... due to code injection" -- and any
          # /nix/store entry trips it. Session managers readily import the variable
          # into the user manager, so drop it for these units.
          UnsetEnvironment = "LD_LIBRARY_PATH";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };

      stagentui = {
        description = "Netskope client tray icon";
        wantedBy = lib.optional cfg.autoStart "graphical-session.target";
        partOf = [ "graphical-session.target" ];
        after = [
          "graphical-session.target"
          "stagentapp.service"
        ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "/opt/netskope/stagent/stAgentUI";
          WorkingDirectory = "/opt/netskope/stagent";
          UnsetEnvironment = "LD_LIBRARY_PATH";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    };
  };
}
