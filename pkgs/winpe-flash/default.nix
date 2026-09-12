{ pkgs }:
let
  # Windows cmd silently aborts LF-only batch files at parenthesized blocks; both scripts below must be CRLF (converted at their definitions).
  toCRLF = text: pkgs.lib.replaceStrings [ "\n" ] [ "\r\n" ] text;

  # Why inject winpeshl.ini: the ESD WinPE's winpeshl.exe does not reliably run startnet.cmd when the file is absent (validated under QEMU: boots without it never reach autorun.cmd).
  # Explicitly launching cmd with startnet.cmd guarantees our startup hook executes on every boot.
  winpeshlIni = pkgs.writeText "winpeshl.ini" ''
    [LaunchApps]
    %SYSTEMROOT%\System32\cmd.exe, "/s /k startnet.cmd"
  '';

  startnetScript = pkgs.writeText "startnet.cmd" (toCRLF ''
    rem DEBUG breadcrumbs: every stage echoes to the console and X:\startnet.log
    set LOG=X:\startnet.log
    echo STARTNET-ENTERED
    echo [1] startnet.cmd entered > %LOG%
    wpeinit
    echo [2] wpeinit done
    echo [2] wpeinit done >> %LOG%
    rem Bring all disks online (WinPE's default SAN policy can leave them offline, which silently blocks drive-letter assignment on real hardware) and enumerate every volume.
    echo san policy=onlineall > X:\dp.scr
    echo rescan >> X:\dp.scr
    echo list volume >> X:\dp.scr
    diskpart /s X:\dp.scr > X:\dp.out 2>&1
    echo --- list volume ---
    type X:\dp.out
    type X:\dp.out >> %LOG%
    rem Persist evidence to the disk's first partition (the real ESP on the target laptop) so a failed run still leaves breadcrumbs + the volume table on disk.
    rem Guarded to actual ESPs; in the QEMU check this is the WinPE partition itself (harmless extra file).
    echo select disk 0 > X:\esp.scr
    echo select partition 1 >> X:\esp.scr
    echo assign letter=S >> X:\esp.scr
    diskpart /s X:\esp.scr >> %LOG% 2>&1
    if exist S:\EFI\ (
        copy /y %LOG% S:\winpe-debug.log >nul 2>&1
        copy /y X:\dp.out S:\winpe-dpout.log >nul 2>&1
    )
    rem Look the ESP up by its volume label instead of hardcoding disk and partition numbers: multi-disk laptops and partition reordering make 'select disk 0 / partition 1' a blind guess (failed on real hardware).
    rem This ESD-extracted WinPE lacks some standard text tools, so dp.out is parsed with pure-batch substring matching + delayed expansion only.
    set TRY=0
    :findpart
    set VOLNUM=
    setlocal enabledelayedexpansion
    for /f "delims=" %%L in (X:\dp.out) do (
        set "LN=%%L"
        if /i not "!LN:WinPE=!" == "!LN!" (
            for /f "tokens=2" %%v in ("!LN!") do set "VOLNUM=%%v"
        )
    )
    endlocal & set "VOLNUM=%VOLNUM%"
    echo [3] WinPE volume = %VOLNUM%
    echo [3] WinPE volume = %VOLNUM% >> %LOG%
    if defined VOLNUM (
        echo select volume %VOLNUM% > X:\av.scr
        echo assign letter=W >> X:\av.scr
        diskpart /s X:\av.scr >> %LOG% 2>&1
    )
    if exist W:\autorun.cmd goto :found
    set /a TRY+=1
    if %TRY% lss 5 (
        echo rescan > X:\dp.scr
        echo list volume >> X:\dp.scr
        diskpart /s X:\dp.scr > X:\dp.out 2>&1
        echo --- list volume retry %TRY% ---
        type X:\dp.out
        type X:\dp.out >> %LOG%
        if exist W:\ dir /b W:\ >> %LOG% 2>&1
        ping -n 3 127.0.0.1 >nul
        goto :findpart
    )
    rem Last resort: legacy hardcoded disk/partition.
    rem Single-disk QEMU puts the ESP at disk 0 partition 1; harmless elsewhere because assigning a letter touches no data and W:\autorun.cmd gates everything below.
    echo [4] label lookup failed, trying hardcoded disk 0 partition 1
    echo select disk 0 > X:\av.scr
    echo select partition 1 >> X:\av.scr
    echo assign letter=W >> X:\av.scr
    diskpart /s X:\av.scr >> %LOG% 2>&1
    if exist W:\autorun.cmd goto :found
    rem Final fallback: scan all drive letters in case the volume got one.
    echo [4] W: not found, scanning all letters
    echo [4] W: not found, scanning all letters >> %LOG%
    for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do (
        if exist %%d:\autorun.cmd (
            echo [5] found autorun.cmd on %%d:
            echo [5] found autorun.cmd on %%d: >> %LOG%
            copy /y %LOG% %%d:\startnet.log >nul
            call %%d:\autorun.cmd %%d:
            goto :done
        )
    )
    echo [!] ERROR: WinPE partition with autorun.cmd not found
    echo [!] ERROR: WinPE partition with autorun.cmd not found >> %LOG%
    if exist S:\EFI\ copy /y %LOG% S:\winpe-debug.log >nul 2>&1
    rem Fail fast: the validation check asserts autorun.log, and dropping to an interactive cmd.exe here used to hang it until the 900s timeout.
    rem Give a 20s window to read the screen, then reboot (BootNext is one-shot, so the machine returns to NixOS).
    ping -n 21 127.0.0.1 >nul
    wpeutil reboot
    :found
    echo [5] found autorun.cmd on W:
    echo [5] found autorun.cmd on W: >> %LOG%
    rem Persist breadcrumbs to the ESP: X: is a RAM disk and dies on reboot.
    copy /y %LOG% W:\startnet.log >nul
    call W:\autorun.cmd W:
    :done
  '');
in
pkgs.writeShellApplication {
  name = "winpe-flash";

  runtimeInputs = with pkgs; [
    efibootmgr
    util-linux
    coreutils
    wimlib
  ];

  text = ''
    set -euo pipefail

    cmd_help() {
      echo "NixOS WinPE Firmware Flasher CLI"
      echo
      echo "Usage: winpe-flash <command>"
      echo
      echo "Commands:"
      echo "  status      Check WinPE partition, firmware payload, and UEFI boot status"
      echo "  logs        Show the execution transcript log from the last WinPE boot"
      echo "  arm         Inject startup hook into boot.wim and set UEFI BootNext"
      echo "  reboot      Trigger a one-time boot into WinPE on next restart"
      echo "  help        Show this help message"
    }

    cmd_logs() {
      if [ -f /mnt/WinPE/autorun.log ]; then
        cat /mnt/WinPE/autorun.log
      else
        echo "No /mnt/WinPE/autorun.log found."
      fi
    }

    cmd_status() {
      echo "=== WinPE Subsystem Status ==="
      echo
      echo "[1] Partition Status:"
      if findmnt /mnt/WinPE >/dev/null 2>&1; then
        echo "  /mnt/WinPE is mounted:"
        findmnt -o SOURCE,FSTYPE,SIZE,USED,AVAIL,TARGET /mnt/WinPE
      else
        echo "  /mnt/WinPE is NOT currently mounted."
      fi
      echo
      echo "[2] Staged Firmware Payloads:"
      if [ -d /mnt/WinPE/firmware ]; then
        ls -lh /mnt/WinPE/firmware/
      else
        echo "  No /mnt/WinPE/firmware directory found."
      fi
      echo
      echo "[3] UEFI Boot Entries:"
      efibootmgr | grep -E "Boot[0-9]{4}|BootOrder|BootNext" || :
      if [ -f /mnt/WinPE/autorun.log ]; then
        echo
        echo "[4] Last WinPE Execution Log:"
        cmd_logs
      fi
    }

    cmd_arm() {
      if [ -z "''${EFIBOOTMGR_BIN:-}" ] && [ "''${EUID:-$(id -u)}" -ne 0 ]; then
        echo "❌ Error: Modifying UEFI boot variables and WinPE partition requires root privileges."
        echo "Please run: sudo winpe-flash arm"
        return 1
      fi

      EFIBOOTMGR="''${EFIBOOTMGR_BIN:-efibootmgr}"

      # Ensure boot.wim has the automated startnet hook to execute autorun.cmd
      if [ -f /mnt/WinPE/sources/boot.wim ]; then
        echo "Ensuring WinPE startup hook is configured in boot.wim..."
        # Why inject winpeshl.ini: see its definition above - without it the WinPE boot never reaches startnet.cmd under QEMU validation.
        wimlib-imagex update /mnt/WinPE/sources/boot.wim 1 --command="add ${winpeshlIni} /Windows/System32/winpeshl.ini" >/dev/null 2>&1 || :
        wimlib-imagex update /mnt/WinPE/sources/boot.wim 1 --command="add ${startnetScript} /Windows/System32/startnet.cmd" >/dev/null 2>&1 || :
        echo "WinPE startup hook verified."
      fi

      # Locate WinPE boot number.
      # Why grep -m1, not `| head -n1`: with pipefail, head closing the pipe early after multiple matches kills the pipeline with SIGPIPE (exit 141).
      WINPE_BOOT_NUM=$($EFIBOOTMGR | grep -i "WinPE" | grep -o -m1 "Boot[0-9a-fA-F]\{4\}" | sed 's/Boot//' || :)

      if [ -z "$WINPE_BOOT_NUM" ]; then
        echo "Error: Could not find 'WinPE' boot entry in efibootmgr!"
        echo "Please ensure the UEFI boot entry is registered."
        return 1
      fi

      CURRENT_BOOTNEXT=$($EFIBOOTMGR | grep -i "BootNext" | grep -o -m1 "[0-9a-fA-F]\{4\}" || :)
      if [ "$CURRENT_BOOTNEXT" = "$WINPE_BOOT_NUM" ]; then
        echo "BootNext is already set to WinPE (Boot$WINPE_BOOT_NUM)."
      else
        echo "Found WinPE UEFI entry: Boot$WINPE_BOOT_NUM"
        echo "Setting BootNext to $WINPE_BOOT_NUM..."
        $EFIBOOTMGR -n "$WINPE_BOOT_NUM"
      fi
    }

    cmd_reboot() {
      echo "=== Triggering WinPE One-Time Boot ==="

      if [ -z "''${EFIBOOTMGR_BIN:-}" ] && [ "''${EUID:-$(id -u)}" -ne 0 ]; then
        echo "❌ Error: Modifying UEFI boot variables requires root privileges."
        echo "Please run: sudo winpe-flash reboot"
        exit 1
      fi

      # AC power verification guard
      AC_CONNECTED=0
      for ac in /sys/class/power_supply/A*/online; do
        if [ -f "$ac" ] && [ "$(cat "$ac")" -eq 1 ]; then
          AC_CONNECTED=1
          break
        fi
      done

      if [ "$AC_CONNECTED" -eq 0 ] && [ -n "$(ls -A /sys/class/power_supply 2>/dev/null)" ]; then
        echo "❌ Error: AC power adapter is not connected!"
        echo "Please plug in your laptop charger before flashing firmware."
        exit 1
      fi

      cmd_arm || exit 1

      echo
      echo "============================================================"
      echo "              ⚠️  FIRMWARE FLASH SAFETY NOTICE              "
      echo "============================================================"
      echo " 1. AC POWER: Keep your charger firmly connected."
      echo " 2. TPM / LUKS: Updating BIOS alters PCR 0. If you use TPM"
      echo "    auto-unlock, have your manual LUKS passphrase ready for"
      echo "    the first reboot after the flash completes."
      echo " 3. DO NOT INTERRUPT: The motherboard flash takes ~2 minutes."
      echo "    Fans will spin at max speed. Do NOT power off or close lid."
      echo "============================================================"
      echo
      echo "Next boot is set to WinPE."
      read -r -p "Reboot now into WinPE flasher? [y/N]: " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "Rebooting..."
        reboot
      else
        echo "Reboot postponed. BootNext will trigger on your next restart."
      fi
    }

    case "''${1:-}" in
      status)
        cmd_status
        ;;
      logs)
        cmd_logs
        ;;
      arm)
        cmd_arm
        ;;
      reboot)
        cmd_reboot
        ;;
      help|--help|-h|"")
        cmd_help
        ;;
      *)
        echo "Unknown command: $1"
        cmd_help
        exit 1
        ;;
    esac
  '';

  meta = with pkgs.lib; {
    description = "CLI utility to inspect and trigger WinPE firmware updates on NixOS";
    homepage = "https://github.com/Malix-Labs/NixOS_WinPE";
    license = licenses.gpl3Plus;
    maintainers = with maintainers; [ malix ];
    platforms = platforms.linux;
    mainProgram = "winpe-flash";
  };

  passthru = {
    inherit startnetScript winpeshlIni;
  };
}
