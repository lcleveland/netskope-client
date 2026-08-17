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
> Getting enrollment to work turned up four defects, all now fixed — see
> [Enrollment gotchas](#enrollment-gotchas). The big one is that the client's OpenSSL
> **CApath of `/etc/ssl/certs` is unusable on NixOS**, so *every* TLS request it made
> failed.
>
> Not yet verified: what happens after the branding file lands — the daemon's own
> secure-enrollment (user cert) and traffic steering.

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
