# netskope-client (NixOS)

A NixOS flake that packages the proprietary **Netskope Client for Linux** (x86_64) and
exposes it as a NixOS module. Planning and decisions are tracked as a
[wayfinder map](https://github.com/lcleveland/netskope-client/issues/1).

> **Status: work in progress.** The packaging derivation (this commit) is complete but
> has **not yet been build-verified on a Nix host** — it was authored in an environment
> without Nix. Enrollment, CA trust, and writable-state relocation are not implemented
> yet (see the map).

## Getting the installer

The client is proprietary, **rebuilt per tenant, and not redistributable**, so you must
supply `NSClient.run` yourself:

1. Download it from your tenant — admin console **Settings → Tools → Downloads → Linux**
   (choose the `.run`), or `https://download-<tenant>.goskope.com/dlr/linux/get`.
2. Add it to the Nix store:

   ```sh
   nix-store --add-fixed sha256 NSClient.run
   ```

The pinned default hash targets the `lselectric` **v140.0.2.2763** build. If your tenant
serves a different build, override the `src` argument of the package.

## Usage

```nix
{
  inputs.netskope.url = "github:lcleveland/netskope-client";

  # in your NixOS configuration:
  imports = [ netskope.nixosModules.default ];
  nixpkgs.config.allowUnfree = true;   # the client is unfree
  services.netskope.enable = true;
  services.netskope.enableTray = true; # false = daemon-only, drops the GTK/WebKit closure
}
```

## Packaging approach

- **Strategy: `autoPatchelfHook`** over a user-supplied `NSClient.run`.
  The `.run` is a Makeself self-extractor; the payload (a raw client tree) is carved out
  by the header's declared offset — no `dpkg`/`.deb` step.
- Only `stAgentUI` (the tray) links stale sonames; they're rewritten with
  `patchelf --replace-needed` (WebKitGTK 4.0→4.1, JSCore 4.0→4.1, appindicator3→ayatana)
  before autoPatchelf resolves the rest. Every other binary needs only stdlibs (and NSS
  for the bundled `certutil`), and none carry a RUNPATH — so autoPatchelf is a clean fit.
  `buildFHSEnv` is the documented fallback if `/opt` path assumptions prove too brittle.

## Layout

- `flake.nix` — outputs: `packages.x86_64-linux.*`, `nixosModules.default`, `devShell`, `formatter`.
- `pkgs/netskope-client.nix` — the package derivation.
- `modules/netskope.nix` — the NixOS module (prototype: package + daemon unit only).
