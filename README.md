# netskope-client (NixOS)

A NixOS flake that packages the proprietary **Netskope Client for Linux** (x86_64) and
exposes it as a NixOS module. Planning and decisions are tracked as a
[wayfinder map](https://github.com/lcleveland/netskope-client/issues/1).

> **Status: work in progress** ([#10](https://github.com/lcleveland/netskope-client/issues/10)).
> Verified on a real host: the package builds, every binary's libraries resolve,
> `stagentd` plus the tray user service start, `stAgentCli` reaches the daemon through
> the IPC peer check, and the **enrollment handshake completes against a live tenant**
> (`Successfully downloaded branding file by email id`). The VM test (`nix build
> .#checks.x86_64-linux.module`) passes.
>
> Enrollment is verified on the host, not just in a sandbox: `netskope-enroll.service`
> exits 0, the daemon picks the branding file up on its own retry timer without a
> restart, and `stAgentCli show-config` reports the tenant gateway, organization and
> steering config. Getting there turned up four defects, all now fixed — see
> [Enrollment gotchas](#enrollment-gotchas). The big one is that the client's OpenSSL
> **CApath of `/etc/ssl/certs` is unusable on NixOS**, so *every* TLS request it made
> failed.
>
> A fifth defect surfaced immediately after: the client installs the tenant CA into
> the system trust store itself, and aborts its whole config cycle when that fails —
> see [Tenant CA install](#tenant-ca-install).
>
> A sixth: steering needs `ip`, which the client looks for at `/usr/sbin/ip` and
> nowhere else — not on `PATH`. Its absence is silent: the tunnel connects, then the
> filter device fails to start and the client reports `Internet Security disabled due
> to error` while looking healthy.
>
> **Steering works**, and the reason it did not is NixOS-specific: the default
> **strict reverse-path filter DROPs every steered reply**, taking the whole network
> down within ~27s of the tunnel coming up. The module now defaults
> `networking.firewall.checkReversePath` to `"loose"` — see [Steering](#steering).
> Measured on a real host: with that one change, 90s of live steering with DNS and TCP
> up throughout and traffic verifiably flowing through the tenant's gateway.
>
> Under steering the tenant re-signs every HTTPS connection, so the system trust store
> has to accept its CA. `trustCA = true` handles that **without any certificate in your
> configuration** — it trusts the copy the client downloads for itself, and follows CA
> rotation. See [Trusting the tenant CA](#trusting-the-tenant-ca--without-putting-it-in-your-config).
>
> A seventh and eighth came from a laptop that docks and roams: the client's
> **DNS-cache flush never once ran** (missing tools, while the layer above it logged
> success), and `.local` resolution stayed **pinned to the DNS servers of the network
> the tunnel started on**, because `sta0` outlives an uplink change and the unit that
> configures it sampled them once. See [Switching networks](#switching-networks). The
> flush also settled a rule that had been half-right since the beginning: the client
> wants each helper in the directory FHS would keep it in, so `fhsTools` is bound at
> `/usr/bin` *and* `/usr/sbin` — see [Runtime tools](#runtime-tools).
>
> Not yet verified on a host: that combination in one run. The rpfilter fix and the
> steering behaviour above are measured; runtime CA trust is covered by the VM test but
> has not yet been through a live steering session. The flush is verified only in the
> negative so far — `/usr/sbin` alone provably did *not* fix it on a real host, and the
> `/usr/bin` half is one rebuild away from being confirmed there.

## Quick start

```nix
{
  inputs.netskope.url = "github:lcleveland/netskope-client";

  # ... in your NixOS configuration:
  imports = [ netskope.nixosModules.default ];
  nixpkgs.config.allowUnfree = true; # the client is unfree

  services.netskope = {
    enable = true;
    tenant = "lselectric";  # fetches the installer from the tenant (public, no auth)
    hash = "sha256-lOAsV+/zV1KNZBraDw8qa7nL4SDu0GH3who7fgLhQTI="; # bump on version change

    enrollment = {
      orgKeyFile    = "/run/secrets/netskope-orgkey";    # value of Windows `token=`
      authTokenFile = "/run/secrets/netskope-authtoken"; # value of Windows `enrollauthtoken=`
      email         = "user@example.com";                # required (or `upn`) — see below
    };

    # Trust the tenant's SSL-inspection CA so HTTPS keeps working under steering.
    # No certificate file needed: it uses the copy the client downloads for itself.
    trustCA = true;
  };
}
```

## Client source

The installer is fetched from `https://download-<tenant>.goskope.com/dlr/linux/get`
(**public, no authentication**) — just set `tenant` + `hash`. The hash changes when
Netskope pushes a new client version to your tenant; refresh it with:

```sh
nix store prefetch-file --name NSClient.run \
  "https://download-<tenant>.goskope.com/dlr/linux/get"
```

Alternatives: `sourceUrl` (an internal mirror) + `hash`; or offline via `requireFile`
(`nix-store --add-fixed sha256 NSClient.run`) or
`package = pkgs.netskope-client.override { srcOverride = ./NSClient.run; }`
(the argument is `srcOverride` rather than `src` so that `callPackage` cannot
auto-fill it from nixpkgs' throwing `pkgs.src` rename alias).
The installer is **proprietary and non-redistributable** — don't commit it.

## Secrets

`enrollment.orgKeyFile` / `authTokenFile` / `encryptTokenFile` are **absolute paths to
runtime files** (typed as strings, never Nix paths, so they are never copied into the
world-readable `/nix/store`). Provide them via sops-nix, agenix, or a root-only file; the
enrollment service reads them through systemd credentials at activation.

## Enrollment gotchas

Four things that each silently break enrollment, found by running the real
`installerutil` against a live tenant. All four are handled by the module now; they are
recorded here because none of them produce an error that points at the cause.

1. **`tenantHost` is the tenant host, not the addon host.** The client prefixes
   `addon-` itself, so `addon-corp.goskope.com` becomes
   `addon-addon-corp.goskope.com` and dies with `curl_easy_perform failed, code 6,
   error Could not resolve hostname`. Windows deployment strings put the *addon* host
   in `host=`, so this is the natural thing to copy in — the module now asserts
   against the prefix at eval time.
2. **`/etc/ssl/certs` is not a usable OpenSSL CApath on NixOS.** The client verifies
   peers with a compiled-in `CApath=/etc/ssl/certs` and no CAfile (it only picks a
   CAfile on Fedora/RHEL, gated on `/etc/{fedora,redhat}-release`). A CApath resolves
   trust anchors through `<subject-hash>.<seq>` symlinks; NixOS ships only
   `ca-bundle.crt` and `ca-certificates.crt`, so the client finds **zero** anchors and
   every TLS handshake fails with `peer cert verify err: 19, self-signed certificate
   in certificate chain` / curl code 60. `SSL_CERT_DIR`, `SSL_CERT_FILE` and
   `CURL_CA_BUNDLE` are all ignored. The module builds a rehashed copy of
   `security.pki.caBundle` and `BindReadOnlyPaths`-mounts it over `/etc/ssl/certs` for
   the client's units only — no system-wide change.
3. **`enrollment.email` (or `upn`) is required.** An org key plus auth token is not
   enough: with both unset the client picks UPN mode, shells out to `realm list` for
   the AD domain, and fails with `Can't find domain from: realm list` on any host that
   is not domain-joined.
4. **The `MyRunFileName` envelope field must be non-empty.** `installerutil` validates
   it before doing anything else and exits 1 with `Invalid options, MyRunFileName not
   found!` without sending a packet. Nothing opens the file, so a placeholder path is
   enough.

A useful way to reproduce enrollment without touching system state: copy the app dir
into a tmpfs inside `unshare --mount --map-root-user`, bind it over
`/opt/netskope/stagent`, and run `installerutil --download_branding_file '<envelope>'`
there. Results land in `logs/nsInstallation.log`.

## Tenant CA install

Once enrolled, the daemon downloads the Netskope root and tenant CAs and installs them
into the **system** trust store itself — and treats failure as fatal to the entire
config update:

```
failed to open file for writing: /etc/pki/ca-trust/source/anchors/nscacert.crt, err: 2
cert system ca cert is not installed
Install CA failed, ca rotation status 2, 0
config update failed, retry in 9 minutes
```

So enrollment succeeds and then the client never converges — it rolls the config back
every nine minutes. `cert.cpp` picks its layout by probing for
`/usr/sbin/update-ca-certificates` (Debian: write `/usr/local/share/ca-certificates`,
then run that tool), falling back to the RHEL pair
`/etc/pki/ca-trust/source/anchors` + `/usr/bin/update-ca-trust`. Neither exists here.

`stagentd.service` therefore gets, **inside its own mount namespace only**: empty
tmpfs mounts over `/usr` and `/etc/pki/ca-trust` (blanking `/usr` makes the layout
choice ours rather than the host's), a writable anchors dir bound from
`${statePath}/ca-anchors`, and a shim for `update-ca-trust` that succeeds without
doing anything. Nothing new appears on the host — the VM test asserts that.

The shim is a no-op on purpose: this system's trust store is built from
`security.pki.certificateFiles` at activation, not from a mutable anchors dir, and
trusting a MITM CA system-wide stays an explicit opt-in via `trustCA`. The useful
side effect is that `${statePath}/ca-anchors/` is where the tenant CA lands in PEM
form — which is what `caCertFile` needs, and the installer ships no CA.

## Runtime tools

The daemon shells out to a handful of commands and looks for them by **absolute FHS
path** — *not* through `PATH`. `systemd.services.stagentd.path` is therefore not
sufficient on its own; the commands are bound into the unit's namespace instead
(`fhsTools`). That took some proving: with `iproute2` on the unit's PATH the daemon still
logged `Command ip not found!`, and it still did with `/usr/bin/ip` in place. Only
`/usr/sbin/ip` silenced it.

And it wants each tool in the directory a real FHS distro would keep it in, which is why
`fhsTools` is bound at **both** `/usr/bin` and `/usr/sbin`. Populating only `/usr/sbin`
got `ip`, `iptables`, `ip6tables`, `dmidecode` and `sysctl` working while every
`/usr/bin` tool stayed invisible: `resolvectl`, `systemd-resolve` and `pidof` were all
present under `/usr/sbin` *and* on PATH, and the DNS flush still reported
`Flush DNS command not found!` on a host where `pidof systemd-resolved` answers
instantly from any other shell. Two directories of symlinks cost nothing; guessing one
per tool gets it wrong half the time.

It wants `ip`, `iptables`, `ip6tables`, `dmidecode`, `resolvectl`, `systemd-resolve`,
`pidof` and `sysctl`; everything else in its string table (`dpkg`, `rpm`, `realm`,
`pgrep`, `traceroute`, …) goes unused here. One name is deliberately *withheld*:
`update-ca-certificates`, whose presence would send the CA installer down its Debian
branch (see [Tenant CA install](#tenant-ca-install)). `update-ca-trust`, the RHEL tool
it *does* call, lives in `fhsTools` too rather than in a bind of its own — a file bind
over a path inside a read-only directory bind needs the file to exist in it first.

The last three tools arrived later than the rest, from chasing
[network switching](#switching-networks), and two of them exist only to make the
DNS-cache flush work at all.

`ip` is the one that matters, and losing it fails in a way that is easy to misread:

```
nsTunHandler.cpp:516  Failed to find ip or iptables command
nsNetTool.cpp:79      Command ip not found!
tunnelMgr.cpp:1288    failed to start filter device
tunnel.cpp:447        TLS received nsssl_closed, tunnel destroyed
```

The TLS tunnel to the POP comes up first and is reported as established, complete with
an assigned IP — only then does the filter device that intercepts traffic fail, so the
daemon stays running, the tray shows a connection, and nothing is actually steered.
The client drives its TUN device with `ip route` / `ip rule` (policy routing on table 1
with an fwmark) and asks `ip route get` for the egress interface, which is also why a
missing `ip` shows up as `Failed to get MTU on device = `.

## Steering

**Status: works.** The blocker was NixOS' reverse-path filter, and it is the single
nastiest failure in this whole exercise: connectivity dies ~25s *after* the client
reports everything healthy, and stays dead until the daemon is killed.

`networking.firewall.checkReversePath` defaults to `true` on NixOS, which installs a
**strict** filter ending in `DROP`, in mangle `PREROUTING`:

```
-A nixos-fw-rpfilter -m rpfilter --validmark -j RETURN
-A nixos-fw-rpfilter -j DROP
```

Steering is asymmetric by construction. Packets leave through the tunnel device
(`fwmark 0x5` → table 9 → `default dev sta0`) and their replies arrive back **on
`sta0`**, while the route to those source addresses is via the physical interface.
Strict rpfilter drops every one of them.

The module therefore sets `networking.firewall.checkReversePath = mkDefault "loose"` —
the same thing nixpkgs' tailscale module does, and overridable if you disagree.

Measured on a real host, ~90s of live steering per run:

| | strict (default) | `"loose"` |
|---|---|---|
| DNS / TCP | dead within ~27s | up for the whole window |
| unsteered ICMP | fine throughout | fine |
| traffic through tenant SWG | — | confirmed, 17/17 samples |
| recovery | kill the daemon | n/a |

Unsteered ICMP surviving while steered TCP/DNS died is the fingerprint: it is the
*return path* being dropped, not the network being down.

### The tunnel device

`sta0` — not `tun*`, which is worth knowing before you go looking for it. Under
steering it carries `100.65.0.2/16`, and table 9 holds `default dev sta0` plus
per-destination bypasses for the corporate ranges.

### Trusting the tenant CA — without putting it in your config

With steering live the tenant re-signs every HTTPS connection:

```
issuer: O=<org>; CN=ns-swg.ca.<tenant>.goskope.com
curl (system trust):  (60) self-signed certificate in certificate chain
curl --cacert <tenant CA>: 200
```

So until the tenant CA is trusted, HTTPS fails everywhere — the client works, the rest
of the desktop does not. `trustCA = true` is the whole fix; **no certificate file is
required**.

That takes some doing, because the two halves don't line up: a NixOS trust store is
assembled at **build** time from `security.pki.certificateFiles`, while the only copy
of the tenant CA most hosts will ever have is fetched by the client at **runtime**. A
runtime file cannot feed a build-time bundle, and under flakes it cannot even be read
at eval:

```
error: access to absolute path '/var/lib/netskope/ca-anchors/nstenantcert.crt'
       is forbidden in pure evaluation mode
```

Making every user copy their tenant's certificate into their own configuration is not
a solution — it is per-user manual work that also goes stale the moment the tenant
rotates its CA.

So `netskope-ca-trust.service` assembles the bundle at runtime — the system's own CA
bundle plus whatever the client has fetched into `${statePath}/ca-anchors` — writes
both the bundle and the hashed CApath layout, and bind-mounts the result over
`/etc/ssl/certs`. A `systemd.path` unit watching the anchors directory rebuilds it when
the tenant rotates, so rotation is handled without anyone editing anything.

Before the client has fetched anything the mount is exactly the system trust store, so
it is inert rather than dangerous. `caCertFile` still exists for anyone who does have
the certificate at eval time and would rather pin it.

This is opt-in and off by default: it trusts a MITM CA system-wide, which should be a
deliberate act.

### Testing steering safely

`tools/steering-test.sh` brings the client up under a dead-man's switch: it probes
connectivity every 3s and tears everything down the moment it dies, on a hard timeout,
or if the script is killed. Two things it learned the hard way, both of which will bite
anyone doing this by hand:

- **`systemctl stop stagentd` is not a backout.** Its shutdown path does network work
  that hangs when the network is down; 30s after `stop` it was still running, rules
  still installed. Use `systemctl stop --no-block` *then* `systemctl kill -s KILL`.
- **Order matters.** `kill -s KILL` on its own makes systemd restart it, because the
  unit is `Restart=always`. Mark it stopping first.

Even then the client cleans up nothing when killed, so the harness removes the
`fwmark` rule, flushes table 9, deletes `sta0` and restarts `firewall.service` itself.

## Switching networks

A laptop that docks, undocks and roams between wifi networks changes its uplink
underneath a tunnel that does not go anywhere. `sta0` belongs to the tunnel, not to the
uplink, and it **outlives an uplink change** — which turned up two defects, both
NixOS-specific and both invisible unless you read the client's own log.

**The DNS cache was never flushed.** The client flushes the resolver cache when the
network changes, which is the one moment it really has to: answers learned from the
network you just left are worse than no answers. On this host every attempt failed,
and the layer above it reported success anyway:

```
npaTunnelMgr.cpp:2175  System DNS cache is flushed, when NPA set domain and IP rules.
nsNetTool.cpp:540      NetTool Flush DNS command not found!
```

Three names are involved. `linux/flushDns.cpp` composes either `systemd-resolve
--flush-caches` or `resolvectl flush-caches`, and gates both on
`pidof systemd-resolved` — which is where the one remaining shell error comes from,
since a failed lookup leaves the composed command as nothing but its argument:

```
stAgentSvc[2818]: sh: line 1: systemd-resolved: command not found
```

…whereupon it concludes `skip flushDNS since systemd-resolved is not running`, on a host
where resolved is the only resolver there is. `systemd-resolve` is the pre-v239 name and
a symlink to `resolvectl` in the same package, so naming it costs nothing.

**The first attempt at this fixed only half of it, which is what pinned down the
directory rule.** Adding all three under `/usr/sbin`, plus `procps` on the unit's PATH,
silenced `sysctl: command not found` completely — and changed nothing about the flush.
`resolvectl`, `systemd-resolve` and `pidof` were all sitting in `/usr/sbin` and on PATH,
`pidof systemd-resolved` answered instantly from any other shell on the box, and the
daemon still logged `Flush DNS command not found!` on every attempt. They are `/usr/bin`
tools on an FHS distro; `ip` and `sysctl` are `/usr/sbin` ones. `fhsTools` is now bound
at both paths — see [Runtime tools](#runtime-tools).

`sysctl` came along for the ride: `npaTunnelMgr` reads
`sysctl -n net.core.{r,w}mem_max` to size the Private Access tunnel's socket buffers and
was falling back to defaults after the same kind of failure
(`sh: line 1: sysctl: command not found`, now gone).

**`.local` resolution was pinned to the network it started on.** `netskope-npa-dns`
copies the uplink's DNS servers onto `sta0` (see [The tunnel device](#the-tunnel-device));
as a oneshot triggered by `sta0` appearing, it sampled them exactly once. Measured on a
real host, docking moved the client's uplink three times in twenty seconds and
re-enumerated the dock's NIC (`eth0` ifindex 6 → 7):

```
nsDnsMgr.cpp:927  Uplink DNS 10.2.75.10 OIF wlp2s0/4 -> eth0/6; rebuilding socket
nsDnsMgr.cpp:927  Uplink DNS 10.2.75.10 OIF eth0/6 -> wlp2s0/4; rebuilding socket
nsDnsMgr.cpp:927  Uplink DNS 10.2.75.10 OIF wlp2s0/4 -> eth0/7; rebuilding socket
```

`sta0` stayed up through all of it and the unit never re-ran. Dock to wifi and the
servers on `sta0` are the ones the *docked* network handed out — normally unreachable
from the new one — so Private Access names go to a dead resolver while every other
symptom looks healthy. The unit now applies once, reports ready, and then follows
`ip monitor link address route` for the life of the tunnel: it coalesces the burst a
single dock swap produces, reconfigures resolved only when the (uplink, servers) pair
actually changes, and re-checks every 60s regardless, since `ip monitor` drops messages
on receive-buffer overrun. Mid-switch moments with no default route or no lease yet
leave the previous setting alone rather than tearing `.local` down for a blip — another
event is always coming.

One thing that looks like a defect and is not: `nsRtNetlink ipRouteGet: failed to get
response`, four of them after every network-change event, from the bypass-route
handler. They are IPv6 route lookups on a host with no IPv6 route — `ip route get` on a
global v6 address answers `Network is unreachable` by hand too.

## Options

| Option | Purpose |
|---|---|
| `enable` | turn the client on |
| `tenant` / `hash` / `sourceUrl` | client source (see above) |
| `package` | override the built package |
| `statePath` (default `/var/lib/netskope`) | all mutable client state; the one path to persist |
| `enableTray` (default `true`) | tray UI: `stagentapp` (watchdog) + `stagentui` (icon) user services + launcher entry |
| `tenantHost` | tenant hostname, **not** the addon host (defaults to `<tenant>.goskope.com`) |
| `enrollment.{orgKeyFile,authTokenFile,encryptTokenFile,email,upn}` | enrollment params |
| `trustCA` | trust the tenant CA system-wide, from the client's own runtime copy |
| `caCertFile` | optional: pin a CA at build time instead (must be in the flake) |
| `autoStart` (default `true`) | start the daemon at boot; false = start it by hand |
| `autoUpdate` (default `false`) | client self-update — unsupported on Nix |

## Packaging approach

`autoPatchelfHook` over the `.run` payload (carved by the makeself header offset — no
`dpkg`). Only `stAgentUI` needs soname swaps (WebKitGTK 4.0→4.1, JSCore 4.0→4.1,
appindicator3→ayatana); everything else needs stdlibs (and NSS for `certutil`).
`buildFHSEnv` is the documented fallback.

The client hard-codes `/opt/netskope/stagent`, both reading its shipped files and
writing state there. It also authenticates every IPC peer by resolving the connecting
process's `/proc/<pid>/exe` against a hard-coded allowlist of
`/opt/netskope/stagent/{stAgentApp,stAgentCli,stAgentUI,nsdiag,bwansvc}` — so the
shipped files have to be **real files at that path**. Symlinking them in from the store
makes every peer resolve to `/nix/store/...` and get rejected (`NSCOM2 invalid client
connection`, `handleNewClient failed -8`), which breaks the tray and `stAgentCli` while
leaving `stagentd` looking perfectly healthy.

So the module keeps the real directory at `${statePath}/app` (copied out of the store,
refreshed when the package changes) and **bind-mounts** it onto `/opt/netskope/stagent`.
A bind mount preserves the visible path, unlike a symlink, so the peer check passes.

## Impermanence

Every mutable file — device identity (`.mid`, `provisioning`), config
(`nsconfig.json`, `nsuser.conf`), the enrollment result (`nsbranding.json`), `data/`
and `logs/` — lives under `statePath` (default `/var/lib/netskope`). On a tmpfs-root
host that single directory is the only thing to persist:

```nix
environment.persistence."/persist".directories = [ "/var/lib/netskope" ];
```

Nothing under `/opt` needs persisting — it is re-materialised on every activation.
Without persistence the client loses its identity each boot and re-registers as a
brand-new device in the tenant.

## Layout

- `flake.nix` — `packages`, `nixosModules.default`, `checks` (VM test), `devShell`, `formatter`.
- `pkgs/netskope-client.nix` — the package derivation.
- `modules/netskope.nix` — the NixOS module.
- `tests/module.nix` — VM test (scaffold; run under #10).
