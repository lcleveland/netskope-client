# NixOS VM test for the module logic (issue #9).
#
# SCAFFOLD — authored without Nix available, so it has NOT been run; treat as a
# starting point to execute under #10 (`nix build .#checks.x86_64-linux.module`).
#
# It uses a stub package so the *module* (writable-state relocation, unit wiring)
# can be exercised without the proprietary NSClient.run. It deliberately does not
# configure enrollment (no secrets, no installerutil) or the tray.
{ pkgs, self }:
let
  # Minimal stand-in for the client: just enough shape for the module to
  # materialise /opt and start a "daemon".
  stub = pkgs.runCommand "netskope-client-stub" { } ''
    mkdir -p $out/opt/netskope/stagent
    printf '#!%s\nexec sleep infinity\n' ${pkgs.runtimeShell} > $out/opt/netskope/stagent/stAgentSvc
    chmod +x $out/opt/netskope/stagent/stAgentSvc
    echo stub > $out/opt/netskope/stagent/nsclient-pub.gpg
  '';
in
pkgs.testers.runNixOSTest {
  name = "netskope-module";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];
      services.netskope = {
        enable = true;
        enableTray = false; # daemon-only: no GTK/WebKit closure in the test
        package = stub; # avoid fetching the real (proprietary) client
      };
    };

  testScript = ''
    machine.wait_for_unit("netskope-setup.service")

    # /opt/netskope/stagent is a real dir: shipped files are store symlinks...
    machine.succeed("test -d /opt/netskope/stagent")
    machine.succeed("test -L /opt/netskope/stagent/stAgentSvc")
    # ...and the writable subdirs redirect to persistent state.
    machine.succeed("test -d /var/lib/netskope/data")
    machine.succeed("readlink /opt/netskope/stagent/data | grep -q '^/var/lib/netskope/data$'")
    machine.succeed("readlink /opt/netskope/stagent/logs | grep -q '^/var/lib/netskope/logs$'")

    # The daemon starts against the materialised /opt path.
    machine.wait_for_unit("stagentd.service")
    machine.succeed("systemctl is-active stagentd.service")
  '';
}
