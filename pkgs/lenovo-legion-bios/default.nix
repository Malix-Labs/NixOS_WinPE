{
  lib,
  stdenvNoCC,
  fetchurl,
  innoextract,
  writeShellApplication,
  curl,
  nix,
  git,
  gnused,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lenovo-legion-15ach6h-bios";
  version = "65"; # GKCN65WW

  src = fetchurl {
    name = "gkcn${finalAttrs.version}ww-installer.exe";
    url = "https://download.lenovo.com/consumer/mobiles/gkcn${finalAttrs.version}ww.exe";
    hash = "sha256-QXb3lKgR+ILqMSwNjz68cR20xaixvJLccwGJjTIgwaA=";
  };

  nativeBuildInputs = [ innoextract ];

  unpackPhase = ''
    runHook preUnpack
    innoextract -e $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    EXE=$(find . -maxdepth 2 -iname "GKCN*WW.exe" | head -n1)
    cp "$EXE" $out
    runHook postInstall
  '';

  passthru.updateScript = writeShellApplication {
    name = "update-lenovo-legion-bios";
    runtimeInputs = [
      curl
      nix
      git
      gnused
    ];
    text = ''
      REPO_ROOT="$(git rev-parse --show-toplevel)"
      TARGET_FILE="$REPO_ROOT/pkgs/lenovo-legion-bios/default.nix"

      CURRENT_VER="${finalAttrs.version}"
      NEXT_VER=$((CURRENT_VER + 1))
      URL="https://download.lenovo.com/consumer/mobiles/gkcn''${NEXT_VER}ww.exe"

      echo "Checking Lenovo CDN for newer BIOS at: $URL ..."
      if curl -sfI "$URL" > /dev/null; then
        echo "Found new BIOS version: GKCN''${NEXT_VER}WW! Prefetching hash..."
        NEW_HASH=$(nix-prefetch-url "$URL")
        SRI_HASH=$(nix hash convert --to sri "sha256:$NEW_HASH")

        echo "Updating $TARGET_FILE ..."
        sed -i "s/version = \"$CURRENT_VER\"/version = \"$NEXT_VER\"/" "$TARGET_FILE"
        sed -i "s|hash = \".*\"|hash = \"$SRI_HASH\"|" "$TARGET_FILE"
        echo "Successfully updated to GKCN''${NEXT_VER}WW!"
      else
        echo "No newer version found. Currently on latest (GKCN''${CURRENT_VER}WW)."
      fi
    '';
  };

  meta = {
    description = "Official Lenovo Legion 5 15ACH6H BIOS and Embedded Controller firmware updater";
    homepage = "https://pcsupport.lenovo.com/products/laptops-and-netbooks/legion-series/legion-5-15ach6h/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryFirmware ];
    maintainers = with lib.maintainers; [ malix ];
    platforms = [ "x86_64-linux" ];
  };
})
