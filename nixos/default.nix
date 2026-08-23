{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.winpe;

  activePayloads = lib.filterAttrs (_: p: p.enable) cfg.payloads;

  defaultAutorun = pkgs.writeScript "autorun.cmd" ''
    @echo off
    echo ========================================================
    echo   NixOS-Generated WinPE Firmware Flasher
    echo ========================================================
    echo.

    set FOUND_PAYLOAD=0

    :: Auto-discover and execute any firmware package placed in the firmware directory
    for %%f in ("%~dp0firmware\*.exe") do (
        set FOUND_PAYLOAD=1
        echo Found firmware package: %%~nxf
        echo Staging firmware update...
        call "%%f"
        if errorlevel 1 (
            echo.
            echo [ERROR] Firmware flash utility failed with error code %errorlevel%!
            echo Opening command prompt for manual diagnostics...
            cmd.exe
            goto :done
        )
        echo.
        echo Flash staging completed. Rebooting system in 5 seconds...
        timeout /t 5
        wpeutil reboot
        goto :done
    )

    if %FOUND_PAYLOAD%==0 (
        echo [WARNING] No .exe payload found in \firmware\ directory!
        echo Opening command prompt for manual maintenance...
        cmd.exe
    )

    :done
  '';
in
{
  options.hardware.winpe = {
    enable = lib.mkEnableOption "WinPE bare-metal firmware updater and recovery subsystem";

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/WinPE";
      description = "Filesystem path where the WinPE partition is mounted.";
    };

    partitionLabel = lib.mkOption {
      type = lib.types.str;
      default = "WinPE";
      description = "Filesystem partition label used to locate and mount the WinPE drive.";
    };

    autoMount = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to automatically configure NixOS fileSystems mount for the WinPE partition.";
    };

    autorunScript = lib.mkOption {
      type = lib.types.package;
      default = defaultAutorun;
      description = "The batch script package deployed to the WinPE root as autorun.cmd.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/winpe-flash { };
      description = "The winpe-flash CLI package to install.";
    };

    cleanFirmwareDirectory =
      lib.mkEnableOption "automatic purging of unmanaged files in the WinPE firmware staging directory on system switch"
      // {
        default = true;
      };

    autoBootOnUpdate =
      lib.mkEnableOption "automatic scheduling of one-time UEFI BootNext into WinPE on system switch when new firmware is staged"
      // {
        default = true;
      };

    payloads = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }: {
            options = {
              enable = lib.mkEnableOption "deployment of this firmware payload" // {
                default = true;
              };

              package = lib.mkOption {
                type = lib.types.package;
                description = "The package derivation containing the executable payload.";
              };

              targetFileName = lib.mkOption {
                type = lib.types.str;
                default = if config ? package && config.package ? name then config.package.name else name;
                description = "The destination filename inside /mnt/WinPE/firmware/.";
              };

              silentFlags = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [
                  "/SILENT"
                  "/VERYSILENT"
                  "/SUPPRESSMSGBOXES"
                ];
                description = "Command-line arguments passed to the executable in WinPE.";
              };
            };
          }
        )
      );
      default = { };
      description = "Firmware payloads and installer executables to stage in WinPE.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ];

    fileSystems = lib.mkIf cfg.autoMount {
      "${cfg.mountPoint}" = {
        device = "/dev/disk/by-label/${cfg.partitionLabel}";
        fsType = "vfat";
        options = [
          "nofail"
          "fmask=0077"
          "dmask=0077"
        ];
      };
    };

    systemd.tmpfiles.settings."10-winpe" = {
      "${cfg.mountPoint}/autorun.cmd"."C+" = {
        mode = "0755";
        argument = "${cfg.autorunScript}";
      };
      "${cfg.mountPoint}/firmware".${if cfg.cleanFirmwareDirectory then "D" else "d"} = {
        mode = "0755";
      };
    }
    // (lib.mapAttrs' (_: p: {
      name = "${cfg.mountPoint}/firmware/${p.targetFileName}";
      value."C+" = {
        mode = "0755";
        argument = "${p.package}";
      };
    }) activePayloads);

    systemd.services.winpe-auto-boot = lib.mkIf (cfg.autoBootOnUpdate && activePayloads != { }) {
      description = "Schedule one-time UEFI BootNext into WinPE when new firmware is staged";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-tmpfiles-setup.service"
        "local-fs.target"
      ];
      path = with pkgs; [
        efibootmgr
        coreutils
        gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        let
          checkPayload = p: ''
            PKG_VERSION="${lib.getVersion p.package}"
            TARGET_NAME="${p.targetFileName}"
            if [ -n "$CURRENT_BIOS" ]; then
              case "$TARGET_NAME" in
                *"$CURRENT_BIOS"*)
                  ;;
                *)
                  if [ "$CURRENT_BIOS" != "$PKG_VERSION" ]; then
                    echo "Firmware payload $TARGET_NAME (version $PKG_VERSION) does not match current BIOS ($CURRENT_BIOS)."
                    NEEDS_UPDATE=1
                  fi
                  ;;
              esac
            else
              NEEDS_UPDATE=1
            fi
          '';
        in
        ''
          WINPE_BOOT_NUM=$(efibootmgr | grep -i "WinPE" | grep -o "Boot[0-9a-fA-F]\{4\}" | head -n1 | sed 's/Boot//' || :)
          if [ -z "$WINPE_BOOT_NUM" ]; then
            echo "WinPE UEFI boot entry not found; skipping BootNext scheduling."
            exit 0
          fi

          CURRENT_BIOS=""
          SYSFS_DMI="''${SYSFS_DMI_DIR:-/sys/class/dmi/id}"
          if [ -r "$SYSFS_DMI/bios_version" ]; then
            CURRENT_BIOS=$(cat "$SYSFS_DMI/bios_version" | tr -d '[:space:]')
          fi

          NEEDS_UPDATE=0
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: checkPayload) activePayloads)}

          if [ "$NEEDS_UPDATE" -eq 1 ]; then
            CURRENT_BOOTNEXT=$(efibootmgr | grep -i "BootNext" | grep -o "[0-9a-fA-F]\{4\}" || :)
            if [ "$CURRENT_BOOTNEXT" = "$WINPE_BOOT_NUM" ]; then
              echo "BootNext is already set to WinPE (Boot$WINPE_BOOT_NUM)."
            else
              echo "Scheduling one-time boot into WinPE (Boot$WINPE_BOOT_NUM) on next restart..."
              efibootmgr -n "$WINPE_BOOT_NUM"
            fi
          else
            echo "All staged firmware payloads match the current BIOS ($CURRENT_BIOS). No update needed."
          fi
        '';
    };
  };
}
