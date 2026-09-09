{
  lib,
  stdenvNoCC,
  fetchurl,
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

  passthru.updateScript = writeShellApplication {
    name = "update-winpe-image";
    runtimeInputs = [
      curl
      cabextract
      gnugrep
      gnused
      nix
    ];
    text = ''
      PKG_FILE="$(dirname "$0")/default.nix"
      TEMP_DIR="$(mktemp -d)"
      trap 'rm -rf "$TEMP_DIR"' EXIT

      echo "Fetching latest Microsoft Windows product catalog..."
      curl -sL "https://go.microsoft.com/fwlink/?linkid=2156292" -o "$TEMP_DIR/catalog.cab"
      cabextract -d "$TEMP_DIR" "$TEMP_DIR/catalog.cab" >/dev/null 2>&1

      PRODUCTS_XML="$TEMP_DIR/products.xml"
      ESD_URL=$(grep -B 2 -A 8 "CLIENTCONSUMER_RET_x64FRE_en-us.esd" "$PRODUCTS_XML" | grep -o 'http://[^<]*\.esd' | head -n1)
      FILENAME=$(basename "$ESD_URL")
      VERSION=$(echo "$FILENAME" | grep -o '^[0-9]\+\.[0-9]\+' || echo "26100.1")

      echo "Found ESD: $FILENAME (version $VERSION)"
      echo "Prefetching hash from Microsoft CDN..."
      HASH=$(TMPDIR=/var/tmp nix-prefetch-url "$ESD_URL")
      SRI_HASH=$(nix hash convert --to sri --type sha256 "$HASH")

      echo "Updating $PKG_FILE..."
      sed -i "s|version = \".*\";|version = \"$VERSION\";|" "$PKG_FILE"
      sed -i "s|url = \".*\";|url = \"$ESD_URL\";|" "$PKG_FILE"
      sed -i "s|hash = \"sha256-.*\";|hash = \"$SRI_HASH\";|" "$PKG_FILE"

      echo "Successfully updated winpe-image to $VERSION ($SRI_HASH)"
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
