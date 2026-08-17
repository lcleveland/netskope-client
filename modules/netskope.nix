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
        does NOT ship it, so it cannot be derived from the package; obtain it from
        your tenant admin console, or copy it off an already-enrolled host (the
        client names it `nstenantcert.crt`; under this module's state relocation it
        lands in `''${statePath}/app/data/`).
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
        # check. NB: an earlier version of this unit looked for a `.eetk` token --
        # that string does not appear in any shipped binary, so the guard never
        # fired and enrollment re-ran on every boot.
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
        json="{\"LoginUser\":\"root\",\"ReportFileName\":\"$report\",\"MyRunFileName\":\"\",\"TenantHostname\":\"${cfg.tenantHost}\",\"Orgkey\":\"$orgkey\",\"UserEmail\":\"${optStr enr.email}\",\"UserUpn\":\"${optStr enr.upn}\",\"IdpMode\":\"\",\"TenantName\":\"\",\"TenantDomain\":\"\",\"EnrollAuthToken\":\"$authtoken\",\"EnrollEncryptToken\":\"$encrypttoken\",\"InstallTags\":\"\"}"

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
