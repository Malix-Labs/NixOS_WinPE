{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.winpe;

  activePayloads = lib.filterAttrs (_: p: p.enable) cfg.payloads;

  # Why CRLF: Windows cmd silently aborts batch files with LF-only line endings at parenthesized blocks (e.g. `if errorlevel 1 (`) - validated under QEMU where the LF script died right after start /wait, while the same logic as CRLF ran to completion.
  # Wine's cmd is lenient, so the wine check cannot catch this.
  toCRLF = text: lib.strings.replaceStrings [ "\n" ] [ "\r\n" ] text;

  defaultAutorun = pkgs.writeText "autorun.cmd" (toCRLF ''
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
              payloadPath =
                if p.entryPoint == "" then
                  "%~dp0firmware\\${p.targetFileName}"
                else
                  "%~dp0firmware\\${p.targetFileName}\\${p.entryPoint}";
            in
            ''
              if exist "${payloadPath}" call :run_payload "${payloadPath}" "${p.targetFileName}" "${flags}"
            ''
          ) activePayloads
        )
      else
        ''
          for %%f in (%~dp0firmware\*.exe %~dp0firmware\*.bat %~dp0firmware\*.cmd) do call :run_payload "%%f" "%%~nxf" ""
        ''
    }

    if %FOUND_PAYLOAD%==0 goto :nopayload
    goto :done

    :nopayload
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
    goto :done

    :run_payload
    set FOUND_PAYLOAD=1
    echo Found firmware package: %~2
    echo [WinPE] Found firmware package: %~2 >> %LOGFILE%
    echo Staging firmware update...
    echo [WinPE] Executing flasher: %~1 %~3 >> %LOGFILE%
    rem Runs the payload synchronously (waits even for GUI-subsystem PE binaries).
    rem Why call and not start /wait: start spawns a second console window and WinPE's desktop heap cannot allocate it - "Not enough memory resources are available to process this command." (validated under QEMU). call executes in this console, waits, and propagates errorlevel.
    rem Why unquoted %~1: wine cmd rejects quoted call targets ("Invalid name"); payload paths live on the ESP and contain no spaces.
    rem Why cd /d: InsydeFlash locates platform.ini and BIOS.fd relative to the process working directory, not the executable path.
    rem Why output capture: InsydeFlash's silent-mode exit codes are deliberately ambiguous (every failure is 259) and its error text only goes to the console - capturing it makes hardware post-mortems possible.
    cd /d "%~dp1"
    set POUT=%~dp1payload.out
    call %~1 %~3 > "%POUT%" 2>&1
    set FLASH_RC=%errorlevel%
    type "%POUT%"
    type "%POUT%" >> %LOGFILE%
    rem Why the exit code is snapshotted into FLASH_RC: the type calls reset errorlevel, and the branch must test the payload's own result.
    rem Why plain zero: platform.ini ships with RETURN_SUCCESSFUL patched to 0,0, so a completed silent flash returns 0 and every failure path returns nonzero.
    if not "%FLASH_RC%"=="0" goto :flashfail
    :flashok
    echo [WinPE] Flash staging completed successfully. Rebooting... >> %LOGFILE%
    echo.
    echo Flash staging completed. Rebooting system in 5 seconds...
    ping -n 6 127.0.0.1 >nul
    wpeutil reboot
    exit /b 0
    :flashfail
    echo [WinPE] Flasher process failed. >> %LOGFILE%
    ${
      if cfg.nonInteractive then
        ''
          echo [WinPE] Non-interactive mode active: rebooting to Linux immediately... >> %LOGFILE%
          ping -n 4 127.0.0.1 >nul
          wpeutil reboot
        ''
      else
        ''
          echo [ERROR] Firmware flash utility failed! Check %LOGFILE% on the WinPE partition.
          rem 20s: enough to read or photograph the captured flasher output before the machine returns to NixOS.
          ping -n 21 127.0.0.1 >nul
          wpeutil reboot
        ''
    }
    exit /b 1

    :done
  '');
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

              entryPoint = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Executable path relative to the staged payload directory when the package is a directory; empty means the package is a single file.";
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
      # Best-effort purge of unmanaged files in the firmware dir; note D only empties during boot-time tmpfiles runs (verified empirically 2026-09-13), so switch-time freshness of managed files is guaranteed by the winpe-stage-files service instead.
      "${cfg.mountPoint}/firmware".${if cfg.cleanFirmwareDirectory then "D" else "d"} = {
        mode = "0755";
      };
    }
    # The image tree keeps the C+ first-copy semantics: it populates an empty ESP correctly but will not refresh an existing tree (delete the ESP contents to re-stage).
    // (lib.optionalAttrs cfg.populateImage {
      "${cfg.mountPoint}"."C+" = {
        mode = "0755";
        argument = "${cfg.imagePackage}";
      };
    });

    # Why a oneshot service instead of tmpfiles: C+ does not overwrite existing destinations (verified empirically 2026-09-12) and D/e only empty during boot-time invocations (verified empirically 2026-09-13), so switch-time staging used to merge new content into stale ESP state.
    # install and rm -rf + cp -r overwrite unconditionally, so every switch and every boot stages exactly the configured bytes.
    systemd.services.winpe-stage-files = {
      description = "Stage autorun.cmd and firmware payloads onto the WinPE partition";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [ "winpe-auto-boot.service" ];
      path = with pkgs; [ coreutils systemd ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Why this ExecStartPost: winpe-auto-boot is oneshot RemainAfterExit, so at
        # BOOT time it injects the start hook into whatever boot.wim is staged, and
        # only earlier switches see the result. Since the winpe-image deploy fix
        # (868e3ef) every switch replaces boot.wim with pristine bytes AFTER that
        # boot's arm run, stripping the hook again - validated 2026-09-17 16:13
        # (round 12 pre-check: pristine 590MB boot.wim + stock recenv.ini on the
        # partition right after a switch). Restarting winpe-auto-boot here re-runs
        # the arm on the freshly staged file at switch time, keeping the invariant
        # "every switch leaves boot.wim hook-injected" true for the next boot.
        ExecStartPost = "${pkgs.systemd}/bin/systemctl try-restart winpe-auto-boot.service";
      };
      script = ''
        install -D -m 0755 ${cfg.autorunScript} ${cfg.mountPoint}/autorun.cmd
        # Deploy the current boot.wim unconditionally: tmpfiles C+ never overwrites an
        # existing tree, so the booted image would stay frozen at whatever version first
        # populated the partition. A stale boot.wim reproduces the 32-bit SxS failure on
        # real hardware (validated 2026-09-16: a 422MB setup-PE boot.wim survived a full
        # switch that staged the 590MB WinRE-based image; the flasher then died at
        # ERROR_SXS_CANT_GEN_ACTCTX exactly like the old base image dictates).
        # winpe-auto-boot runs after this service and re-injects the startnet hook.
        install -D -m 0755 ${cfg.imagePackage}/sources/boot.wim ${cfg.mountPoint}/sources/boot.wim
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            _: p:
            if p.entryPoint != "" then
              ''
                rm -rf '${cfg.mountPoint}/firmware/${p.targetFileName}'
                cp -r '${p.package}' '${cfg.mountPoint}/firmware/${p.targetFileName}'
              ''
            else
              ''
                install -D -m 0755 '${p.package}' '${cfg.mountPoint}/firmware/${p.targetFileName}'
              ''
          ) activePayloads
        )}
      '';
    };

    systemd.services.winpe-auto-boot = lib.mkIf (cfg.autoBootOnUpdate && activePayloads != { }) {
      description = "Schedule one-time UEFI BootNext into WinPE when new firmware is staged";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-tmpfiles-setup.service"
        "local-fs.target"
      ];
      path = with pkgs; [
        coreutils
        cfg.package
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
          CURRENT_BIOS=""
          SYSFS_DMI="''${SYSFS_DMI_DIR:-/sys/class/dmi/id}"
          if [ -r "$SYSFS_DMI/bios_version" ]; then
            CURRENT_BIOS=$(cat "$SYSFS_DMI/bios_version" | tr -d '[:space:]')
          fi

          NEEDS_UPDATE=0
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: checkPayload) activePayloads)}

          if [ "$NEEDS_UPDATE" -eq 1 ]; then
            echo "Scheduling WinPE boot for staged firmware..."
            # Why winpe-flash arm: guarantees boot.wim is patched with startnet.cmd hook before setting UEFI BootNext.
            ${lib.getExe cfg.package} arm
          else
            echo "All staged firmware payloads match the current BIOS ($CURRENT_BIOS). No update needed."
          fi
        '';
    };
  };
}
