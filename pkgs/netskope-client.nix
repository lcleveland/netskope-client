{
  lib,
  stdenv,
  requireFile,
  fetchurl,
  autoPatchelfHook,
  patchelf,
  gzip,
  gnutar,
  # always-needed runtime libs
  nss, # certutil: libnss3, libnssutil3, libsmime3
  nspr, # certutil: libnspr4, libplc4, libplds4
  # tray-only (stAgentUI) libs
  gtk3,
  webkitgtk_4_1,
  libayatana-appindicator,
  glib,
  pango,
  cairo,
  gdk-pixbuf,
  dbus,
  # options
  enableTray ? true,
  # client source (resolution order is in the `let` block below):
  tenant ? null, # short tenant name -> fetch from download-<tenant>.goskope.com (no auth)
  hash ? null, # hash of the fetched NSClient.run (required with tenant/url)
  url ? null, # explicit installer URL override (mirror); requires hash
  # Explicit source override (path/derivation); wins over everything.
  #
  # Deliberately NOT named `src`: callPackage auto-fills any argument whose name
  # exists in the package set -- including ones that have a default here -- and
  # nixpkgs carries a *throwing* `pkgs.src` rename alias ("The \"src\" package has
  # been renamed to \"simple-revision-control\"", aliases.nix, added 2025-11-19).
  # With the argument named `src`, every plain `pkgs.callPackage` of this file (the
  # module's `package` default, and this flake's own package output) resolved it to
  # that alias and aborted evaluation as soon as the source was forced. The name
  # `srcOverride` collides with nothing in the package set, so the default holds.
  srcOverride ? null,
}:

let
  version = "140.0.2.2763";

  # Client source resolution, in priority order:
  #   1. explicit `srcOverride` (path/derivation)
  #   2. `url` + `hash`         (fetchurl from a mirror)
  #   3. `tenant` + `hash`      (fetchurl from download-<tenant>.goskope.com; public, no auth)
  #   4. requireFile fallback   (offline: `nix-store --add-fixed sha256 NSClient.run`)
  #
  # The download URL is public (verified: no auth), but the file is proprietary and
  # rebuilt per tenant/version, so its hash is not universal -- the user pins `hash`
  # and bumps it when Netskope ships a new client build.
  downloadUrl =
    if url != null then
      url
    else if tenant != null then
      "https://download-${tenant}.goskope.com/dlr/linux/get"
    else
      null;

  fetchedSrc =
    if downloadUrl == null then
      null
    else if hash == null then
      throw "netskope-client: set `hash` when using `tenant`/`url`. The installer's hash changes per client version; get it with:  nix store prefetch-file --name NSClient.run \"${downloadUrl}\""
    else
      fetchurl (
        {
          url = downloadUrl;
          name = "NSClient.run";
        }
        // (if lib.hasInfix "-" hash then { inherit hash; } else { sha256 = hash; })
      );

  # Offline / air-gapped fallback. This sha256 is the lselectric v140 build.
  requireFileSrc = requireFile {
    name = "NSClient.run";
    sha256 = "94e02c57eff357528d641ada0f0f2a6bb9cbe120eed061f7c21a3b7e02e14132";
    message = ''
      No client source configured. Either set `tenant` (+ `hash`) to fetch it, or
      supply NSClient.run offline. It is proprietary and tenant-specific; obtain it:

        Admin console: Settings -> Tools -> Downloads -> Linux   (choose the .run)
        or:            https://download-<tenant>.goskope.com/dlr/linux/get

      Then add it to the Nix store:

        nix-store --add-fixed sha256 NSClient.run

      Expected sha256 (lselectric, v140.0.2.2763):
        94e02c57eff357528d641ada0f0f2a6bb9cbe120eed061f7c21a3b7e02e14132
    '';
  };

  resolvedSrc =
    if srcOverride != null then
      srcOverride
    else if fetchedSrc != null then
      fetchedSrc
    else
      requireFileSrc;
in
stdenv.mkDerivation {
  pname = "netskope-client";
  inherit version;

  src = resolvedSrc;

  nativeBuildInputs = [
    autoPatchelfHook
    patchelf
    gzip
    gnutar
  ];

  buildInputs = [
    stdenv.cc.cc.lib # libstdc++.so.6, libgcc_s.so.1 (all binaries)
    nss # certutil
    nspr # certutil
  ]
  ++ lib.optionals enableTray [
    gtk3
    webkitgtk_4_1
    libayatana-appindicator
    glib
    pango
    cairo
    gdk-pixbuf
    dbus
  ];

  # NSClient.run is a Makeself self-extracting archive: an N-line /bin/sh header
  # followed by a gzip'd tar. `--noexec` hangs, so carve the payload out using the
  # offset the header declares about itself (version-independent).
  unpackPhase = ''
    runHook preUnpack

    skip=$(sed -n -E 's/^offset=`head -n ([0-9]+).*/\1/p' "$src" | head -n1)
    if [ -z "$skip" ]; then
      echo "netskope-client: could not locate the makeself payload offset in $src" >&2
      exit 1
    fi
    offset=$(head -n "$skip" "$src" | wc -c)

    mkdir -p payload
    tail -c +$((offset + 1)) "$src" | gzip -dc | tar -x -C payload

    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest="$out/opt/netskope/stagent"
    mkdir -p "$dest"
    cp -a payload/. "$dest/"
  ''
  + lib.optionalString (!enableTray) ''
    # daemon-only: drop the GTK/WebKit tray binary so autoPatchelf doesn't demand its libs
    rm -f "$dest/stAgentUI"
  ''
  + ''
    runHook postInstall
  '';

  # stAgentUI hard-codes stale sonames; rewrite them to current nixpkgs libs BEFORE
  # autoPatchelf (postFixup) resolves NEEDED entries against buildInputs.
  preFixup = lib.optionalString enableTray ''
    ui="$out/opt/netskope/stagent/stAgentUI"
    patchelf --replace-needed libwebkit2gtk-4.0.so.37        libwebkit2gtk-4.1.so.0        "$ui"
    patchelf --replace-needed libjavascriptcoregtk-4.0.so.18 libjavascriptcoregtk-4.1.so.0 "$ui"
    patchelf --replace-needed libappindicator3.so.1          libayatana-appindicator3.so.1 "$ui"
  '';

  passthru = {
    inherit enableTray;
    # The client hard-codes this path; the module materialises it (see issue #7).
    installDir = "/opt/netskope/stagent";
    # Where the client writes its root CA at runtime (NOT shipped in the installer;
    # provisioned at enrollment). The client writes it to installDir, which the module
    # bind-mounts from its state dir, so the real file lands under
    # <services.netskope.statePath>/app/data/ (default /var/lib/netskope). CA trust is
    # user-supplied via the module (see #8).
    caCertRuntimePath = "/var/lib/netskope/app/data/nscacert.pem";
  };

  meta = {
    description = "Netskope Client for Linux (proprietary SASE/SSE endpoint agent)";
    homepage = "https://www.netskope.com/";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "stAgentCli";
  };
}
