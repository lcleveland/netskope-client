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
> What remains is only `trustCA`: under steering the tenant re-signs every HTTPS
> connection, so anything on the system trust store fails until its CA is trusted.

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

    trustCA = true;
    caCertFile = "/etc/netskope/nstenantcert.crt";
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

The daemon shells out to a handful of commands and looks for them at **`/usr/sbin/<name>`**
— *not* through `PATH`. `systemd.services.stagentd.path` therefore does nothing for it;
the commands are bound into `/usr/sbin` inside the unit's namespace instead (`fhsTools`).
That took some proving: with `iproute2` on the unit's PATH the daemon still logged
`Command ip not found!`, and it still did with `/usr/bin/ip` in place. Only `/usr/sbin/ip`
silenced it.

It wants `ip`, `iptables`, `ip6tables`, `dmidecode` and `resolvectl`; everything else in
its string table (`dpkg`, `rpm`, `realm`, `pgrep`, `traceroute`, …) goes unused here.
One name is deliberately *withheld*: `update-ca-certificates`, whose presence would
send the CA installer down its Debian branch (see [Tenant CA install](#tenant-ca-install)).

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

### What is left: `trustCA`

With steering live the tenant re-signs every HTTPS connection:

```
issuer: O=<org>; CN=ns-swg.ca.<tenant>.goskope.com
curl (system trust):  (60) self-signed certificate in certificate chain
curl --cacert <tenant CA>: 200
```

So until the tenant CA is in the system trust store, HTTPS fails everywhere. Set
`trustCA = true` and point `caCertFile` at the cert the enrolled client wrote to
`${statePath}/ca-anchors/nstenantcert.crt`. The module warns when steering can run
without it.

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
| `trustCA` / `caCertFile` | add the Netskope root CA to system trust |
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
