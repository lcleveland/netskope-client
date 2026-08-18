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

  # The helper commands the daemon shells out to, at the paths it looks for them.
  #
  # It resolves them by absolute FHS path, NOT through PATH. That was established the
  # hard way, by running the daemon against a throwaway copy of its app dir and
  # watching nsdebuglog: with iproute2 on the unit's PATH it still logged "Command ip
  # not found!", and it still did with /usr/bin/ip in place; adding /usr/sbin/ip is
  # what silenced it and let "reset stAgent route rules" run. (systemd.services.*.path
  # is therefore not sufficient here -- it was tried, shipped, and did nothing for the
  # lookups, though a few bare-name shell calls do still need it. Set both.)
  #
  # And it wants each tool in the directory a real FHS distro would put it in, which is
  # why this is bound at BOTH /usr/bin and /usr/sbin. Shipping only /usr/sbin got `ip`,
  # `iptables`, `ip6tables`, `dmidecode` and `sysctl` working while every /usr/bin tool
  # stayed invisible -- `resolvectl`, `systemd-resolve` and `pidof` were all present
  # under /usr/sbin and PATH, and the DNS flush still reported
  #
  #   nsNetTool.cpp:540  NetTool Flush DNS command not found!
  #
  # on a host where `pidof systemd-resolved` answers instantly from any other shell.
  # One directory populated per tool guesses wrong half the time; two costs nothing,
  # since the whole thing is symlinks.
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
    # Flushing the DNS cache when steering changes -- or when the network does, which
    # is the case that matters most: the whole point of the flush is to drop answers
    # learned from the network you just left.
    #
    # resolvectl alone is NOT enough, and the failure is silent in the worst way.
    # Verified on a real host: EVERY flush attempt failed,
    #
    #   nsNetTool.cpp:540  NetTool Flush DNS command not found!
    #
    # while npaTunnelMgr logged "System DNS cache is flushed" right above it -- it
    # never checks the result. So the resolver cache was flushed exactly never, on a
    # machine whose own logs claimed otherwise.
    #
    # Three names, because the client has two flush paths and a gate in front of them:
    # linux/flushDns.cpp composes `systemd-resolve --flush-caches` or
    # `resolvectl flush-caches`, and gates both on `pidof systemd-resolved` -- which is
    # also the source of the one shell error that outlived the first attempt at this
    # fix, since a failed lookup leaves the composed command as just its argument:
    #
    #   stAgentSvc[2818]: sh: line 1: systemd-resolved: command not found
    #
    # ...whereupon it decides "skip flushDNS since systemd-resolved is not running", on
    # a host where resolved is the only resolver there is. `systemd-resolve` is the
    # pre-v239 name and a symlink to resolvectl in the same package, so naming it costs
    # nothing. All three are /usr/bin tools on an FHS distro, which is the other half
    # of this -- see the directory note above.
    ln -s ${config.systemd.package}/bin/resolvectl $out/resolvectl
    ln -s ${config.systemd.package}/bin/systemd-resolve $out/systemd-resolve
    ln -s ${pkgs.procps}/bin/pidof $out/pidof
    # Socket buffers for the Private Access tunnel: npaTunnelMgr reads
    # `sysctl -n net.core.{r,w}mem_max` and writes back with `sysctl -w`. Another
    # bare-name call that fails on NixOS --
    #
    #   stAgentSvc[2603]: sh: line 1: sysctl: command not found
    #
    # -- leaving the tunnel on whatever the defaults happen to be.
    ln -s ${pkgs.procps}/bin/sysctl $out/sysctl
    # The RHEL trust-store refresh tool the CA installer calls after dropping its
    # anchors (see the CA notes on stagentd.service). It lives in here rather than in a
    # bind of its own because this directory now IS /usr/bin, and a file bind over a
    # path inside a read-only directory bind needs the file to exist in it first.
    ln -s ${caTrustShim} $out/update-ca-trust
  '';

  # Which trust store the client's own units get.
  #
  # Normally the build-time one above is right. But with trustCA on and steering
  # live, the client's OWN traffic is intercepted and re-signed by the tenant too --
  # it is not exempt from its own SSL inspection:
  #
  #   tunnel.cpp:1296  TLS Tunneling flow ... process: stagentsvc
  #                    to host: achecker-<tenant>.goskope.com
  #   nsHTTPClient.cpp:512  curl_easy_perform failed, code 60,
  #                    SSL peer certificate or SSH remote key was not OK
  #
  # achecker is the Private Access access-checker, so a daemon that cannot verify it
  # cannot resolve private apps: they come back SERVFAIL while everything else looks
  # healthy. Measured on a real host -- the daemon's private bundle had 121
  # certificates and no tenant CA, while the system had 123 with it.
  #
  # So when trustCA is on, point the daemon at the same runtime trust dir as the rest
  # of the machine (netskope-ca-trust.service builds it, and orders itself before
  # stagentd so it exists first). It carries the hashed layout the client's CApath
  # needs, and it follows CA rotation.
  clientCertDir = if cfg.trustCA then "${cfg.statePath}/ca-trust" else caCertDir;

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
      # Both client units bind ${statePath}/ca-trust as their /etc/ssl/certs when
      # trustCA is on (see clientCertDir), and a bind of a directory that does not
      # exist yet fails the unit outright -- so this has to have run first.
      before = [
        "stagentd.service"
        "netskope-enroll.service"
      ];
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

    # Private Access name resolution.
    #
    # The client resolves private apps itself, handing back a synthetic 100.64.0.0/10
    # address -- verified against a live tenant, where an A query for a private app
    # aimed at the system resolver returns 100.64.0.1. Browsers still get nothing,
    # because private apps are commonly published under `.local` and systemd-resolved
    # refuses to send `.local` to unicast DNS at all (RFC 6762 reserves it for mDNS):
    #
    #   resolve call failed: No appropriate name servers or networks for name found
    #
    # The query dies inside resolved and never reaches the client. Fix it by giving
    # the client's own tunnel interface a routing domain for `local`, plus the DNS
    # servers of the default-route link -- the client only answers queries aimed at
    # the system's resolver, so the same query sent to a public resolver comes back
    # as a real NXDOMAIN.
    #
    # Four things here were settled by testing on a real host rather than reasoned:
    #
    #  * A GLOBAL routing domain (services.resolved.domains) does NOT work: global
    #    domains route to global DNS servers, and a DHCP-configured host has none.
    #  * `local` as a whole is the right scope. It needs no tenant knowledge, and the
    #    domain list could not be discovered anyway -- the client keeps it encrypted.
    #  * mDNS keeps working. nss-mdns only claims SINGLE-label `.local` names, so
    #    `somehost.local` still resolves through Avahi ahead of resolved, while
    #    multi-label corporate names fall through to us.
    #  * This belongs on sta0, not on the physical link. Touching an
    #    NetworkManager-managed link risks `resolvectl revert` wiping the DNS servers
    #    NM pushed (recoverable only by reactivating the connection), whereas sta0 is
    #    created and destroyed by the client, so the routing domain naturally lives
    #    exactly as long as the tunnel does.
    #
    # NB: the client rejects AAAA queries for these names ("Unsupported DNS Flags"),
    # which is its own quirk and not fatal -- resolved uses the A answer.
    #
    # The servers are a property of the network the laptop is ON, so this cannot be a
    # oneshot that samples them once. sta0 belongs to the tunnel, not to the uplink,
    # and it OUTLIVES an uplink change -- measured on a real host, where docking moved
    # the client's uplink between wifi and ethernet three times in twenty seconds and
    # re-enumerated the dock's NIC (eth0 ifindex 6 -> 7):
    #
    #   nsDnsMgr.cpp:927  Uplink DNS 10.2.75.10 OIF wlp2s0/4 -> eth0/6; rebuilding socket
    #   nsDnsMgr.cpp:927  Uplink DNS 10.2.75.10 OIF eth0/6 -> wlp2s0/4; rebuilding socket
    #   nsDnsMgr.cpp:927  Uplink DNS 10.2.75.10 OIF wlp2s0/4 -> eth0/7; rebuilding socket
    #
    # ...through all of which sta0 stayed up and the sampled-once unit never re-ran.
    # Dock to wifi and the servers pinned here are the ones the docked network handed
    # out -- typically unreachable from the new one -- so `.local` names go to a dead
    # resolver and Private Access resolution stops, while everything else looks fine.
    # So: apply, then follow the network for as long as the tunnel lives.
    systemd.services.netskope-npa-dns = {
      description = "Route .local names to the Netskope tunnel resolver";
      # sta0 exists only while the tunnel is up, which is exactly when this should
      # apply, so bind to the device rather than guessing at timing.
      bindsTo = [ "sys-subsystem-net-devices-sta0.device" ];
      after = [ "sys-subsystem-net-devices-sta0.device" ];
      wantedBy = [ "sys-subsystem-net-devices-sta0.device" ];
      serviceConfig = {
        # notify, not simple: the unit is only meaningfully up once `.local` actually
        # routes somewhere, and NotifyAccess=all because the readiness ping comes from
        # a child of the shell rather than the shell itself.
        Type = "notify";
        NotifyAccess = "all";
        # If `ip monitor` dies the tunnel is still up and still needs following.
        # BindsTo means a deliberate stop (sta0 going away) is not restarted.
        Restart = "always";
        RestartSec = 5;
      };
      script = ''
        set -eu
        resolvectl=${config.systemd.package}/bin/resolvectl
        ip=${pkgs.iproute2}/bin/ip

        applied=""

        apply() {
          # The uplink, never sta0 itself: the client puts a default route on the
          # tunnel in its own table, and pointing sta0's resolver at sta0 would be a
          # loop. (Skipping it here rather than relying on the main table staying
          # clean, since that is the client's to change, not ours.)
          link="$("$ip" -o route show default \
            | ${pkgs.gawk}/bin/awk '$5 != "sta0" { print $5; exit }')"
          if [ -z "$link" ]; then
            echo "netskope: no default route; leaving Private Access DNS alone" >&2
            return 0
          fi
          servers="$("$resolvectl" dns "$link" | ${pkgs.gnused}/bin/sed 's/^[^:]*: *//')"
          if [ -z "$servers" ]; then
            echo "netskope: $link has no DNS servers; leaving Private Access DNS alone" >&2
            return 0
          fi
          # Mid-switch there is a moment with no uplink or no lease yet. Both branches
          # above leave the previous setting in place rather than tearing `.local` down
          # for a blip -- correct only because another event is coming to fix it.
          if [ "$link $servers" = "$applied" ]; then
            return 0
          fi
          # Unquoted on purpose: resolvectl takes the servers as separate arguments.
          # shellcheck disable=SC2086
          "$resolvectl" dns sta0 $servers
          "$resolvectl" domain sta0 '~local'
          applied="$link $servers"
          echo "netskope: .local routed via sta0 -> $servers (uplink $link)" >&2
        }

        apply
        ${config.systemd.package}/bin/systemd-notify --ready

        # Follow the uplink for the life of the tunnel. Events only ever trigger the
        # comparison in apply(), so a busy link is cheap and a redundant wakeup is
        # free.
        "$ip" monitor link address route | while :; do
          # Wake on a netlink event, or every 60s regardless: `ip monitor` drops
          # messages on receive-buffer overrun and prints its own complaint, and a
          # dropped one would otherwise strand `.local` on the old network's resolver
          # until the tunnel next came up. The poll is the backstop, the events are
          # what make it converge in seconds.
          rc=0
          read -r -t 60 _ || rc=$?
          # A status above 128 is the timeout firing; anything else non-zero is EOF,
          # i.e. `ip monitor` is gone. Leave and let Restart bring both back, rather
          # than spinning on a dead pipe.
          if [ "$rc" -ne 0 ] && [ "$rc" -le 128 ]; then
            break
          fi
          # One dock swap is dozens of link/address/route messages, and the client
          # rebuilds its own bypass routes on top of them. Drain the burst and apply
          # once it has settled, so resolved is reconfigured at most once per change.
          while read -r -t 2 _; do :; done
          apply
        done
      '';
    };

    # Rebinding the tunnel after an uplink change.
    #
    # The client does not notice that its uplink went away. It keeps the steering
    # tunnel bound to the source address the old link had, and only rebuilds when its
    # own TLS keepalive finally expires -- measured on a real host across two undocks,
    # 2m14s and 2m07s:
    #
    #   10:18:33  [undock; the DNS unit above reacts within the second]
    #   10:18:46  npa keepAlive fails with 15 tries
    #   10:20:47  tunnel.cpp:447   TLS received nsssl_closed, tunnel destroyed
    #   10:20:48  tunnelMgr.cpp:1147  Primary tunnel source IP: 10.20.35.126
    #
    # The symptom is specific and easy to misattribute: DNS keeps working, because
    # nsDnsMgr rebuilds its own uplink sockets on the change event within
    # milliseconds, while everything on 80/443 goes through the tunnel and hangs. The
    # client's flow log fills up while it does -- attempts went from 61 per 30s before
    # the undock to 296 during it, a retry storm rather than traffic. Bypass routes are
    # collateral: nsBypassRouteHandler sees every change event and rebuilds nothing
    # (its deletes all fail, since the kernel already purged the routes with the dead
    # link), so table 9 is only repaired when the tunnel is.
    #
    # None of that is reachable through configuration -- the keepalive interval lives
    # in the tenant's encrypted config, and stAgentCli exposes no knob for it.
    #
    # But the client's RECOVERY is prompt: 1.3s from seeing the socket close to a
    # tunnel on the new uplink, routes and all. Only the detection is slow. So detect
    # it for the client: when an address disappears, close any of its sockets still
    # bound to one. A socket whose local address is no longer configured cannot carry
    # traffic under any circumstances, which is what makes this safe rather than a
    # heuristic -- there is no state in which killing it loses something.
    #
    # Deliberately narrow, on both axes:
    #  * Only sockets whose local address is absent from `ip addr`. Not "sockets on the
    #    old uplink" -- an address can survive an uplink change, and this must not fire
    #    on a metric change or a second link appearing.
    #  * Only the client's own sockets, matched through `ss -p`. A NixOS module has no
    #    business reaping other software's sockets, however dead they are.
    systemd.services.netskope-tunnel-rebind = {
      description = "Rebind the Netskope tunnel after an uplink change";
      # Same lifecycle as the DNS unit: relevant exactly while a tunnel exists.
      bindsTo = [ "sys-subsystem-net-devices-sta0.device" ];
      after = [ "sys-subsystem-net-devices-sta0.device" ];
      wantedBy = [ "sys-subsystem-net-devices-sta0.device" ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        Restart = "always";
        RestartSec = 5;
      };
      script = ''
        set -eu
        ip=${pkgs.iproute2}/bin/ip
        ss=${pkgs.iproute2}/bin/ss

        sweep() {
          # Every address currently configured anywhere, padded so the match below
          # cannot hit a substring (10.2.192.20 inside 10.2.192.202).
          addrs=" $("$ip" -o addr show | ${pkgs.gawk}/bin/awk '{ split($4, a, "/"); print a[1] }' \
            | tr '\n' ' ')"

          # -H drops the header; columns are Recv-Q Send-Q Local Peer Process.
          "$ss" -Htnp state established 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -F 'stAgentSvc' \
            | while read -r _ _ local peer _; do
              # IPv4 only: the client's tunnel is v4, and stripping a port off a
              # bracketed v6 literal needs different handling than this.
              case "$local" in
                *:*:*) continue ;;
              esac
              # ss renders the local end of a device-bound socket as ADDR%IFNAME:PORT,
              # and the client binds EVERY tunnel socket to its uplink device -- it has
              # to, or the traffic carrying the tunnel would route back into the tun that
              # tunnel installs. So the qualifier is present on all of them, and it has to
              # come off before the comparison below. Comparing the qualified form against
              # `ip addr` cannot succeed for any socket the client owns, which is how this
              # unit came to condemn every HEALTHY socket it found:
              #
              #   netskope: closed tunnel socket 10.2.192.202%eth0:49898 ->
              #             162.10.127.32:443; its source address is gone
              #
              # on a host whose `ip addr` listed 10.2.192.202 on eth0 the entire time. The
              # 60s backstop then made it periodic, and since the client's recovery IS
              # prompt the result was a tunnel that rebuilt and was torn down again about
              # once a minute -- the exact bounce this unit exists to prevent, caused by
              # this unit.
              lport=''${local##*:}
              laddr=''${local%:*}
              laddr=''${laddr%%"%"*}
              [ -n "$laddr" ] || continue
              case "$addrs" in
                *" $laddr "*) continue ;;
              esac
              # `ss -K` exits 0 whether it destroyed a socket, matched nothing, or was
              # refused permission -- all three verified -- so its status cannot be what
              # we report on; that is how the DNS flush managed to log a success it never
              # had. It does print what it matched, and -H leaves stdout empty when that
              # is nothing, so key the message off the output instead. stderr is
              # deliberately not swallowed, so a real failure still reaches the journal.
              if [ -n "$("$ss" -HKtn state established src "$laddr:$lport" dst "$peer")" ]; then
                echo "netskope: closed tunnel socket $local -> $peer; source address $laddr is no longer configured" >&2
              fi
            done
        }

        sweep
        ${config.systemd.package}/bin/systemd-notify --ready

        # Addresses are what matter here, but link events arrive alongside them on a
        # dock swap and cost nothing to wake on.
        "$ip" monitor address link | while :; do
          rc=0
          read -r -t 60 _ || rc=$?
          if [ "$rc" -ne 0 ] && [ "$rc" -le 128 ]; then
            break
          fi
          # Let the burst settle before looking: mid-swap the old address may be gone
          # while the new one has not arrived, and there is nothing to gain from
          # sweeping twice. The client only needs one close to start rebuilding.
          while read -r -t 2 _; do :; done
          sweep
        done
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
      requires = [ "netskope-setup.service" ] ++ lib.optional cfg.trustCA "netskope-ca-trust.service";
      after = [
        "netskope-setup.service"
        "network-online.target"
      ]
      ++ lib.optional cfg.trustCA "netskope-ca-trust.service";
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
        BindReadOnlyPaths = [ "${clientCertDir}:/etc/ssl/certs" ];
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
      requires = [ "netskope-setup.service" ] ++ lib.optional cfg.trustCA "netskope-ca-trust.service";
      after = [
        "network-online.target"
        "netskope-setup.service"
      ]
      ++ lib.optional cfg.trustCA "netskope-ca-trust.service"
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
        pkgs.procps # sysctl and pidof, both invoked as bare names through a shell
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
          "${clientCertDir}:/etc/ssl/certs"
          # Both, because the client wants each tool where FHS would keep it, and
          # picking one directory per tool guesses wrong -- see fhsTools. It carries
          # update-ca-trust for the /usr/bin half rather than binding that separately.
          "${fhsTools}:/usr/bin"
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
