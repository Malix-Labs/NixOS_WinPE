{ pkgs }:
let
  startnetScript = pkgs.writeScript "startnet.cmd" ''
    @echo off
    wpeinit
    echo automount enable > X:\mount.scr
    echo rescan >> X:\mount.scr
    diskpart /s X:\mount.scr >nul 2>&1
    del X:\mount.scr 2>nul
    for %%d in (c d e f g h i j k l m n o p q r s t u v w x y z C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist %%d:\autorun.cmd (
            call %%d:\autorun.cmd
            goto :done
        )
    )
    cmd.exe
    :done
  '';
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

    show_help() {
      echo "NixOS WinPE Firmware Flasher CLI"
      echo
      echo "Usage: winpe-flash <command>"
      echo
      echo "Commands:"
      echo "  status      Check WinPE partition, firmware payload, and UEFI boot status"
      echo "  logs        Show the execution transcript log from the last WinPE boot"
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

    cmd_reboot() {
      echo "=== Triggering WinPE One-Time Boot ==="

      if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
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

      # Ensure boot.wim has the automated startnet hook to execute autorun.cmd
      if [ -f /mnt/WinPE/sources/boot.wim ]; then
        echo "Ensuring WinPE startup hook is configured in boot.wim..."
        wimlib-imagex update /mnt/WinPE/sources/boot.wim 1 --command="add ${startnetScript} /Windows/System32/startnet.cmd" >/dev/null 2>&1 || :
        echo "WinPE startup hook verified."
      fi

      # Locate WinPE boot number
      WINPE_BOOT_NUM=$(efibootmgr | grep -i "WinPE" | grep -o "Boot[0-9a-fA-F]\{4\}" | head -n1 | sed 's/Boot//' || :)

      if [ -z "$WINPE_BOOT_NUM" ]; then
        echo "Error: Could not find 'WinPE' boot entry in efibootmgr!"
        echo "Please ensure the UEFI boot entry is registered."
        exit 1
      fi

      echo "Found WinPE UEFI entry: Boot$WINPE_BOOT_NUM"
      echo "Setting BootNext to $WINPE_BOOT_NUM..."
      efibootmgr -n "$WINPE_BOOT_NUM"

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
        echo "Reboot postponed. BootNext $WINPE_BOOT_NUM will trigger on your next restart."
      fi
    }

    case "''${1:-help}" in
      status)
        cmd_status
        ;;
      logs)
        cmd_logs
        ;;
      reboot|flash)
        cmd_reboot
        ;;
      help|--help|-h)
        show_help
        ;;
      *)
        echo "Unknown command: $1"
        show_help
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
    inherit startnetScript;
  };
}
