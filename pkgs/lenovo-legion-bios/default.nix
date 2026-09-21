{
  lib,
  pkgs,
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
  # x86 helper DLLs staged next to H2OFFT-W (winpe-image's wow64SidecarFiles):
  # the WinRE image boot is broken when these are grafted wholesale into its
  # SysWOW64, so they ride along next to the flasher instead (loader resolves
  # the application directory first). Default empty for the plain package.
  sidecarFiles ? { },
  # mingw cross toolchain, used only for the GDI UAP api-set forwarder shim
  # (the ONLY non-vendor binary in this deployment): gdi32.dll imports
  # api-ms-win-gdi-internal-uap-l1-1-0.dll which exists neither as a file nor
  # as a resolvable schema entry in the 26100 ESD (round 22). Every export is
  # forwarded verbatim to the ESD's own x86 gdi32full.dll.
  gcc-mingw ? pkgs.pkgsCross.mingw32.stdenv.cc,
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
    # For the GDI UAP api-set forwarder shim below.
    gcc-mingw
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
    # Round 29 (2026-09-21): pin the BIOS image path explicitly. The vendor default is
    # an empty [FDFile] FileName (auto-locate "the FD file from CWD"), and the tool's
    # precondition fail path on WinPE = the unreadable void "Error" modal with RC=0 -
    # no way to distinguish "file not found" from "driver missing". Explicit wins:
    # also cheaper than the driver install matrix, which round 28 proved only stages
    # the driver package (oem0.inf published) without ever creating the H2OFFT
    # service (root device node enumeration absent in this WinPE).
    sed -i '/^\[FDFile\]/,/^\[/{s/^FileName=.*\r\?$/FileName=BIOS.fd\r/}' $out/platform.ini
    # The RT_MANIFEST strip step is GONE as of 2026-09-18: H2OFFT-W runs an embedded
    # Authenticode WinVerifyTrust pass over EVERY companion tool at startup
    # (validated under wine: WinVerifyTrust calls on FlsHook.exe/FWUpdLcl.exe trace
    # dump_file_info; a stripped FWUpdLcl.exe returns TRUST_E_BAD_DIGEST 0x80096010
    # and the tool refuses with the "malware installed ... invalid with signature
    # check" alert; on hardware round 12 that was a silent 0-byte exit). The old
    # motivation for stripping (32-bit actctx 14001 on WinPE) predates the
    # sxs-winners-graft environment (§0.6); whether an embedded-manifest 32-bit exe
    # still fails actctx in the NEW environment is validated by the winpe-qemu
    # check booting H2OFFT-W itself - if that check ever turns red with an SxS
    # exit code, revisit with an official-files-only alternative.
    runHook postInstall

    # VC90 MFC private-assembly fallback (RESEARCH-NOTES.md round 19): H2OFFT-W.exe's
    # embedded manifest requests Microsoft.VC90.MFC 9.0.21022.8, which the ESD does NOT
    # ship at all (VC90 CRT only). The SxS binder's private-assembly lookup is a
    # "<AssemblyName>\" directory next to the exe, so the vendor's own files must be
    # laid out there. All bytes are vendor-identical: mfc90u.dll is copied verbatim
    # (its Authenticode signature - checked by H2OFFT-W's own WinVerifyTrust pass over
    # companions - stays valid), and the manifest is the vendor-shipped
    # Microsoft.VC90.MFC.manifest text trimmed to the file set this toolchain actually
    # carries (mfc90u.dll only). Manifest files are not signature-checked by
    # WinVerifyTrust, so the trim is safe. No binary is modified with this step.
    mkdir -p $out/Microsoft.VC90.MFC
    cp $out/mfc90u.dll $out/Microsoft.VC90.MFC/
    sed 's|<file name="mfc90.dll" /> <file name="mfc90u.dll" /> <file name="mfcm90.dll" /> <file name="mfcm90u.dll" />|<file name="mfc90u.dll" />|' \
      $out/Microsoft.VC90.MFC.manifest > $out/Microsoft.VC90.MFC/Microsoft.VC90.MFC.manifest

    # VC90 CRT private assembly, same private-assembly route as MFC: the vendor
    # ships Microsoft.VC90.CRT.manifest + msvcp90.dll/msvcr90.dll flat right next
    # to H2OFFT-W.exe; the manifest lists three payload files of which msvcm90.dll
    # is absent from this toolchain, so the private manifest is trimmed to the
    # shipped pair. All bytes vendor-identical, manifest is text-only.
    mkdir -p $out/Microsoft.VC90.CRT
    cp $out/msvcp90.dll $out/Microsoft.VC90.CRT/
    cp $out/msvcr90.dll $out/Microsoft.VC90.CRT/
    sed 's|<file name="msvcr90.dll" /> <file name="msvcp90.dll" /> <file name="msvcm90.dll" />|<file name="msvcp90.dll" /> <file name="msvcr90.dll" />|' \
      $out/Microsoft.VC90.CRT.manifest > $out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest

    # Sidecar x86 DLLs (see sidecarFiles parameter note): copied verbatim next to
    # H2OFFT-W.exe. Bytes are vendor-OS-identical Microsoft files from the same ESD.
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: path: ''
        cp ${path} $out/${name}
      '') sidecarFiles
    )}

    # api-ms-win-gdi-internal-uap-l1-1-0.dll forwarder shim (see gcc-mingw parameter
    # note): a 16-forwarder DLL compiled here at build time; exports forward verbatim
    # to the ESD's own x86 gdi32full.dll. Staged next to H2OFFT-W.exe.
    ${gcc-mingw}/bin/i686-w64-mingw32-gcc -shared -o $out/api-ms-win-gdi-internal-uap-l1-1-0.dll \
      ${./gdi-uap-forwarder.c} ${./gdi-uap-forwarder.def}
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
    # VC90 MFC private assembly layout: the directory must exist
    # next to H2OFFT-W.exe, the manifest must keep the exact requested identity (name
    # + version + token), list only the shipped file, and the DLL must be byte-identical
    # to the vendor flat copy (signature validity guarantee).
    [ -s "$out/Microsoft.VC90.MFC/Microsoft.VC90.MFC.manifest" ]
    [ -s "$out/Microsoft.VC90.MFC/mfc90u.dll" ]
    cmp "$out/mfc90u.dll" "$out/Microsoft.VC90.MFC/mfc90u.dll"
    grep -qF 'name="Microsoft.VC90.MFC"' "$out/Microsoft.VC90.MFC/Microsoft.VC90.MFC.manifest"
    grep -qF 'version="9.0.21022.8"' "$out/Microsoft.VC90.MFC/Microsoft.VC90.MFC.manifest"
    if grep -E 'file name="mfc90\.dll"|file name="mfcm' "$out/Microsoft.VC90.MFC/Microsoft.VC90.MFC.manifest"; then
      echo "ERROR: VC90 MFC private manifest lists files the toolchain does not ship" >&2
      exit 1
    fi
    # VC90 CRT private assembly checks (same private-assembly discipline as MFC).
    [ -s "$out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest" ]
    grep -qF 'name="Microsoft.VC90.CRT"' "$out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest"
    grep -qF 'version="9.0.21022.8"' "$out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest"
    grep -qF '<file name="msvcp90.dll" />' "$out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest"
    grep -qF '<file name="msvcr90.dll" />' "$out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest"
    if grep -E 'file name="msvcm' "$out/Microsoft.VC90.CRT/Microsoft.VC90.CRT.manifest"; then
      echo "ERROR: VC90 CRT private manifest lists msvcm90.dll which the toolchain lacks" >&2
      exit 1
    fi
    cmp "$out/msvcp90.dll" "$out/Microsoft.VC90.CRT/msvcp90.dll"
    cmp "$out/msvcr90.dll" "$out/Microsoft.VC90.CRT/msvcr90.dll"
    # GDI UAP forwarder shim must exist, be a 32-bit DLL per binary, and forward
    # exactly the 16 symbols gdi32 imports from that api set.
    [ -s "$out/api-ms-win-gdi-internal-uap-l1-1-0.dll" ]
    file -b "$out/api-ms-win-gdi-internal-uap-l1-1-0.dll" | grep -q "PE32"
    for s in hdcCreateDCW InternalDeleteDC GetRandomRgn PtInRegion FillRgn CreateRoundRectRgn SelectObjectImpl SetPolyFillModeImpl SelectClipRgnImpl AbortDocImpl GdiSupportsFontChangeEvent DeleteColorSpace IcmReleaseCachedColorSpace IcmDeleteLocalDC DeleteEMFSpoolData SetMetaRgn; do
      grep -aqF "gdi32full.$s" "$out/api-ms-win-gdi-internal-uap-l1-1-0.dll" || { echo "ERROR: forwarder missing gdi32full.$s" >&2; exit 1; }
    done
    for f in "$out"/*.exe "$out"/*.dll; do
      # The strip step is gone (see install phase): the vendor toolchain must stay
      # byte-identical or H2OFFT-W's integrity verification rejects it. Assert the
      # embedded manifests are still present in the files that carry one.
      if [ "$(basename "$f")" = "H2OFFT-W.exe" ]; then
        wrestool --list "$f" | grep -qE "type=24 --name" || { echo "ERROR: $f lost its manifest - toolchain bytes were modified" >&2; exit 1; }
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
