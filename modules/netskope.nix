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
        Add the Netskope SSL-inspection root CA to the system trust store.
        This is a MITM certificate, so opt in deliberately. Requires `caCertFile`.
      '';
    };

    caCertFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/netskope/nstenantcert.crt";
      description = ''
        Path to the Netskope root CA (PEM) used for SSL inspection. The installer
        does NOT ship it, so it cannot be derived from the package -- but an
        enrolled client downloads it and writes it out in PEM form, so the simplest
        source is this host itself: once the daemon has run a config update, look in
        `''${statePath}/ca-anchors/` for `nstenantcert.crt` (SSL inspection) and
        `nscacert.crt` (the Netskope root). Failing that, take it from the tenant
        admin console. (The client's own encrypted copies live in
        `''${statePath}/app/data/*.pem.enc` and are not directly usable.)
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
        assertion = cfg.trustCA -> cfg.caCertFile != null;
        message = "services.netskope.trustCA is enabled but services.netskope.caCertFile is unset — supply the Netskope root CA PEM (the installer does not ship it).";
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

    warnings = lib.optional cfg.autoUpdate "services.netskope.autoUpdate has no real effect on NixOS: the client cannot self-update the immutable store. Bump the packaged NSClient.run instead.";

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

    # Netskope's SSL inspection MITMs TLS, so its root CA must be trusted
    # system-wide (issue #8). The installer does not ship the cert, so the user
    # supplies it via caCertFile; it is added at build time to the system bundle.
    security.pki.certificateFiles = lib.mkIf (cfg.trustCA && cfg.caCertFile != null) [ cfg.caCertFile ];

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
      wantedBy = [ "multi-user.target" ];
      requires = [ "netskope-setup.service" ];
      after = [
        "network-online.target"
        "netskope-setup.service"
      ]
      ++ lib.optional enrollmentConfigured "netskope-enroll.service";
      wants = [ "network-online.target" ] ++ lib.optional enrollmentConfigured "netskope-enroll.service";
      # NB: no `path`. The daemon ignores PATH for its helper commands and looks them
      # up at /usr/sbin/<name> instead; they are bound in there (see fhsTools).
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
        wantedBy = [ "graphical-session.target" ];
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
        wantedBy = [ "graphical-session.target" ];
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
