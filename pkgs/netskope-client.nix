{
  lib,
  stdenv,
  requireFile,
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
  # override the installer source; defaults to a requireFile of NSClient.run
  src ? null,
}:

let
  version = "140.0.2.2763";

  # The Netskope installer is proprietary and rebuilt per tenant, so it cannot be
  # redistributed or pinned to a public hash. The user must supply NSClient.run.
  # This sha256 is the lselectric v140 build; override `src` if yours differs.
  defaultSrc = requireFile {
    name = "NSClient.run";
    sha256 = "94e02c57eff357528d641ada0f0f2a6bb9cbe120eed061f7c21a3b7e02e14132";
    message = ''
      The Netskope client installer (NSClient.run) is proprietary and tenant-specific;
      it is rebuilt per tenant and cannot be redistributed. Obtain it from your tenant:

        Admin console: Settings -> Tools -> Downloads -> Linux   (choose the .run)
        or:            https://download-<tenant>.goskope.com/dlr/linux/get

      Then add it to the Nix store:

        nix-store --add-fixed sha256 NSClient.run

      Expected sha256 (lselectric, v140.0.2.2763):
        94e02c57eff357528d641ada0f0f2a6bb9cbe120eed061f7c21a3b7e02e14132
    '';
  };
in
stdenv.mkDerivation {
  pname = "netskope-client";
  inherit version;

  src = if src != null then src else defaultSrc;

  nativeBuildInputs = [
    autoPatchelfHook
    patchelf
    gzip
    gnutar
  ];

  buildInputs =
    [
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

  installPhase =
    ''
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
    # provisioned at enrollment). After #7's relocation the real file lives under
    # /var/lib/netskope/data/. CA trust is user-supplied via the module (see #8).
    caCertRuntimePath = "/var/lib/netskope/data/nscacert.pem";
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
