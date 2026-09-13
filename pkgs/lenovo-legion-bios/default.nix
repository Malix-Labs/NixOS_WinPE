{
  lib,
  stdenvNoCC,
  fetchurl,
  innoextract,
  p7zip,
  file,
  writeShellApplication,
  curl,
  nix,
  git,
  gnused,
  gnugrep,
  python3,
  icoutils,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lenovo-legion-15ach6h-bios";
  version = "65"; # GKCN65WW

  src = fetchurl {
    name = "gkcn${finalAttrs.version}ww-installer.exe";
    url = "https://download.lenovo.com/consumer/mobiles/gkcn${finalAttrs.version}ww.exe";
    hash = "sha256-QXb3lKgR+ILqMSwNjz68cR20xaixvJLccwGJjTIgwaA=";
  };

  nativeBuildInputs = [
    innoextract
    p7zip
    gnused
    (python3.withPackages (ps: [ ps.pefile ]))
  ];

  unpackPhase = ''
    runHook preUnpack
    innoextract -e $src
    # The outer Inno installer only wraps a 7z SFX carrying the real InsydeFlash toolchain (H2OFFT-W.exe, platform.ini, BIOS.fd and its drivers) - ship the toolchain itself so it can be driven directly under WinPE.
    INNER=$(find . -maxdepth 2 -iname "GKCN*WW.exe")
    7z x -otoolchain "$INNER" >/dev/null
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r toolchain/. $out/
    # Headless-WinPE hardening of platform.ini, each key patched inside its own section.
    # [UI] Confirm=0 + Silent=1: no GUI; in silent mode FlashComplete Action=0 makes the tool return to the shell after flashing instead of rebooting itself.
    # [AC_Adapter] Flag=0 + [Platform_Check] Flag=0: the battery and model probes are unreliable or unsatisfiable under WinPE (placeholder platform names AA/BB); the AC guard lives in winpe-flash instead.
    # [Log_file] Flag=1: write H2OFFT.log next to the tool (lands on the ESP) for post-mortem evidence.
    sed -i 's/^Confirm=1/Confirm=0/' $out/platform.ini
    sed -i 's/^Silent=0/Silent=1/' $out/platform.ini
    sed -i '/^\[AC_Adapter\]/,/^\[/ s/^Flag=1/Flag=0/' $out/platform.ini
    sed -i '/^\[Platform_Check\]/,/^\[/ s/^Flag=1/Flag=0/' $out/platform.ini
    sed -i '/^\[Log_file\]/,/^\[/ s/^Flag=0/Flag=1/' $out/platform.ini
    # Silent success must return 0 (not the InsydeFlash default 3010 "reboot required"): the autorun script branches on a plain "if errorlevel 1".
    sed -i 's/^RETURN_SUCCESSFUL=0,3010/RETURN_SUCCESSFUL=0,0/' $out/platform.ini
    # The ESD-extracted WinPE cannot create activation contexts for 32-bit applications: every manifest-bearing binary fails with ERROR_SXS_CANT_GEN_ACTCTX regardless of manifest content (vendor dependencies, trimmed private assemblies and dependency-free manifests all fail identically - validated under QEMU and on hardware 2026-09-13).
    # Zeroing the RT_MANIFEST directory entry counts removes the manifest resource without touching any other PE structure, so the loader uses the default context and the plain DLL search order, resolving the vendor VC90 DLLs flat in the application directory.
    for f in "$out"/*.exe "$out"/*.dll; do
      python3 ${./strip-manifest.py} "$f"
    done
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    file
    gnugrep
    icoutils
  ];

  installCheckPhase = ''
    runHook preInstallCheck
    [ -s "$out/H2OFFT-W.exe" ]
    [ -s "$out/FWUpdLcl.exe" ]
    [ -s "$out/BIOS.fd" ]
    [ -s "$out/platform.ini" ]
    file -b "$out/FWUpdLcl.exe" | grep -q "PE32"
    sed -n '/^\[UI\]/,/^\[/p' "$out/platform.ini" | grep -q "^Silent=1"
    sed -n '/^\[UI\]/,/^\[/p' "$out/platform.ini" | grep -q "^Confirm=0"
    sed -n '/^\[AC_Adapter\]/,/^\[/p' "$out/platform.ini" | grep -q "^Flag=0"
    sed -n '/^\[Platform_Check\]/,/^\[/p' "$out/platform.ini" | grep -q "^Flag=0"
    sed -n '/^\[Log_file\]/,/^\[/p' "$out/platform.ini" | grep -q "^Flag=1"
    grep -q "^RETURN_SUCCESSFUL=0,0" "$out/platform.ini"
    for f in "$out"/*.exe "$out"/*.dll; do
      if wrestool --list "$f" | grep -qE "type=24 --name"; then
        echo "ERROR: $f still embeds a manifest resource" >&2
        exit 1
      fi
    done
    runHook postInstallCheck
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

  meta = with lib; {
    description = "Official Lenovo Legion 15ACH6H BIOS and Embedded Controller firmware updater";
    homepage = "https://pcsupport.lenovo.com/products/laptops-and-netbooks/legion-series/legion-5-15ach6h/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryFirmware ];
    maintainers = with lib.maintainers; [ malix ];
    platforms = [ "x86_64-linux" ];
  };
})
