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
  p7zip,
  hivex,
  gawk,

  # Base-ESD selection (2026-09-23, round 41): the 26100 (24H2) base rejects the
  # 2008-era SHA-1 Authenticode chain of the vendor toolchain (RESEARCH-NOTES.md
  # rounds 32–40): WinPE 24H2 removed the legacy trust classes at the crypt layer
  # (E_NOTIMPL even through CryptCATAdmin's file hashing). Lenovo's own update
  # utility runs its flashes from a 22621 (22H2)-class PE, where the same package's
  # chain still validates.
  #
  # Exposed as TWO package variants in flake.nix (see perSystem.packages):
  #   winpe-image        = 24H2 (the newest Microsoft base; default kept for any
  #                        future firmware tool that needs a modern base - e.g.
  #                        a future SHA-256-signed vendor package),
  #   winpe-image-legacy = 22H2 (the era-matching base for legacy 32-bit flashers).
  # The profile picks the variant it needs; neither variant silently degrades the other.
  esdBase ? "modern-24h2",
}:
let
  # Base-ESD registry (Microsoft's own pinned dl.delivery URLs + published SHA-256s;
  # provenance documented in RESEARCH-NOTES.md round 41). Select by KEY OR by
  # passing your own { version,url,hash } attribute.
  esdBases = {
    "modern-24h2" = {
      version = "10.0.26100.4349";
      url = "http://dl.delivery.mp.microsoft.com/filestreamingservice/files/009d9a0d-8e1a-45ce-9540-21377534803e/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_en-us.esd";
      hash = "sha256-yi0uVjuXAPe6BWnJ3AUyG4HhSVxS2gaGHD3IjvnObqs=";
    };
    "legacy-22h2" = {
      version = "10.0.22621.1702";
      url = "http://dl.delivery.mp.microsoft.com/filestreamingservice/files/ec26d435-5d20-4563-9c75-b7726e55f93b/22621.1702.230505-1222.ni_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_en-us.esd";
      hash = "sha256-c7SC2dhjunFhNgDOD9VR8VqdsY78yZG8M7TIw6mLOQ0=";
    };
  };
  esd = if builtins.isAttrs esdBase then esdBase else esdBases.${esdBase} or esdBases."modern-24h2";
  version = esd.version;
  # ESD WinRE (the boot.wim base) is 32-bit-incapable: WinPE dropped WOW64 packaging after
  # Win10 2004 (RESEARCH-NOTES.md §0.6). The base is therefore the full-Windows image's own
  # WinRE (build-consistent kernel + user mode, native PE infra), and these assembly
  # families provide the 32-bit runtime Microsoft ships for every desktop system:
  # SxS runtime assemblies (WinSxS manifests + payloads) and WOW64 subsystem files.
  # The vc90.crt family is here for the same reason as the windows.* families below:
  # H2OFFT-W.exe (RESEARCH-NOTES.md round 19) dies at 0xC0000135 with the
  # side-by-side-configuration dialog because its embedded manifest requests
  # Microsoft.VC90.CRT 9.0.21022.8 and this WinRE base ships no VC90 at all. The
  # ESD carries the 9.0.30729.9635 CRT assembly + a policy.9.0 publisher-policy
  # manifest whose Winners entries bind any 9.0.x request to 30729.9635.
  # WinRE image itself (grafting dwmapi/winmm/uxtheme/comdlg32 into the boot.wim's
  # SysWOW64 breaks the WinPE boot outright - BSOD 0xc0000021a during early boot,
  # validated 2026-09-19). They ship as sidecar files staged NEXT to the 32-bit
  # flasher, where the loader resolves them before the system directories.
  wow64SidecarFiles = [
    "comdlg32.dll"
    "dwmapi.dll"
    "gdi32full.dll"
    "uxtheme.dll"
    "winmm.dll"
  ];
  coreWow64Files = [
    "advapi32.dll"
    "gdi32.dll"
    "kernel32.dll"
    "KernelBase.dll"
    "msvcrt.dll"
    "ole32.dll"
    "rpcrt4.dll"
    "sechost.dll"
    "shell32.dll"
    "shlwapi.dll"
    "user32.dll"
    "wldp.dll"
    "cmd.exe"
  ];
  requiredWimPaths =
    (map (f: "/Windows/System32/${f}") [
      "wow64.dll"
      "wow64base.dll"
      "wow64con.dll"
      "wow64cpu.dll"
      "wow64win.dll"
    ])
    ++ (map (f: "/Windows/SysWOW64/${f}") coreWow64Files)
    ++ [ "/Windows/sxs-winners.cmd" ];
in
stdenvNoCC.mkDerivation {
  pname = "winpe-image";
  inherit version;
  # As far as I am aware, there is no smaller official source than using the Windows client ESD, which contains all genuine boot binaries (boot.sdi, BCD, bootx64.efi, boot.wim).
  src = fetchurl { inherit (esd) url hash; };
  nativeBuildInputs = [
    wimlib
    p7zip
    hivex
    gawk
  ];

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{sources,boot,EFI/Boot}
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    # Why extract Image 1 wholesale: bootmgr requires more than just the BCD and bootloader to render its UI - fonts, bootres.dll (boot logo/graphics resources), and en-US MUI string tables.
    # With only a bare BCD it paints a flat blue screen and hangs with no error text.
    wimlib-imagex extract "$src" 1 /boot --dest-dir=$out --no-acls
    wimlib-imagex extract "$src" 1 /efi/microsoft --dest-dir=$out/EFI --no-acls
    wimlib-imagex extract "$src" 1 /efi/boot/bootx64.efi --dest-dir=$out/EFI/Boot --no-acls
    # The WIM stores /efi/microsoft in lowercase; normalize for FAT layout.
    mv $out/EFI/microsoft $out/EFI/Microsoft

    # Why the WinRE image as boot.wim base: the setup WinPE (image 2) is packaged without
    # any 32-bit (WOW64) support and no 26100-era WOW64 runtime exists in the ESD to graft,
    # so 32-bit flashers die at process creation (0xc0000142). The full-Windows image's own
    # WinRE is a version-consistent bootable PE (winpeshl/wpeinit/diskpart included) whose
    # era matches the WOW64 files also present in that image. QEMU-ladder-validated:
    # all 32-bit probes and FWUpdLcl.exe execute (RESEARCH-NOTES.md §0.6).
    IMAGE_COUNT=$(wimlib-imagex info "$src" | sed -n 's/^Image Count:[[:space:]]*//p')
    [ -n "$IMAGE_COUNT" ] || { echo "ERROR: could not read image count from ESD" >&2; exit 1; }
    OS_IMAGE=""
    for i in $(seq 1 "$IMAGE_COUNT"); do
      if wimlib-imagex dir "$src" "$i" --path=/Windows/System32/Recovery/Winre.wim >/dev/null 2>&1; then
        OS_IMAGE="$i"
        break
      fi
    done
    [ -n "$OS_IMAGE" ] || { echo "ERROR: no ESD image contains /Windows/System32/Recovery/Winre.wim; cannot build WinRE-based boot.wim" >&2; exit 1; }

    # Why LZX: bootmgr's ramdisk loader fails LZMS WIMs with 0xc00000bb; LZX is the compression used by bootable boot.wim on real install media.
    wimlib-imagex extract "$src" "$OS_IMAGE" /Windows/System32/Recovery/Winre.wim --dest-dir="$TMP" --no-acls
    wimlib-imagex export "$TMP/Winre.wim" 1 "$out/sources/boot.wim" --compress=LZX --boot

    # Graft 1: WOW64 subsystem (System32 bridge DLLs) + core 32-bit runtime DLLs + a 32-bit
    # cmd.exe canary, all verbatim from the same ESD image. 7z, not wimlib, for extraction:
    # it handles every path shape deterministically.
    OSI="$TMP/osimg/$OS_IMAGE"
    echo "Extracting WOW64 + core 32-bit files from ESD image $OS_IMAGE..."
    SEVENZ_ARGS=()
    for f in wow64.dll wow64base.dll wow64con.dll wow64cpu.dll wow64win.dll; do
      SEVENZ_ARGS+=("$OS_IMAGE/Windows/System32/$f")
    done
    for f in ${lib.concatStringsSep " " coreWow64Files}; do
      SEVENZ_ARGS+=("$OS_IMAGE/Windows/SysWOW64/$f")
    done
    7z x -y -o"$TMP/osimg" "$src" "''${SEVENZ_ARGS[@]}" >/dev/null
    for f in wow64.dll wow64base.dll wow64con.dll wow64cpu.dll wow64win.dll; do
      [ -s "$OSI/Windows/System32/$f" ] || { echo "ERROR: ESD image $OS_IMAGE lost $f (WOW64 bridge)" >&2; exit 1; }
      echo "add $OSI/Windows/System32/$f /Windows/System32/$f"
    done > "$TMP/graft.cmds"
    for f in ${lib.concatStringsSep " " coreWow64Files}; do
      [ -s "$OSI/Windows/SysWOW64/$f" ] || { echo "ERROR: ESD image $OS_IMAGE lost SysWOW64/$f (core 32-bit runtime)" >&2; exit 1; }
      echo "add $OSI/Windows/SysWOW64/$f /Windows/SysWOW64/$f"
    done >> "$TMP/graft.cmds"

    # Graft 2: the x86 SxS runtime assembly family (all versions present; the SxS binder
    # picks the highest). Manifests live in WinSxS/Manifests, payloads in WinSxS/<assembly>/.
    echo "Extracting x86 SxS assembly family from ESD image $OS_IMAGE..."
    7z x -y -o"$TMP/osimg" "$src" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_microsoft.windows.common-controls_6595*" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_microsoft.windows.gdiplus_6595*" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_microsoft.windows.systemcompatible_6595*" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_microsoft.windows.isolationautomation_6595*" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_microsoft.windows.i..utomation.proxystub_6595*" \
      "$OS_IMAGE/Windows/WinSxS/x86_microsoft.windows.common-controls_6595*" \
      "$OS_IMAGE/Windows/WinSxS/x86_microsoft.windows.gdiplus_6595*" \
      "$OS_IMAGE/Windows/WinSxS/x86_microsoft.windows.systemcompatible_6595*" \
      "$OS_IMAGE/Windows/WinSxS/x86_microsoft.windows.isolationautomation_6595*" \
      "$OS_IMAGE/Windows/WinSxS/x86_microsoft.windows.i..utomation.proxystub_6595*" \
      >/dev/null
    MANIFEST_COUNT=$(find "$OSI/Windows/WinSxS/Manifests" -name "x86_microsoft.windows.*_6595*.manifest" 2>/dev/null | wc -l)
    [ "$MANIFEST_COUNT" -ge 5 ] || { echo "ERROR: expected the x86 6595 SxS manifests in ESD image $OS_IMAGE, found $MANIFEST_COUNT" >&2; exit 1; }
    find "$OSI/Windows/WinSxS/Manifests" -name "x86_microsoft.windows.*_6595*.manifest" | while read -r f; do
      echo "add $f /Windows/WinSxS/Manifests/$(basename "$f")"
    done >> "$TMP/graft.cmds"
    find "$OSI/Windows/WinSxS" -maxdepth 2 -type f ! -path "*/Manifests/*" -path "*/x86_microsoft.windows.*_6595*" | while read -r f; do
      rel="''${f#"$OSI"}"
      echo "add $f $rel"
    done >> "$TMP/graft.cmds"

    # Graft 2b: the x86 VC90 CRT SxS assembly (9.0.30729.9635: 3 payload DLLs + own
    # manifest) plus its policy.9.0 publisher-policy manifest (the (now-removed) sxsFamilyRegex note:
    # H2OFFT-W requests 9.0.21022.8; the policy + Winners redirect it to 30729.9635).
    echo "Extracting x86 VC90 CRT SxS assembly from ESD image $OS_IMAGE..."
    7z x -y -o"$TMP/osimg" "$src" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_microsoft.vc90.crt_*" \
      "$OS_IMAGE/Windows/WinSxS/Manifests/x86_policy.9.0.microsoft.vc90.crt_*" \
      "$OS_IMAGE/Windows/WinSxS/x86_microsoft.vc90.crt_*" \
      >/dev/null
    VC90_COUNT=$(find "$OSI/Windows/WinSxS/Manifests" -name "x86_microsoft.vc90.crt_*.manifest" 2>/dev/null | wc -l)
    [ "$VC90_COUNT" -ge 1 ] || { echo "ERROR: expected the x86 VC90 CRT SxS manifests in ESD image $OS_IMAGE, found $VC90_COUNT" >&2; exit 1; }
    find "$OSI/Windows/WinSxS/Manifests" -name "x86_microsoft.vc90.crt_*.manifest" -o -name "x86_policy.9.0.microsoft.vc90.crt_*.manifest" | while read -r f; do
      echo "add $f /Windows/WinSxS/Manifests/$(basename "$f")"
    done >> "$TMP/graft.cmds"
    find "$OSI/Windows/WinSxS" -maxdepth 2 -type f ! -path "*/Manifests/*" -path "*/x86_microsoft.vc90.crt_*" | while read -r f; do
      rel="''${f#"$OSI"}"
      echo "add $f $rel"
    done >> "$TMP/graft.cmds"

    # Graft 2c: extract the x86 sidecar DLLs NEVER to be grafted into the image but
    # exported alongside it (see wow64SidecarFiles note: booting a boot.wim whose
    # SysWOW64 contains them bugchecks). The bios payload stages them next to
    # H2OFFT-W.exe instead; the 32-bit loader checks the application directory first.
    # 7z is case-sensitive for payload names (round-18 KernelBase lesson).
    echo "Extracting x86 sidecar DLLs from ESD image $OS_IMAGE..."
    SIDEZIP_ARGS=()
    for f in ${lib.concatStringsSep " " wow64SidecarFiles}; do
      SIDEZIP_ARGS+=("$OS_IMAGE/Windows/SysWOW64/$f")
    done
    7z x -y -o"$TMP/sidecar" "$src" "''${SIDEZIP_ARGS[@]}" >/dev/null
    for f in ${lib.concatStringsSep " " wow64SidecarFiles}; do
      [ -s "$TMP/sidecar/$OS_IMAGE/Windows/SysWOW64/$f" ] || { echo "ERROR: ESD image $OS_IMAGE lost SysWOW64/$f (x86 sidecar)" >&2; exit 1; }
    done
    mkdir -p "$out/sidecar"
    for f in ${lib.concatStringsSep " " wow64SidecarFiles}; do
      cp "$TMP/sidecar/$OS_IMAGE/Windows/SysWOW64/$f" "$out/sidecar/$f"
    done

    # Graft 2d: the x86 api-set stub files + gdi32full (all ESD-official). The 32-bit
    # (WOW64) loader resolves the api-set *names* it sees in import tables against
    # FILES in X:\Windows\SysWOW64, while the ESD only packages them under
    # Windows/SysWOW64/downlevel/ - a directory the 32-bit DLL search path does not
    # include. Grafting the downlevel stubs flat into SysWOW64 (round-22 replica
    # validated: boot fine + probe3 all-ok for every user32/gdi32/ole32 api-set
    # except the schema-only gdi-internal-uap one, which the bios package provides
    # as a forwarding shim next to H2OFFT-W) is what unfixes gdi32/user32/shell32/ole32.
    echo "Grafting x86 api-set stubs (from SysWOW64 downlevel) + gdi32full into SysWOW64 root..."
    7z x -y -o"$TMP/apistub" "$src" "$OS_IMAGE/Windows/SysWOW64/downlevel/api-ms-*.dll" >/dev/null
    STUBS=$(find "$TMP/apistub/$OS_IMAGE/Windows/SysWOW64/downlevel" -name "api-ms-*.dll" | wc -l)
    [ "$STUBS" -ge 90 ] || { echo "ERROR: expected ~112 x86 api-set stub files in ESD image $OS_IMAGE, found $STUBS" >&2; exit 1; }
    find "$TMP/apistub/$OS_IMAGE/Windows/SysWOW64/downlevel" -name "api-ms-*.dll" | while read -r f; do
      echo "add $f /Windows/SysWOW64/$(basename "$f")"
    done >> "$TMP/graft.cmds"
    echo "add $TMP/sidecar/$OS_IMAGE/Windows/SysWOW64/gdi32full.dll /Windows/SysWOW64/gdi32full.dll" >> "$TMP/graft.cmds"

    # Graft 3: the SxS Winners registry entries, generated from the same ESD's SOFTWARE hive
    # (the SxS binder resolves system assemblies through this registry index, not the
    # directory scan). Emitted as explicit `reg add` commands in a generated batch file that
    # startnet.cmd executes at boot - never rewrites the hive file itself. Values stay
    # version-agnostic because they are re-derived from each ESD's hive at build time.
    wimlib-imagex extract "$src" "$OS_IMAGE" /Windows/System32/config/SOFTWARE --dest-dir="$TMP/hive" --no-acls
    hivexregedit --export "$TMP/hive/SOFTWARE" '\Microsoft\Windows\CurrentVersion\SideBySide\Winners' > "$TMP/winners-all.reg" 2>/dev/null
    [ -s "$TMP/winners-all.reg" ] || { echo "ERROR: could not export SxS Winners from ESD image $OS_IMAGE SOFTWARE hive" >&2; exit 1; }
    awk '
      /^\[\\Microsoft\\Windows\\CurrentVersion\\SideBySide\\Winners\\x86_(microsoft\.windows\.(systemcompatible|isolationautomation|i\.\.utomation\.proxystub|common-controls|gdiplus)|microsoft\.vc90\.crt|policy\.9\.0\.microsoft\.vc90\.crt)_/ {
        inkeep = 1
        key = $0
        gsub(/^\[/, "", key); gsub(/\]$/, "", key)
        sub(/^\\Microsoft\\/, "HKLM\\Software\\Microsoft\\", key)
        next
      }
      /^\[/ { inkeep = 0; next }
      inkeep && /^@=hex\(1\):/ {
        s = $0; sub(/^@=hex\(1\):/, "", s)
        n = split(s, a, ",")
        out = ""
        for (i = 1; i <= n; i++) if (a[i] != "00") out = out sprintf("%c", strtonum("0x" a[i]))
        print "reg add \"" key "\" /ve /t REG_SZ /d \"" out "\" /f"
        next
      }
      inkeep && /"=hex\(3\):/ {
        vname = $0; sub(/^"/, "", vname); sub(/"=hex\(3\):.*$/, "", vname)
        vdata = $0; sub(/^"[^"]*"=hex\(3\):/, "", vdata)
        print "reg add \"" key "\" /v \"" vname "\" /t REG_BINARY /d " vdata " /f"
        next
      }
      inkeep { next }
    ' "$TMP/winners-all.reg" > "$TMP/sxs-winners.cmd"
    echo "@echo off" > "$TMP/sxs-winners.cmd.tmp"
    echo "rem Generated by pkgs/winpe-image from this ESD's own SOFTWARE hive." >> "$TMP/sxs-winners.cmd.tmp"
    echo "rem SxS binder resolves system assemblies through these registry Winners entries." >> "$TMP/sxs-winners.cmd.tmp"
    cat "$TMP/sxs-winners.cmd" >> "$TMP/sxs-winners.cmd.tmp"
    mv "$TMP/sxs-winners.cmd.tmp" "$TMP/sxs-winners.cmd"
    ADD_COUNT=$(grep -c "^reg add" "$TMP/sxs-winners.cmd")
    [ "$ADD_COUNT" -ge 10 ] || { echo "ERROR: generated sxs-winners.cmd has only $ADD_COUNT reg add lines (expected >= 10)" >&2; exit 1; }
    # cmd requires CRLF; convert before grafting.
    sed -i 's/$/\r/' "$TMP/sxs-winners.cmd"
    echo "add $TMP/sxs-winners.cmd /Windows/sxs-winners.cmd" >> "$TMP/graft.cmds"

    # Apply all grafts in one pass (wimupdate is atomic; any error aborts the whole batch).
    wimlib-imagex update "$out/sources/boot.wim" < "$TMP/graft.cmds"

    runHook postInstall
  '';

  # Update flow: fetch the Windows Update product catalog, locate the current client ESD, prefetch + structurally validate it, then rewrite this file.
  # Every predictable failure (catalog layout, edition rename, missing boot files) exits with a named error BEFORE default.nix is touched.
  # Structural changes that no script can predict (new distribution mechanism, image reorganization) fail loudly here and need a human-authored fix.
  # x86 helper DLLs staged next to 32-bit flashers by the bios package (see
  # wow64SidecarFiles note & graft 2c: these must NOT live in the boot.wim).
  passthru.wow64SidecarFiles = wow64SidecarFiles;

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
      # Target resolution: pass the flake checkout as $1 (recommended when running the store-built binary via `nix run`), or rely on $0 sitting next to default.nix when executed from a source tree.
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
      [ -n "$IMAGE_COUNT" ] && [ "$IMAGE_COUNT" -ge 2 ] || { echo "ERROR: expected >= 2 images (1: boot environment, plus a full-Windows image), got: $IMAGE_COUNT" >&2; exit 1; }
      wimlib-imagex dir "$ESD_STORE_PATH" 1 --path=/efi/microsoft/boot/bcd >/dev/null 2>&1 || { echo "ERROR: ESD image 1 lost /efi/microsoft/boot/bcd" >&2; exit 1; }
      wimlib-imagex dir "$ESD_STORE_PATH" 1 --path=/boot/boot.sdi >/dev/null 2>&1 || { echo "ERROR: ESD image 1 lost /boot/boot.sdi" >&2; exit 1; }
      OS_OK=""
      for i in $(seq 1 "$IMAGE_COUNT"); do
        if wimlib-imagex dir "$ESD_STORE_PATH" "$i" --path=/Windows/System32/Recovery/Winre.wim >/dev/null 2>&1; then
          OS_OK=1
          break
        fi
      done
      [ -n "$OS_OK" ] || { echo "ERROR: no ESD image contains /Windows/System32/Recovery/Winre.wim - the WinRE-based boot.wim build would fail" >&2; exit 1; }

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
    # The x86 sidecar DLLs must exist (bios package stages them next to H2OFFT-W).
    for f in ${lib.concatStringsSep " " wow64SidecarFiles}; do
      [ -s "$out/sidecar/$f" ] || { echo "ERROR: sidecar DLL missing: $out/sidecar/$f" >&2; exit 1; }
    done
    [ -s "$out/EFI/Microsoft/boot/resources/bootres.dll" ]
    [ -s "$out/EFI/Microsoft/boot/fonts/wgl4_boot.ttf" ]

    # Regression tripwire: bootmgr's ramdisk loader fails LZMS WIMs with 0xc00000bb; bootable boot.wim must stay LZX.
    wimlib-imagex info "$out/sources/boot.wim" | grep -q "Compression:.*LZX"

    # The boot.wim must be the WinRE-based image with the WOW64 grafts intact: without them
    # 32-bit flashers (FWUpdLcl.exe) die at process creation (RESEARCH-NOTES.md §0.6).
    # Extract-based assertion: each required 32-bit support file must be extractable
    # from the boot.wim (the strongest possible presence proof). wimlib puts a single
    # extracted file flat in --dest-dir, so assert on the basename.
    mkdir -p checktree
    for p in ${lib.concatStringsSep " " requiredWimPaths}; do
      name=$(basename "$p")
      rm -f "checktree/$name"
      wimlib-imagex extract "$out/sources/boot.wim" 1 "$p" --dest-dir=checktree --no-acls >/dev/null 2>&1 \
        || { echo "ERROR: boot.wim is missing required 32-bit support file: $p" >&2; exit 1; }
      [ -s "checktree/$name" ] || { echo "ERROR: required file extracted empty: $p" >&2; exit 1; }
    done
    wimlib-imagex dir "$out/sources/boot.wim" > wimdir.txt
    grep -qiE "systemcompatible" wimdir.txt \
      || { echo "ERROR: boot.wim is missing the x86 SystemCompatible SxS manifest" >&2; exit 1; }
    grep -qiE "proxystub" wimdir.txt \
      || { echo "ERROR: boot.wim is missing the x86 IsolationAutomation.ProxyStub SxS manifest" >&2; exit 1; }
    # The generated .cmd must actually contain x86 Winners reg add lines (the presence
    # check above only proves the file exists).
    wimlib-imagex extract "$out/sources/boot.wim" 1 /Windows/sxs-winners.cmd --dest-dir=regchk --no-acls >/dev/null
    grep -qF 'reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\SideBySide\Winners\x86_microsoft.windows.systemcompatible' regchk/sxs-winners.cmd \
      || { echo "ERROR: sxs-winners.cmd lacks x86 SystemCompatible Winners reg add entries" >&2; exit 1; }
    grep -qF 'reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\SideBySide\Winners\x86_microsoft.windows.i..utomation.proxystub' regchk/sxs-winners.cmd \
      || { echo "ERROR: sxs-winners.cmd lacks x86 ProxyStub Winners reg add entries" >&2; exit 1; }
    grep -qF 'reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\SideBySide\Winners\x86_microsoft.vc90.crt' regchk/sxs-winners.cmd \
      || { echo "ERROR: sxs-winners.cmd lacks x86 VC90 CRT Winners reg add entries" >&2; exit 1; }
    grep -qF 'reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\SideBySide\Winners\x86_policy.9.0.microsoft.vc90.crt' regchk/sxs-winners.cmd \
      || { echo "ERROR: sxs-winners.cmd lacks the x86 VC90 CRT publisher-policy Winners reg add entries" >&2; exit 1; }
    # The VC90 CRT assembly itself must be in the WinSxS store of the boot.wim (manifest
    # + at least one payload), otherwise H2OFFT-W dies at actctx (RESEARCH-NOTES.md round 19).
    wimlib-imagex dir "$out/sources/boot.wim" | grep -iE "WinSxS/Manifests/x86_microsoft\.vc90\.crt" \
      || { echo "ERROR: boot.wim is missing the x86 VC90 CRT SxS manifest" >&2; exit 1; }
    wimlib-imagex dir "$out/sources/boot.wim" | grep -iE "WinSxS/Manifests/x86_policy\.9\.0\.microsoft\.vc90\.crt" \
      || { echo "ERROR: boot.wim is missing the x86 VC90 CRT publisher-policy manifest" >&2; exit 1; }
    wimlib-imagex dir "$out/sources/boot.wim" | grep -iE "WinSxS/x86_microsoft\.vc90\.crt.*/msvcr90\.dll" \
      || { echo "ERROR: boot.wim is missing the x86 VC90 CRT payload (msvcr90.dll)" >&2; exit 1; }

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
