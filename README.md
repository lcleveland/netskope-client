# netskope-client (NixOS)

A NixOS flake that packages the proprietary **Netskope Client for Linux** (x86_64) and
exposes it as a NixOS module. Planning and decisions are tracked as a
[wayfinder map](https://github.com/lcleveland/netskope-client/issues/1).

> **Status: work in progress** ([#10](https://github.com/lcleveland/netskope-client/issues/10)).
> Verified on a real host: the package builds, every binary's libraries resolve, and
> `stagentd` plus the tray user service start. The VM test (`nix build
> .#checks.x86_64-linux.module`) passes.
>
> Not yet verified: the **enrollment handshake** (still needs a tenant org key + auth
> token), and the bind-mount peer-path fix has only been exercised in the VM test with a
> stub package — not yet against the real client on a host.

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

## Options

| Option | Purpose |
|---|---|
| `enable` | turn the client on |
| `tenant` / `hash` / `sourceUrl` | client source (see above) |
| `package` | override the built package |
| `statePath` (default `/var/lib/netskope`) | all mutable client state; the one path to persist |
| `enableTray` (default `true`) | tray UI: `stagentapp` (watchdog) + `stagentui` (icon) user services + launcher entry |
| `tenantHost` | enrollment host (defaults to `addon-<tenant>.goskope.com`) |
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
