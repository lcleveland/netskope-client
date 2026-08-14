# netskope-client (NixOS)

A NixOS flake that packages the proprietary **Netskope Client for Linux** (x86_64) and
exposes it as a NixOS module. Planning and decisions are tracked as a
[wayfinder map](https://github.com/lcleveland/netskope-client/issues/1).

> **Status: work in progress.** The module is feature-complete — packaging, writable-state
> relocation, headless token/org-key enrollment, and CA trust — but has **not** been build-
> or run-verified on a Nix host yet ([#10](https://github.com/lcleveland/netskope-client/issues/10)).
> Verify before relying on it; the enrollment handshake in particular is untested.

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
`package = pkgs.netskope-client.override { src = ./NSClient.run; }`.
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
| `enableTray` (default `true`) | tray UI: `stAgentUI` + `stagentapp` user service |
| `tenantHost` | enrollment host (defaults to `addon-<tenant>.goskope.com`) |
| `enrollment.{orgKeyFile,authTokenFile,encryptTokenFile,email,upn}` | enrollment params |
| `trustCA` / `caCertFile` | add the Netskope root CA to system trust |
| `autoUpdate` (default `false`) | client self-update — unsupported on Nix |

## Packaging approach

`autoPatchelfHook` over the `.run` payload (carved by the makeself header offset — no
`dpkg`). Only `stAgentUI` needs soname swaps (WebKitGTK 4.0→4.1, JSCore 4.0→4.1,
appindicator3→ayatana); everything else needs stdlibs (and NSS for `certutil`).
`buildFHSEnv` is the documented fallback. The client hard-codes `/opt/netskope/stagent`
and writes state there, so the module materialises that path as a real directory with
`data/` and `logs/` redirected to `/var/lib/netskope`.

## Layout

- `flake.nix` — `packages`, `nixosModules.default`, `checks` (VM test), `devShell`, `formatter`.
- `pkgs/netskope-client.nix` — the package derivation.
- `modules/netskope.nix` — the NixOS module.
- `tests/module.nix` — VM test (scaffold; run under #10).
