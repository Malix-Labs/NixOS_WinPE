{
  lib,
  stdenvNoCC,
  fetchurl,
  coreutils,
  wimlib,
  writeShellApplication,
  curl,
  cabextract,
  gnugrep,
  gnused,
  nix,
}:
let
  version = "10.0.26100.4349";
in
stdenvNoCC.mkDerivation {
  pname = "winpe-image";
  inherit version;

  # As far as I am aware, there is no smaller official source than using the Windows client ESD, which contains all genuine boot binaries (boot.sdi, BCD, bootx64.efi, boot.wim).
  src = fetchurl {
    url = "http://dl.delivery.mp.microsoft.com/filestreamingservice/files/009d9a0d-8e1a-45ce-9540-21377534803e/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_en-us.esd";
    hash = "sha256-yi0uVjuXAPe6BWnJ3AUyG4HhSVxS2gaGHD3IjvnObqs=";
  };

  dontUnpack = true;

  nativeBuildInputs = [
    wimlib
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{sources,boot,EFI/Boot}

    # Why extract Image 1 wholesale: bootmgr requires more than just the BCD
    # and bootloader to render its UI - fonts, bootres.dll (boot logo/graphics
    # resources), and en-US MUI string tables. With only a bare BCD it paints
    # a flat blue screen and hangs with no error text.
    wimlib-imagex extract "$src" 1 /boot --dest-dir=$out --no-acls
    wimlib-imagex extract "$src" 1 /efi/microsoft --dest-dir=$out/EFI --no-acls
    wimlib-imagex extract "$src" 1 /efi/boot/bootx64.efi --dest-dir=$out/EFI/Boot --no-acls
    # The WIM stores /efi/microsoft in lowercase; normalize for FAT layout.
    mv $out/EFI/microsoft $out/EFI/Microsoft

    # Why export Image 2: contains genuine Microsoft Windows PE (amd64) operating system image.
    # Why LZX: the ESD stores images LZMS-compressed (ESD-style), but bootmgr's
    # ramdisk loader fails with 0xc00000bb reading LZMS WIMs; LZX is the
    # compression used by bootable boot.wim on real install media.
    wimlib-imagex export "$src" 2 "$out/sources/boot.wim" --compress=LZX --boot

    runHook postInstall
  '';

  # Update flow: fetch the Windows Update product catalog, locate the current
  # client ESD, prefetch + structurally validate it, then rewrite this file.
  # Every predictable failure (catalog layout, edition rename, missing boot
  # files) exits with a named error BEFORE default.nix is touched. Structural
  # changes that no script can predict (new distribution mechanism, image
  # reorganization) fail loudly here and need a human-authored fix.
  passthru.updateScript = writeShellApplication {
    name = "update-winpe-image";
    runtimeInputs = [
      coreutils
      curl
      cabextract
      gnugrep
      gnused
      wimlib
      nix
    ];
    text = ''
      # Target resolution: pass the flake checkout as $1 (recommended when
      # running the store-built binary via `nix run`), or rely on $0 sitting
      # next to default.nix when executed from a source tree.
      TARGET="''${1:-}"
      if [ -n "$TARGET" ] && [ -d "$TARGET" ]; then
        PKG_FILE="$TARGET/pkgs/winpe-image/default.nix"
      elif [ -n "$TARGET" ] && [ "''${TARGET##*/}" = "default.nix" ]; then
        PKG_FILE="$TARGET"
      else
        PKG_FILE="$(dirname "$0")/default.nix"
      fi
      [ -f "$PKG_FILE" ] || { echo "ERROR: target default.nix not found at: $PKG_FILE" >&2; echo "Pass the flake checkout as the first argument, e.g.: nix run .#winpe-image.updateScript -- /path/to/NixOS_WinPE" >&2; exit 1; }

      TEMP_DIR="$(mktemp -d)"
      trap 'rm -rf "$TEMP_DIR"' EXIT

      echo "Fetching latest Microsoft Windows product catalog..."
      curl -fsSL "https://go.microsoft.com/fwlink/?linkid=2156292" -o "$TEMP_DIR/catalog.cab"
      cabextract -q -d "$TEMP_DIR" "$TEMP_DIR/catalog.cab"
      PRODUCTS_XML="$TEMP_DIR/products.xml"
      [ -s "$PRODUCTS_XML" ] || { echo "ERROR: catalog did not contain products.xml - Microsoft likely changed the catalog layout" >&2; exit 1; }

      ESD_URL=$(grep -B 2 -A 8 "CLIENTCONSUMER_RET_x64FRE_en-us.esd" "$PRODUCTS_XML" | grep -oE 'https?://[^<]*CLIENTCONSUMER_RET_x64FRE_en-us\.esd' | tail -n1)
      [ -n "$ESD_URL" ] || { echo "ERROR: no CLIENTCONSUMER_RET_x64FRE_en-us.esd in the catalog - update the discovery logic in this script manually" >&2; exit 1; }
      case "$ESD_URL" in
        *dl.delivery.mp.microsoft.com/*) ;;
        *) echo "ERROR: unexpected ESD host in catalog: $ESD_URL" >&2; exit 1 ;;
      esac
      VERSION=$(basename "$ESD_URL" | grep -oE '^[0-9]+\.[0-9]+')
      [ -n "$VERSION" ] || { echo "ERROR: could not parse version from: $ESD_URL" >&2; exit 1; }
      # Windows 11 ESDs keep the 10.0 NT kernel prefix in their version.
      NT_VERSION="10.0.$VERSION"

      echo "Found ESD: $(basename "$ESD_URL") (version $VERSION)"
      echo "Prefetching (~5GB, be patient)..."
      PREFETCH="$TEMP_DIR/prefetch.txt"
      nix-prefetch-url --print-path "$ESD_URL" > "$PREFETCH"
      HASH=$(sed -n 1p "$PREFETCH")
      ESD_STORE_PATH=$(sed -n 2p "$PREFETCH")
      SRI_HASH=$(nix hash convert --to sri --hash-algo sha256 "$HASH")

      echo "Validating ESD structure..."
      IMAGE_COUNT=$(wimlib-imagex info "$ESD_STORE_PATH" | sed -n 's/^Image Count:[[:space:]]*//p')
      [ -n "$IMAGE_COUNT" ] && [ "$IMAGE_COUNT" -ge 2 ] || { echo "ERROR: expected >= 2 images (1: boot environment, 2: WinPE), got: $IMAGE_COUNT" >&2; exit 1; }
      wimlib-imagex info "$ESD_STORE_PATH" 2 | grep -qi "WindowsPE" || { echo "ERROR: ESD image 2 is no longer a Windows PE image" >&2; exit 1; }
      wimlib-imagex dir "$ESD_STORE_PATH" 1 --path=/efi/microsoft/boot/bcd >/dev/null 2>&1 || { echo "ERROR: ESD image 1 lost /efi/microsoft/boot/bcd" >&2; exit 1; }
      wimlib-imagex dir "$ESD_STORE_PATH" 1 --path=/boot/boot.sdi >/dev/null 2>&1 || { echo "ERROR: ESD image 1 lost /boot/boot.sdi" >&2; exit 1; }

      NEW_PKG="$TEMP_DIR/default.nix"
      cp "$PKG_FILE" "$NEW_PKG"
      sed -i "s|version = \".*\";|version = \"$NT_VERSION\";|" "$NEW_PKG"
      sed -i "s|url = \".*\";|url = \"$ESD_URL\";|" "$NEW_PKG"
      sed -i "s|hash = \"sha256-.*\";|hash = \"$SRI_HASH\";|" "$NEW_PKG"

      if cmp -s "$PKG_FILE" "$NEW_PKG"; then
        echo "winpe-image is already at the latest ESD ($VERSION). Nothing to do."
        exit 0
      fi

      echo "Pending changes:"
      diff -u "$PKG_FILE" "$NEW_PKG" || true
      mv "$NEW_PKG" "$PKG_FILE"
      echo "Updated winpe-image to $VERSION ($SRI_HASH)"
      echo "Next: nix flake check -L   (end-to-end validation against the new ESD), then commit."
    '';
  };

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    [ -s "$out/sources/boot.wim" ]
    [ -s "$out/EFI/Boot/bootx64.efi" ]
    [ -s "$out/EFI/Microsoft/boot/bcd" ]
    [ -s "$out/boot/boot.sdi" ]
    [ -s "$out/EFI/Microsoft/boot/resources/bootres.dll" ]
    [ -s "$out/EFI/Microsoft/boot/fonts/wgl4_boot.ttf" ]

    # Regression tripwire: bootmgr's ramdisk loader fails LZMS WIMs with
    # 0xc00000bb; bootable boot.wim must stay LZX.
    wimlib-imagex info "$out/sources/boot.wim" | grep -q "Compression:.*LZX"

    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Official Microsoft Windows PE x86_64 Bootable Image extracted from Windows ESD";
    homepage = "https://www.microsoft.com/software-download";
    license = licenses.unfree;
    maintainers = with maintainers; [ malix ];
    platforms = [ "x86_64-linux" ];
  };
}
