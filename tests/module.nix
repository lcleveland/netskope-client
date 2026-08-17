# NixOS VM test for the module logic (issue #9).
#
# It uses a stub package so the *module* (state relocation, the bind mount, unit
# wiring) can be exercised without the proprietary NSClient.run. It deliberately does
# not configure enrollment (no secrets, no installerutil) or the tray.
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

    # The client's IPC layer authenticates peers by resolving the connecting
    # process's /proc/<pid>/exe against a hard-coded allowlist of
    # /opt/netskope/stagent/{stAgentApp,stAgentCli,stAgentUI,nsdiag,bwansvc}, so the
    # shipped files must be REAL FILES at that path. Symlinking them in from the
    # store resolves to /nix/store and gets every peer rejected ("NSCOM2 invalid
    # client connection"), which silently breaks the tray and stAgentCli while
    # leaving the daemon itself looking healthy. Guard against that regression.
    machine.succeed("test -f /opt/netskope/stagent/stAgentSvc")
    machine.fail("test -L /opt/netskope/stagent/stAgentSvc")
    machine.succeed(
        'test "$(realpath /opt/netskope/stagent/stAgentSvc)" = /opt/netskope/stagent/stAgentSvc'
    )

    # That path is a bind mount of the state dir: it keeps the hard-coded location
    # stable while leaving /opt itself disposable on a tmpfs root.
    machine.succeed("mountpoint -q /opt/netskope/stagent")
    machine.succeed("test -d /var/lib/netskope/app/data")
    machine.succeed("test -d /var/lib/netskope/app/logs")

    # Impermanence contract: state the client drops into its hard-coded directory has
    # to land under statePath, the single directory a tmpfs-root host must persist.
    machine.succeed("echo nsdeviceid=test > /opt/netskope/stagent/provisioning")
    machine.succeed("grep -q nsdeviceid=test /var/lib/netskope/app/provisioning")

    # data/ must stay traversable by the per-user stAgentUI/stAgentCli, which read
    # data/nsusercert.p12 as the logged-in user (upstream install.sh uses mode 755).
    machine.succeed('test "$(stat -c %a /var/lib/netskope/app/data)" = 755')

    # Re-running setup, as a nixos-rebuild switch does, must neither stack bind
    # mounts nor discard client state.
    machine.succeed("systemctl restart netskope-setup.service")
    machine.succeed("grep -q nsdeviceid=test /opt/netskope/stagent/provisioning")
    machine.succeed('test "$(grep -c " /opt/netskope/stagent " /proc/mounts)" = 1')

    # The daemon starts against the bind-mounted path.
    machine.wait_for_unit("stagentd.service")
    machine.succeed("systemctl is-active stagentd.service")

    # The client verifies TLS peers with a compiled-in OpenSSL CApath of
    # /etc/ssl/certs, and a CApath resolves anchors through <subject-hash>.<seq>
    # symlinks that NixOS' /etc/ssl/certs does not have -- so without a rehashed
    # directory bind-mounted in, every branding/config fetch fails with
    # "self-signed certificate in certificate chain" (curl 60) and the client never
    # enrolls. Check inside the daemon's own mount namespace, which is where
    # BindReadOnlyPaths puts it.
    pid = machine.succeed("systemctl show -p MainPID --value stagentd.service").strip()
    machine.succeed(f"nsenter --mount --target {pid} find /etc/ssl/certs -name '*.0' | grep -q .")
    # ... and the bundle files stay reachable: the mount is a superset of the real dir.
    machine.succeed(f"nsenter --mount --target {pid} test -e /etc/ssl/certs/ca-bundle.crt")

    # Namespacing the daemon must not hide the /opt bind mount it execs from.
    machine.succeed(f"nsenter --mount --target {pid} mountpoint -q /opt/netskope/stagent")

    # Once enrolled the client installs the tenant CA into the system trust store
    # itself, and treats failure as fatal to the whole config update ("Install CA
    # failed" -> "config update failed, retry in 9 minutes"). It needs a writable
    # anchors dir and a refresh tool; give it the RHEL pair, since blanking /usr
    # means it cannot find Debian's /usr/sbin/update-ca-certificates.
    machine.succeed(
        f"nsenter --mount --target {pid} "
        "touch /etc/pki/ca-trust/source/anchors/probe.crt"
    )
    machine.succeed("test -e /var/lib/netskope/ca-anchors/probe.crt")  # lands in statePath
    machine.succeed(f"nsenter --mount --target {pid} /usr/bin/update-ca-trust")
    machine.fail(f"nsenter --mount --target {pid} test -e /usr/sbin/update-ca-certificates")

    # None of that may leak onto the host: these paths exist only in the namespace.
    machine.fail("test -e /usr/bin/update-ca-trust")
    machine.fail("test -e /etc/pki/ca-trust/source/anchors")
    # NixOS' own bundle sits in /etc/pki/tls and must survive the /etc/pki/ca-trust
    # overlay.
    machine.succeed(f"nsenter --mount --target {pid} test -e /etc/pki/tls/certs/ca-bundle.crt")
  '';
}
