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

    enableTray = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build and run the per-user tray UI (stAgentUI + the stagentapp user service).
        Disable on headless hosts to drop the heavy GTK/WebKit closure.
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
        does NOT ship it, so it cannot be derived from the package; obtain it from
        your tenant admin console, or copy it off an already-enrolled host (the
        client names it `nstenantcert.crt`; under this module's state relocation it
        lands at /var/lib/netskope/data/).
      '';
    };

    tenantHost = lib.mkOption {
      type = lib.types.str;
      default = if cfg.tenant == null then "" else "addon-${cfg.tenant}.goskope.com";
      defaultText = lib.literalExpression ''"addon-<tenant>.goskope.com" when `tenant` is set, else ""'';
      example = "addon-<tenant>.goskope.com";
      description = ''
        Tenant enrollment host (the addon/gateway host). Maps to the client's
        -H/--tenantHostname. Defaults to addon-<tenant>.goskope.com when `tenant`
        is set; override for regional variants. Leave empty to package the client
        without declarative enrollment.
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
        description = ''
          Optional user email for email-mode enrollment (-m/--email). Not needed
          when enrolling with an org key + auth token.
        '';
      };

      upn = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional UPN for non-domain-joined enrollment (-u/--upn).";
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
    #   #10  build + runtime verification on a real Nix host (this was authored
    #        without Nix; the enrollment handshake in particular is unverified)
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
    ];

    warnings = lib.optional cfg.autoUpdate "services.netskope.autoUpdate has no real effect on NixOS: the client cannot self-update the immutable store. Bump the packaged NSClient.run instead.";

    environment.systemPackages = [ cfg.package ];

    # Netskope's SSL inspection MITMs TLS, so its root CA must be trusted
    # system-wide (issue #8). The installer does not ship the cert, so the user
    # supplies it via caCertFile; it is added at build time to the system bundle.
    security.pki.certificateFiles = lib.mkIf (cfg.trustCA && cfg.caCertFile != null) [ cfg.caCertFile ];

    # Writable-state relocation (issue #7).
    #
    # The client hard-codes /opt/netskope/stagent and both READS its shipped files
    # and WRITES runtime state under that same path (data/ = certs + the .eetk
    # enrollment token + config, logs/, plus stray top-level files and sockets) --
    # read-only in /nix/store. Strategy: materialise /opt/netskope/stagent as a real
    # root-owned directory; symlink every shipped file in from the store (immutable)
    # and redirect the writable subdirs data/ + logs/ to persistent /var/lib/netskope.
    # Because the top dir is itself a real writable directory, the daemon can still
    # create ad-hoc files (.eetk, sockets) directly under it. Re-materialised on each
    # boot/switch by a oneshot ordered before the daemon, so it survives nixpkgs bumps
    # without enumerating filenames at eval time.
    systemd.services.netskope-setup = {
      description = "Prepare /opt/netskope/stagent (Netskope writable-state relocation)";
      wantedBy = [ "multi-user.target" ];
      before = [ "stagentd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        src="${cfg.package}/opt/netskope/stagent"
        dst="/opt/netskope/stagent"
        state="/var/lib/netskope"

        install -d -m 0755 "$dst"
        install -d -m 0700 "$state/data"
        install -d -m 0755 "$state/logs"

        # Clear stale symlinks from a previous generation; keep real files the
        # client dropped in the top dir (e.g. the .eetk enrollment token).
        find "$dst" -maxdepth 1 -type l -delete

        # Symlink every shipped file from the store (read-only, immutable).
        for f in "$src"/*; do
          ln -sfn "$f" "$dst/$(basename "$f")"
        done

        # Redirect the writable subdirs to persistent state.
        ln -sfn "$state/data" "$dst/data"
        ln -sfn "$state/logs" "$dst/logs"
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
        LoadCredential = [
          "orgkey:${enr.orgKeyFile}"
        ]
        ++ lib.optional (enr.authTokenFile != null) "authtoken:${enr.authTokenFile}"
        ++ lib.optional (enr.encryptTokenFile != null) "encrypttoken:${enr.encryptTokenFile}";
      };
      script = ''
        set -eu
        appPath=/opt/netskope/stagent

        # Idempotent: the .eetk token is written on successful enrollment.
        if [ -e "$appPath/.eetk" ] || [ -e /var/lib/netskope/data/.eetk ]; then
          echo "netskope: already enrolled, skipping"
          exit 0
        fi

        orgkey="$(cat "$CREDENTIALS_DIRECTORY/orgkey")"
        authtoken=""
        [ -e "$CREDENTIALS_DIRECTORY/authtoken" ] && authtoken="$(cat "$CREDENTIALS_DIRECTORY/authtoken")"
        encrypttoken=""
        [ -e "$CREDENTIALS_DIRECTORY/encrypttoken" ] && encrypttoken="$(cat "$CREDENTIALS_DIRECTORY/encrypttoken")"

        report="enroll.$$"

        # install.sh's enrollment envelope, verbatim field set.
        json="{\"LoginUser\":\"root\",\"ReportFileName\":\"$report\",\"MyRunFileName\":\"\",\"TenantHostname\":\"${cfg.tenantHost}\",\"Orgkey\":\"$orgkey\",\"UserEmail\":\"${optStr enr.email}\",\"UserUpn\":\"${optStr enr.upn}\",\"IdpMode\":\"\",\"TenantName\":\"\",\"TenantDomain\":\"\",\"EnrollAuthToken\":\"$authtoken\",\"EnrollEncryptToken\":\"$encrypttoken\",\"InstallTags\":\"\"}"

        "$appPath/installerutil" "--download_branding_file" "$json"
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
      path = [ pkgs.iptables ]; # steering programs iptables at runtime
      serviceConfig = {
        Type = "simple";
        # Launch via the materialised /opt path (not the store) so the client's
        # hard-coded /opt/netskope/stagent state lookups resolve to writable dirs.
        ExecStart = "/opt/netskope/stagent/stAgentSvc";
        WorkingDirectory = "/opt/netskope/stagent";
        Restart = "always";
        RestartSec = 10;
      };
    };

    # Per-user tray UI (#4). Runs stAgentApp (the tray/watchdog) in the user's
    # graphical session; the shipped stagentapp.service targets default.target,
    # rewired here to graphical-session.target.
    systemd.user.services.stagentapp = lib.mkIf cfg.enableTray {
      description = "Netskope client tray agent";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "/opt/netskope/stagent/stAgentApp";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
