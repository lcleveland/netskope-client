{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.netskope;
in
{
  options.services.netskope = {
    enable = lib.mkEnableOption "the Netskope client daemon (stAgentSvc)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/netskope-client.nix { inherit (cfg) enableTray; };
      defaultText = lib.literalExpression "netskope-client";
      description = "The netskope-client package to run.";
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
      example = "/etc/netskope/nscacert.pem";
      description = ''
        Path to the Netskope root CA (PEM) used for SSL inspection. The installer
        does NOT ship it, so it cannot be derived from the package; obtain it from
        your tenant admin console, or copy /var/lib/netskope/data/nscacert.pem off
        an already-enrolled host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ------------------------------------------------------------------
    # SCOPE. Packaging (#5), writable-state relocation (#7), and CA trust (#8)
    # are implemented. Still tracked as separate tickets and NOT wired up yet --
    # the daemon won't enroll until these land:
    #
    #   #6  declarative token/org-key enrollment + secret handling (installerutil)
    #   #9  full option schema (tenant/source URL/tray user/etc.)
    #
    # Build-verification of the whole thing on a Nix host is #10.
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
    ];

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

    systemd.services.stagentd = {
      description = "Netskope client daemon";
      wantedBy = [ "multi-user.target" ];
      requires = [ "netskope-setup.service" ];
      after = [
        "network-online.target"
        "netskope-setup.service"
      ];
      wants = [ "network-online.target" ];
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
  };
}
