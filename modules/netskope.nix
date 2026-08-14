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
  };

  config = lib.mkIf cfg.enable {
    # ------------------------------------------------------------------
    # PROTOTYPE SCOPE (map issue #5: packaging).
    #
    # This module currently only wires the *package* and a bare daemon unit, to
    # exercise the derivation. It is deliberately incomplete: the following are
    # tracked as separate tickets and are NOT implemented yet, so the daemon will
    # NOT actually function until at least #7 lands.
    #
    #   #6  declarative token/org-key enrollment + secret handling (installerutil)
    #   #7  relocate writable state (logs/, data/, .eetk, sockets) out of /nix/store
    #   #8  Netskope root CA trust  (security.pki.certificateFiles = caCertPath)
    #   #9  full option schema (tenant/source URL/CA toggle/tray user/etc.)
    # ------------------------------------------------------------------

    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "services.netskope: Netskope ships no Linux client for ${pkgs.stdenv.hostPlatform.system} (x86_64-linux only).";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    # PLACEHOLDER for issue #7. The binaries hard-code /opt/netskope/stagent, so we
    # surface the store tree there. But this symlink is read-only: the daemon also
    # needs to WRITE logs/, data/, the .eetk enrollment token and an IPC socket under
    # that path. Splitting the writable subdirs onto a real location (e.g.
    # /var/lib/netskope) is exactly what #7 must decide before this works.
    systemd.tmpfiles.rules = [
      "L+ /opt/netskope/stagent - - - - ${cfg.package}/opt/netskope/stagent"
    ];

    systemd.services.stagentd = {
      description = "Netskope client daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.iptables ]; # steering programs iptables at runtime
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/opt/netskope/stagent/stAgentSvc";
        WorkingDirectory = "${cfg.package}/opt/netskope/stagent";
        Restart = "always";
        RestartSec = 10;
        # StateDirectory / BindPaths for writable state -> issue #7
      };
    };
  };
}
