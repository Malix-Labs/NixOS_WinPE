{ pkgs }:
let
  # Windows cmd silently aborts LF-only batch files at parenthesized blocks;
  # both scripts below must be CRLF (converted at their definitions).
  toCRLF = text: pkgs.lib.replaceStrings [ "\n" ] [ "\r\n" ] text;

  # Why inject winpeshl.ini: the ESD WinPE's winpeshl.exe does not reliably run
  # startnet.cmd when the file is absent (validated under QEMU: boots without
  # it never reach autorun.cmd). Explicitly launching cmd with startnet.cmd
  # guarantees our startup hook executes on every boot.
  winpeshlIni = pkgs.writeText "winpeshl.ini" ''
    [LaunchApps]
    %SYSTEMROOT%\System32\cmd.exe, "/s /k startnet.cmd"
  '';

  startnetScript = pkgs.writeText "startnet.cmd" (toCRLF ''
    rem DEBUG: echo on so headless screendumps show every stage
    echo STARTNET-ENTERED
    set LOG=X:\startnet.log
    echo [1] startnet.cmd entered > %LOG%
    wpeinit
    echo [2] wpeinit done
    echo [2] wpeinit done >> %LOG%
    rem Locate the WinPE partition (EF00 partitions get no drive letter by
    rem default, so explicitly assign one via diskpart, then verify).
    echo rescan > X:\vol.scr
    echo select disk 0 >> X:\vol.scr
    echo select partition 1 >> X:\vol.scr
    echo assign letter=W >> X:\vol.scr
    set TRY=0
    :findpart
    diskpart /s X:\vol.scr >> %LOG% 2>&1
    del X:\vol.scr 2>nul
    echo [3] diskpart attempt %TRY% done
    echo [3] diskpart attempt %TRY% done >> %LOG%
    if exist W:\autorun.cmd goto :found
    set /a TRY+=1
    if %TRY% lss 5 (
        rem Partition may need a moment to appear after WinPE storage init.
        echo rescan > X:\vol.scr
        ping -n 3 127.0.0.1 >nul
        goto :findpart
    )
    rem Fallback: scan all drive letters in case diskpart picked another one.
    echo [4] W: not found, scanning all letters
    echo [4] W: not found, scanning all letters >> %LOG%
    for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do (
        if exist %%d:\autorun.cmd (
            echo [5] found autorun.cmd on %%d:
            echo [5] found autorun.cmd on %%d: >> %LOG%
            call %%d:\autorun.cmd %%d:
            goto :done
        )
    )
    echo [!] ERROR: WinPE partition with autorun.cmd not found
    echo [!] ERROR: WinPE partition with autorun.cmd not found >> %LOG%
    cmd.exe
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
        # Why inject winpeshl.ini: see its definition above - without it the
        # WinPE boot never reaches startnet.cmd under QEMU validation.
        wimlib-imagex update /mnt/WinPE/sources/boot.wim 1 --command="add ${winpeshlIni} /Windows/System32/winpeshl.ini" >/dev/null 2>&1 || :
        wimlib-imagex update /mnt/WinPE/sources/boot.wim 1 --command="add ${startnetScript} /Windows/System32/startnet.cmd" >/dev/null 2>&1 || :
        echo "WinPE startup hook verified."
      fi

      # Locate WinPE boot number. Why grep -m1, not `| head -n1`: with
      # pipefail, head closing the pipe early after multiple matches kills the
      # pipeline with SIGPIPE (exit 141).
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
