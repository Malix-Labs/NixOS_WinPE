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
    set LOGFILE=%~dp0autorun.log
    echo ======================================================== > %LOGFILE%
    echo   NixOS-Generated WinPE Firmware Flasher Execution Log >> %LOGFILE%
    echo ======================================================== >> %LOGFILE%
    echo Timestamp: %DATE% %TIME% >> %LOGFILE%
    echo Non-Interactive Mode: ${if cfg.nonInteractive then "ENABLED" else "DISABLED"} >> %LOGFILE%
    echo. >> %LOGFILE%

    echo ========================================================
    echo   NixOS-Generated WinPE Firmware Flasher
    echo ========================================================
    echo.

    set FOUND_PAYLOAD=0

    ${
      if activePayloads != { } then
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            _: p:
            let
              flags = lib.concatStringsSep " " p.silentFlags;
            in
            ''
              if exist "%~dp0firmware\${p.targetFileName}" (
                  call :run_payload "%~dp0firmware\${p.targetFileName}" "${p.targetFileName}" "${flags}"
              )
            ''
          ) activePayloads
        )
      else
        ''
          for %%f in (%~dp0firmware\*.exe %~dp0firmware\*.bat %~dp0firmware\*.cmd) do (
              call :run_payload "%%f" "%%~nxf" ""
          )
        ''
    }

    if %FOUND_PAYLOAD%==0 (
        echo [WARNING] No .exe payload found in \firmware\ directory!
        echo [WinPE] [WARNING] No .exe payload found in firmware directory! >> %LOGFILE%
        ${
          if cfg.nonInteractive then
            ''
              echo [WinPE] Non-interactive mode active: rebooting to Linux immediately... >> %LOGFILE%
              wpeutil reboot
            ''
          else
            ''
              echo Type 'wpeutil reboot' to return to Linux.
              echo Opening command prompt for manual maintenance...
              cmd.exe
            ''
        }
    )
    goto :done

    :run_payload
    set FOUND_PAYLOAD=1
    echo Found firmware package: %~2
    echo [WinPE] Found firmware package: %~2 >> %LOGFILE%
    echo Staging firmware update...
    echo [WinPE] Executing flasher: %1 %~3 >> %LOGFILE%
    start /wait "" %1 %~3
    if errorlevel 1 (
        echo [WinPE] Flasher process failed. >> %LOGFILE%
        echo.
        echo ========================================================
        echo   [ERROR] Firmware flash utility failed!
        echo ========================================================
        echo.
        echo Possible reasons:
        echo   - AC power adapter is not connected [Error 1702]
        echo   - Battery level is too low [below 30%%]
        echo.
        echo Available actions:
        echo   1. Plug in AC power and re-run the updater:
        echo        autorun.cmd
        echo.
        echo   2. Reboot back into Linux without updating:
        echo        wpeutil reboot
        echo.
        echo ========================================================
        ${
          if cfg.nonInteractive then
            ''
              echo [WinPE] Non-interactive mode active: rebooting to Linux immediately... >> %LOGFILE%
              echo Non-interactive mode active. Rebooting back to Linux in 3 seconds...
              timeout /t 3
              wpeutil reboot
              exit /b 1
            ''
          else
            ''
              echo Opening command prompt for manual maintenance...
              cmd.exe
              exit /b 1
            ''
        }
    ) else (
        echo.
        echo Flash staging completed. Rebooting system in 5 seconds...
        echo [WinPE] Flash staging completed successfully. Rebooting... >> %LOGFILE%
        timeout /t 5
        wpeutil reboot
        exit /b 0
    )

    :done
  '';
in
{
  options.hardware.winpe = {
    enable = lib.mkEnableOption "WinPE bare-metal firmware updater and recovery subsystem";

    nonInteractive = lib.mkEnableOption "fully automated non-interactive firmware execution with log persistence and immediate reboot";

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

    imagePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/winpe-image { };
      description = "The base WinPE filesystem package deployed to mountPoint when populateImage is enabled.";
    };

    populateImage = lib.mkEnableOption "automatic declarative population of the base WinPE image files to the mountPoint";

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
    // (lib.optionalAttrs cfg.populateImage {
      "${cfg.mountPoint}"."C+" = {
        mode = "0755";
        argument = "${cfg.imagePackage}";
      };
    })
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
            if [ -z "$CURRENT_BIOS" ]; then
              NEEDS_UPDATE=1
            elif [ "$CURRENT_BIOS" != "$PKG_VERSION" ] && [[ "$TARGET_NAME" != *"$CURRENT_BIOS"* ]]; then
              echo "Firmware payload $TARGET_NAME (version $PKG_VERSION) does not match current BIOS ($CURRENT_BIOS)."
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
