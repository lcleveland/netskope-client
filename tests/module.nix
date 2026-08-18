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
      environment.systemPackages = [
        pkgs.openssl # to mint a stand-in tenant CA
        pkgs.socat # to hold open a socket the rebind sweep must not touch
      ];
      services.resolved.enable = true; # the Private Access DNS fix acts on resolved
      services.netskope = {
        enable = true;
        enableTray = false; # daemon-only: no GTK/WebKit closure in the test
        package = stub; # avoid fetching the real (proprietary) client
        # Deliberately WITHOUT caCertFile: the point of trustCA is that it works from
        # the certificate the client fetches at runtime, so nobody has to put their
        # tenant's CA into their configuration.
        trustCA = true;
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

    # autoStart's escape hatch has to actually work: stopping the daemon must be
    # enough to take the client out of the traffic path, and it must not come back
    # on its own. (Restart=always applies to the process dying, not to `stop`.)
    machine.succeed("systemctl stop stagentd.service")
    machine.succeed("sleep 12")  # outlives RestartSec=10
    machine.fail("systemctl is-active --quiet stagentd.service")
    machine.succeed("systemctl start stagentd.service")
    machine.wait_for_unit("stagentd.service")

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

    # trustCA has to work with no certificate in the configuration: the tenant CA only
    # exists as a file the client fetches at runtime, and a NixOS trust store is built
    # at eval time, so the module assembles the bundle at runtime and bind-mounts it.
    # The unit is a oneshot without RemainAfterExit -- it has to be able to run again
    # when the path unit fires on a rotation -- so wait on its effect, not its state.
    machine.wait_until_succeeds("mountpoint -q /etc/ssl/certs")
    machine.succeed(
        "systemctl show -p Result --value netskope-ca-trust.service | grep -qx success"
    )
    # Before anything is fetched it must be exactly the system trust store, not empty
    # -- this directory is /etc/ssl/certs for the whole machine.
    machine.succeed("grep -q 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-bundle.crt")
    machine.succeed("test -e /etc/ssl/certs/ca-certificates.crt")
    system_certs = int(machine.succeed("grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-bundle.crt"))

    # Now simulate the client fetching a tenant CA, and a rotation after it.
    machine.succeed(
        "openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.pem "
        "-out /var/lib/netskope/ca-anchors/nstenantcert.crt -days 1 -subj /CN=fake-tenant-ca"
    )
    machine.succeed("systemctl start netskope-ca-trust.service")
    after = int(machine.succeed("grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-bundle.crt"))
    assert after == system_certs + 1, f"tenant CA not merged: {system_certs} -> {after}"
    # ...and it is the same certificate, not merely one more of something.
    machine.succeed(
        "grep -qFf /var/lib/netskope/ca-anchors/nstenantcert.crt /etc/ssl/certs/ca-bundle.crt"
    )

    # ... and that the hashed CApath layout is regenerated alongside it, since the
    # Netskope client itself consumes /etc/ssl/certs as a CApath rather than a CAfile.
    machine.succeed("find /etc/ssl/certs -name '*.0' | grep -q .")

    # The daemon must end up trusting what the system trusts. This is easy to get
    # wrong -- it has its own /etc/ssl/certs, and pointing that at a build-time bundle
    # makes it the one process on the machine that does NOT trust the tenant. That is
    # not cosmetic: the client is not exempt from its own SSL inspection, so once
    # steering is live its calls to achecker-<tenant>.goskope.com are re-signed too,
    # and failing them breaks Private Access resolution (SERVFAIL) while every other
    # symptom looks healthy.
    machine.succeed("systemctl restart stagentd.service")
    machine.wait_for_unit("stagentd.service")
    pid = machine.succeed("systemctl show -p MainPID --value stagentd.service").strip()
    daemon_certs = int(
        machine.succeed(
            f"nsenter --mount --target {pid} grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-bundle.crt"
        )
    )
    assert daemon_certs == after, f"daemon trusts {daemon_certs} CAs, system trusts {after}"
    machine.succeed(
        f"nsenter --mount --target {pid} "
        "grep -qFf /var/lib/netskope/ca-anchors/nstenantcert.crt /etc/ssl/certs/ca-bundle.crt"
    )

    # Private Access names are commonly published under `.local`, which
    # systemd-resolved refuses to send to unicast DNS at all -- so the query dies
    # inside resolved and never reaches the client, which would have answered it.
    # The routing domain goes on the tunnel interface, which the client creates when
    # the tunnel comes up; stand in a dummy device of that name.
    machine.succeed("ip link add sta0 type dummy && ip link set sta0 up")
    # The VM's link has no DNS of its own; give it one, since copying the
    # default-route link's servers onto the tunnel is half of what the unit does.
    # (With none, the unit correctly declines to touch anything -- also worth having
    # exercised, which the run before this assertion does.)
    link = machine.succeed("ip -o route show default | awk '{print $5; exit}'").strip()
    machine.succeed(f"resolvectl dns {link} 192.0.2.53")
    machine.wait_until_succeeds("systemctl restart netskope-npa-dns.service")
    machine.succeed("resolvectl domain sta0 | grep -q '~local'")
    # ...pointed at the DNS servers of the default-route link, because the client only
    # answers queries aimed at the system's own resolver.
    machine.succeed("resolvectl dns sta0 | grep -qE '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+'")
    # ...and without disturbing the link NetworkManager (or whatever) manages, since
    # reverting a managed link wipes the DNS servers it pushed.
    machine.succeed(f"resolvectl domain {link} | grep -qv '~local'")
    machine.succeed(f"resolvectl dns {link} | grep -q 192.0.2.53")

    # Docking, or moving to wifi, changes the uplink's DNS servers while sta0 -- which
    # belongs to the tunnel, not the uplink -- stays exactly where it is. Sampling the
    # servers once would strand `.local` on the resolver of the network that has been
    # left behind, so the unit follows netlink for as long as the tunnel lives. Change
    # the servers WITHOUT touching the unit, and they must follow on their own.
    machine.succeed(f"resolvectl dns {link} 192.0.2.54")
    # Nudge netlink the way a real uplink change does: the DNS servers themselves are
    # invisible to `ip monitor`, and a dock swap always brings address/route churn with
    # it. (The 60s poll would catch it regardless -- that is the backstop, not the path
    # under test here.)
    machine.succeed(f"ip addr add 192.0.2.1/32 dev {link}")
    machine.wait_until_succeeds("resolvectl dns sta0 | grep -q 192.0.2.54")
    machine.succeed("resolvectl domain sta0 | grep -q '~local'")

    # The client keeps its tunnel bound to the source address of an uplink that has
    # gone away, and only rebuilds when its own keepalive expires -- 2m14s of DNS
    # working while nothing on 80/443 loads. netskope-tunnel-rebind closes any of the
    # client's sockets whose local address is no longer configured, which the client
    # recovers from in ~1.3s.
    #
    # Killing a socket the client owns needs a real stAgentSvc, so that stays a host
    # check. What IS testable is every way the sweep can be wrong about a socket it
    # must leave alone -- which is the dangerous direction, and where this unit was in
    # fact broken.
    machine.wait_for_unit("netskope-tunnel-rebind.service")
    machine.succeed(
        "socat -u TCP-LISTEN:9999,bind=127.0.0.1,fork,reuseaddr /dev/null "
        ">/dev/null 2>&1 & sleep 1; "
        "exec 3<>/dev/tcp/127.0.0.1/9999; "
        "systemctl restart netskope-tunnel-rebind.service; "
        # Still there: the sweep ran (Type=notify, so the restart returned only once it
        # had) and left a healthy socket that is not the client's alone.
        "ss -Htn state established '( sport = :9999 or dport = :9999 )' | grep -q ."
    )

    # And a socket that IS the client's, on an address that is still configured, must
    # survive too. This is the case that shipped broken: the client binds every tunnel
    # socket to its uplink device, ss renders such a socket as ADDR%IFNAME:PORT, and
    # comparing that qualified form against `ip addr` never matches -- so the sweep
    # closed every socket the client had, on a healthy uplink, every 60s, bouncing the
    # tunnel it was written to keep up.
    #
    # Reproducing it needs all three properties together: a process ss reports as
    # stAgentSvc (the sweep greps for it), a socket bound to a device, and a local
    # address that is still present. A copy of socat under the client's name supplies
    # the first, so-bindtodevice=lo the second.
    machine.succeed("cp $(readlink -f $(type -P socat)) /tmp/stAgentSvc")
    machine.succeed(
        "/tmp/stAgentSvc -u TCP-LISTEN:9998,bind=127.0.0.1,fork,reuseaddr /dev/null "
        ">/dev/null 2>&1 & sleep 1; "
        "sleep infinity | /tmp/stAgentSvc - TCP:127.0.0.1:9998,so-bindtodevice=lo "
        ">/dev/null 2>&1 & sleep 2; "
        # Precondition, not decoration: if the socket is not actually device-bound, or
        # not actually attributed to stAgentSvc, the assertion below proves nothing.
        "ss -Htnp state established '( sport = :9998 or dport = :9998 )' "
        "| grep -q '127.0.0.1%lo' && "
        "ss -Htnp state established '( sport = :9998 or dport = :9998 )' "
        "| grep -q stAgentSvc"
    )
    machine.succeed("systemctl restart netskope-tunnel-rebind.service")
    machine.succeed(
        "ss -Htn state established '( sport = :9998 or dport = :9998 )' | grep -q ."
    )

    # Removing the tunnel takes both followers with it, rather than leaving resolved
    # pointing `.local` at an interface that no longer exists.
    machine.succeed("ip link del sta0")
    machine.wait_until_fails("systemctl is-active --quiet netskope-npa-dns.service")
    machine.wait_until_fails("systemctl is-active --quiet netskope-tunnel-rebind.service")

    # Strict reverse-path filtering DROPs every steered reply (they arrive on the tun
    # while the route to their source is via the physical link), which takes the whole
    # network down within ~27s of the tunnel coming up. The module defaults it to loose.
    machine.succeed(
        "iptables -t mangle -S nixos-fw-rpfilter | grep -q -- '--loose'"
    )

    # Steering needs `ip`, and the client looks for it at /usr/sbin/ip specifically --
    # not on PATH, which is why systemd.services.*.path does not help. Without it the
    # tunnel connects and only then does the filter device fail, leaving a daemon that
    # looks healthy while steering nothing.
    # ...and it wants each tool in the directory FHS would keep it in, so both halves
    # are populated. Shipping only /usr/sbin left every /usr/bin tool invisible --
    # `resolvectl`, `systemd-resolve` and `pidof` all present under /usr/sbin and on
    # PATH, and the DNS flush still reporting "Flush DNS command not found!".
    for tool in [
        "ip",
        "iptables",
        "ip6tables",
        "dmidecode",
        "resolvectl",
        "systemd-resolve",
        "pidof",
        "sysctl",
    ]:
        for d in ["/usr/bin", "/usr/sbin"]:
            machine.succeed(f"nsenter --mount --target {pid} test -x {d}/{tool}")
    machine.succeed(f"nsenter --mount --target {pid} /usr/sbin/ip -V")

    # Whether the flush then WORKS cannot be asserted here: this test runs a stub
    # daemon, and the failure mode lives entirely inside the real client's tool lookup.
    # It has to be read off nsdebuglog on a host -- "Flush DNS command: ..." replacing
    # "Flush DNS command not found!" -- which is why that check is in the README rather
    # than in this file.

    # None of that may leak onto the host: these paths exist only in the namespace.
    machine.fail("test -e /usr/bin/update-ca-trust")
    machine.fail("test -e /etc/pki/ca-trust/source/anchors")
    # NixOS' own bundle sits in /etc/pki/tls and must survive the /etc/pki/ca-trust
    # overlay.
    machine.succeed(f"nsenter --mount --target {pid} test -e /etc/pki/tls/certs/ca-bundle.crt")
  '';
}
