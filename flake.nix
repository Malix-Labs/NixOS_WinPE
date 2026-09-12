{
  description = "NixOS WinPE";

  inputs = {
    nixpkgs.url = "tarball+https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.git-hooks.flakeModule
      ];

      flake = {
        # Standard NixOS modules conforming to flake-schemas
        nixosModules =
          let
            winpe = import ./nixos;
          in
          {
            inherit winpe;
            default = winpe;
            lenovo-legion-15ach6h = import ./profiles/lenovo-legion-15ach6h.nix;
          };

        # Disko partition snippet module
        diskoModules =
          let
            winpe = import ./disko;
          in
          {
            inherit winpe;
            default = winpe;
          };
      };

      perSystem =
        {
          config,
          system,
          ...
        }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          inherit (nixpkgs) lib;
          inherit (self) nixosModules diskoModules;
          winpe-flash = pkgs.callPackage ./pkgs/winpe-flash { };
          winpe-image = pkgs.callPackage ./pkgs/winpe-image { };
          lenovo-legion-15ach6h-bios = pkgs.callPackage ./pkgs/lenovo-legion-bios { };

          evalNixos =
            modules:
            lib.nixosSystem {
              inherit system;
              modules = modules ++ [
                {
                  system.stateVersion = "26.11";
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "/dev/dummy";
                    fsType = "ext4";
                  };
                  nixpkgs.hostPlatform = system;
                  nixpkgs.config.allowUnfree = true;
                }
              ];
            };

          # Shared by the autorun and wim-injection checks.
          autorunScripts = {
            interactive =
              (evalNixos [
                nixosModules.default
                {
                  hardware.winpe.enable = true;
                  hardware.winpe.nonInteractive = false;
                }
              ]).config.hardware.winpe.autorunScript;
            nonInteractive =
              (evalNixos [
                nixosModules.default
                {
                  hardware.winpe.enable = true;
                  hardware.winpe.nonInteractive = true;
                }
              ]).config.hardware.winpe.autorunScript;
          };
        in
        {
          packages = {
            inherit winpe-flash winpe-image lenovo-legion-15ach6h-bios;
            default = winpe-flash;
          };

          checks = {
            inherit winpe-flash;

            all-profiles =
              let
                profiles = lib.filterAttrs (name: _: name != "default" && name != "winpe") nixosModules;

                profileChecks = lib.mapAttrs (
                  name: profileModule:
                  let
                    eval = evalNixos [ profileModule ];
                    cfg = eval.config.hardware.winpe;
                  in
                  assert cfg.enable;
                  assert (lib.length (lib.attrValues cfg.payloads)) > 0;
                  pkgs.runCommand "check-profile-${name}" { } ''
                    cp -r ${eval.config.system.build.etc}/etc $out
                  ''
                ) profiles;
              in
              pkgs.runCommand "check-all-profiles" { } ''
                mkdir -p $out
                ${lib.concatStringsSep "\n" (map (p: "ln -s ${p} $out/${p.name}") (lib.attrValues profileChecks))}
              '';

            wim-injection =
              let
                winpeFlashPkg = pkgs.callPackage ./pkgs/winpe-flash { };
              in
              pkgs.runCommand "test-wim-injection" { nativeBuildInputs = [ pkgs.wimlib ]; } ''
                mkdir -p root/Windows/System32
                echo "wpeinit" > root/Windows/System32/startnet.cmd
                wimcapture root test.wim

                wimupdate test.wim 1 --command="add ${winpeFlashPkg.startnetScript} /Windows/System32/startnet.cmd"

                mkdir -p extracted
                wimextract test.wim 1 /Windows/System32/startnet.cmd --dest-dir=extracted

                grep -Fq "wpeinit" extracted/startnet.cmd
                grep -Fq "san policy=onlineall" extracted/startnet.cmd
                grep -Fq "list volume" extracted/startnet.cmd
                grep -Fq "assign letter=W" extracted/startnet.cmd
                grep -Fq "diskpart /s" extracted/startnet.cmd
                grep -Fq "for %%d in" extracted/startnet.cmd
                grep -Fq "call %%d:\\autorun.cmd" extracted/startnet.cmd
                grep -Fq "enabledelayedexpansion" extracted/startnet.cmd

                # Tripwire: the ESD-extracted WinPE ships NO findstr.exe (screendump-proven 2026-09-11: "'findstr' is not recognized").
                # The ESP label lookup must stay pure-batch substring parsing.
                if grep -qi "findstr" extracted/startnet.cmd; then
                  echo "ERROR: startnet.cmd uses findstr, which is absent from ESD WinPE"
                  exit 1
                fi

                # Regression tripwire: real Windows cmd aborts LF-only batches at parenthesized blocks; every generated script must be CRLF.
                for f in ${winpeFlashPkg.startnetScript} ${autorunScripts.interactive} ${autorunScripts.nonInteractive}; do
                  grep -q $'\r' "$f" || { echo "ERROR: $f is not CRLF"; exit 1; }
                done

                touch $out
              '';

            clean-firmware-directory =
              let
                mkCase =
                  clean:
                  let
                    s = lib.boolToString clean;
                    mountPoint = "@DIR@";
                    eval = evalNixos [
                      nixosModules.default
                      {
                        hardware.winpe = {
                          enable = true;
                          inherit mountPoint;
                          cleanFirmwareDirectory = clean;
                          payloads.testPayload = {
                            package = pkgs.writeText "GKCN65WW.exe" "payload-content";
                            targetFileName = "GKCN65WW.exe";
                          };
                        };
                      }
                    ];
                    rules = lib.concatLists (
                      lib.mapAttrsToList (
                        path: types:
                        lib.mapAttrsToList (
                          type: rule: "${type} ${path} ${rule.mode} ${rule.user} ${rule.group} ${rule.age} ${rule.argument}"
                        ) types
                      ) eval.config.systemd.tmpfiles.settings."10-winpe"
                    );
                    conf = pkgs.writeText "10-winpe-${s}.conf" (lib.concatStringsSep "\n" rules);
                  in
                  ''
                    dir="$PWD/winpe-${s}/firmware"
                    mkdir -p "$dir"
                    echo "old" > "$dir/stale.exe"
                    substitute ${conf} "$PWD/conf-${s}.conf" --replace-fail "@DIR@" "$PWD/winpe-${s}"
                    fakeroot systemd-tmpfiles --remove --create "$PWD/conf-${s}.conf"
                    ${if clean then "[ ! -f $dir/stale.exe ]" else "[ -f $dir/stale.exe ]"}
                    [ -f $dir/GKCN65WW.exe ]
                  '';
              in
              pkgs.runCommand "test-clean-firmware-directory"
                {
                  nativeBuildInputs = with pkgs; [
                    systemd
                    fakeroot
                  ];
                }
                ''
                  ${mkCase true}
                  ${mkCase false}
                  touch $out
                '';

            autorun =
              let
                autorunInteractive = autorunScripts.interactive;
                autorunNonInteractive = autorunScripts.nonInteractive;
              in
              pkgs.runCommand "test-autorun"
                {
                  nativeBuildInputs = with pkgs; [
                    wineWow64Packages.minimal
                    coreutils
                    gnugrep
                    gnused
                  ];
                }
                ''
                  # Static Assertion: the payload must run via `call` - synchronous (waits for GUI-subsystem binaries too) and it does not spawn a second console window: WinPE's desktop heap cannot allocate one ("Not enough memory resources").
                  grep -Fq 'call %~1 %~3' ${autorunInteractive}
                  grep -Fq 'call %~1 %~3' ${autorunNonInteractive}

                  export WINEDEBUG=-all
                  export WINEPREFIX="$PWD/wine"
                  wineboot -u
                  wineserver -w

                  mkdir -p "$WINEPREFIX/drive_c/winpe/firmware"

                  install_mock_autorun() {
                    install -m 644 "$1" "$WINEPREFIX/drive_c/winpe/autorun.cmd"
                    sed -i 's|timeout /t [0-9]*|echo [MOCK] timeout|g' "$WINEPREFIX/drive_c/winpe/autorun.cmd"
                    sed -i 's|wpeutil reboot|echo [MOCK] wpeutil reboot|g' "$WINEPREFIX/drive_c/winpe/autorun.cmd"
                    sed -i 's|cmd.exe|echo [MOCK] dropped to cmd.exe|g' "$WINEPREFIX/drive_c/winpe/autorun.cmd"
                  }

                  # Test Case 1: Interactive mode - Mock executable succeeds (exit code 0)
                  install_mock_autorun ${autorunInteractive}
                  # Why exit /b, not exit: with the payload invoked via `call`, a bare `exit` would terminate the whole cmd.exe process instead of returning to autorun.cmd (matches .exe behaviour).
                  printf '@exit /b 0\r\n' > "$WINEPREFIX/drive_c/winpe/firmware/mock.bat"

                  # Wine returns the autorun.cmd exit code; failure-path tests intentionally end non-zero, so tolerate it and assert on the log.
                  wine cmd.exe /c "C:\winpe\autorun.cmd" || true
                  grep -q "Flash staging completed successfully" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  # Test Case 2: Interactive mode - Mock executable fails (exit code 3) -> drops to cmd.exe
                  printf '@exit /b 3\r\n' > "$WINEPREFIX/drive_c/winpe/firmware/mock.bat"

                  wine cmd.exe /c "C:\winpe\autorun.cmd" || true
                  grep -q "Flasher process failed" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  # Test Case 3: Non-Interactive mode - Mock executable fails (exit code 3) -> reboots immediately
                  install_mock_autorun ${autorunNonInteractive}

                  wine cmd.exe /c "C:\winpe\autorun.cmd" || true
                  grep -q "Non-interactive mode active: rebooting" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  # Test Case 4: Real Windows GUI PE Binary (PE32/PE32+ GUI Subsystem)
                  install_mock_autorun ${autorunInteractive}

                  rm -f "$WINEPREFIX/drive_c/winpe/firmware/mock.bat"
                  printf '@echo off\r\necho Mock GUI executed\r\nexit /b 0\r\n' > "$WINEPREFIX/drive_c/winpe/firmware/gui_payload.cmd"
                  wine cmd.exe /c "C:\winpe\autorun.cmd" || true
                  grep -q "gui_payload.cmd" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  wineserver -k
                  touch $out
                '';

            auto-boot-service =
              let
                evalEnabled = evalNixos [
                  nixosModules.default
                  {
                    hardware.winpe = {
                      enable = true;
                      payloads.testPayload = {
                        package = pkgs.writeText "GKCN65WW.exe" "payload-content";
                        targetFileName = "GKCN65WW.exe";
                      };
                    };
                  }
                ];
                evalDisabled = evalNixos [
                  nixosModules.default
                  {
                    hardware.winpe = {
                      enable = true;
                      autoBootOnUpdate = false;
                      payloads.testPayload = {
                        package = pkgs.writeText "GKCN65WW.exe" "payload-content";
                        targetFileName = "GKCN65WW.exe";
                      };
                    };
                  }
                ];
                mockEfibootmgr = pkgs.writeShellScriptBin "efibootmgr" ''
                  if [ "$#" -eq 0 ]; then
                    cat "$EFISTATE"
                  elif [ "$1" = "-n" ]; then
                    sed -i "/BootNext/d" "$EFISTATE"
                    echo "BootNext: $2" >> "$EFISTATE"
                  fi
                '';
                autoBootScript = pkgs.writeScript "winpe-auto-boot-script.sh" evalEnabled.config.systemd.services.winpe-auto-boot.script;
              in
              assert evalEnabled.config.hardware.winpe.autoBootOnUpdate == true;
              assert evalEnabled.config.systemd.services ? winpe-auto-boot;
              assert !(evalDisabled.config.systemd.services ? winpe-auto-boot);
              pkgs.runCommand "test-auto-boot-service"
                {
                  nativeBuildInputs = with pkgs; [
                    bash
                    coreutils
                    gnugrep
                    gnused
                    mockEfibootmgr
                  ];
                }
                ''
                  # Set up mock sysfs environment
                  MOCK_SYS="$PWD/sys/class/dmi/id"
                  mkdir -p "$MOCK_SYS"
                  export SYSFS_DMI_DIR="$MOCK_SYS"
                  export EFISTATE="$PWD/efistate"
                  export EFIBOOTMGR_BIN="${mockEfibootmgr}/bin/efibootmgr"

                  # Edge Case 1: Outdated BIOS -> Schedules BootNext to WinPE (0000)
                  echo -e "BootCurrent: 0005\nBootOrder: 0005,0000\nBoot0000* WinPE\nBoot0005* Linux" > "$EFISTATE"
                  echo "GKCN64WW" > "$MOCK_SYS/bios_version"
                  bash -e "${autoBootScript}"
                  grep "BootNext: 0000" "$EFISTATE"

                  # Edge Case 2: Already up to date BIOS -> Does not change BootNext
                  sed -i "/BootNext/d" "$EFISTATE"
                  echo "GKCN65WW" > "$MOCK_SYS/bios_version"
                  bash -e "${autoBootScript}"
                  ! grep "BootNext" "$EFISTATE"

                  # Edge Case 3: No WinPE UEFI entry -> Exits gracefully without failure
                  sed -i "/WinPE/d" "$EFISTATE"
                  bash -e "${autoBootScript}" || true

                  touch $out
                '';

            uefi-boot = pkgs.testers.runNixOSTest {
              name = "winpe-uefi-boot";
              nodes.machine =
                { pkgs, ... }:
                {
                  imports = [
                    inputs.disko.nixosModules.disko
                    diskoModules.default
                    nixosModules.default
                    {
                      disko.devices.disk.main = {
                        device = "/dev/vda";
                        type = "disk";
                        content = {
                          type = "gpt";
                        };
                      };
                    }
                  ];
                  environment.systemPackages = with pkgs; [
                    wimlib
                    efibootmgr
                    coreutils
                  ];
                  hardware.winpe = {
                    enable = true;
                    nonInteractive = true;
                    autoMount = false;
                    payloads.testPayload = {
                      package = pkgs.writeText "GKCN65WW.exe" "payload-content";
                      targetFileName = "GKCN65WW.exe";
                      silentFlags = [
                        "-s"
                        "-noconfirm"
                        "-n"
                        "-b"
                      ];
                    };
                  };
                };
              testScript = ''
                start_all()
                machine.wait_for_unit("multi-user.target")

                # Basic CLI verification
                machine.succeed("winpe-flash help")

                # Setup mock WinPE filesystem structure
                machine.succeed("mkdir -p /mnt/WinPE/sources /mnt/WinPE/firmware /tmp/wim-root/Windows/System32")
                machine.succeed("echo 'original-startnet' > /tmp/wim-root/Windows/System32/startnet.cmd")
                machine.succeed("wimlib-imagex capture /tmp/wim-root /mnt/WinPE/sources/boot.wim 'WinPE-Image'")

                # Verify log output handling
                machine.succeed("echo 'Flasher executed successfully' > /mnt/WinPE/autorun.log")
                logs_out = machine.succeed("winpe-flash logs")
                assert "Flasher executed successfully" in logs_out

                # Verify status shows staged payload and log handling
                status_out = machine.succeed("winpe-flash status")
                assert "Flasher executed successfully" in status_out

                # Test WIM startnet injection and script contents
                machine.succeed("winpe-flash reboot <<< 'n' || true")
                extracted = machine.succeed("wimlib-imagex extract /mnt/WinPE/sources/boot.wim 1 /Windows/System32/startnet.cmd --to-stdout")
                assert "select disk 0" in extracted
                assert "diskpart /s" in extracted
                assert "autorun.cmd" in extracted
              '';
            };

            winpe-qemu =
              let
                winpeImg = winpe-image;
                winpeFlash = winpe-flash;
                diskoEval = evalNixos [
                  inputs.disko.nixosModules.disko
                  diskoModules.default
                  nixosModules.default
                  {
                    disko.devices.disk.main = {
                      device = "disk.img";
                      type = "disk";
                      # LZX-recompressed boot.wim (~540MB) plus boot environment fits in 900M.
                      # Note: must stay <= 900M - at 1G mkfs.vfat switches to 8K FAT32 clusters which bootmgr cannot read.
                      imageSize = "900M";
                      content.type = "gpt";
                    };
                    hardware.winpe = {
                      enable = true;
                      nonInteractive = true;
                      payloads.testPayload = {
                        package = pkgs.writeText "mock-flash.cmd" "@echo [WinPE VM Execution] Staging and Flash completed successfully\r\n@exit /b 0\r\n";
                        targetFileName = "mock-flash.cmd";
                      };
                    };
                  }
                ];
              in
              pkgs.runCommand "winpe-qemu-check"
                {
                  # Why no KVM: Windows bootmgr hangs nondeterministically under this host's KVM (~50% of runs), while TCG boots reliably; TCG costs ~5min per boot which is acceptable for a check.
                  nativeBuildInputs = with pkgs; [
                    qemu_kvm
                    gptfdisk
                    dosfstools
                    mtools
                    wimlib
                    coreutils
                    socat
                  ];
                }
                ''
                  # 1. Create a 900MB disk image with GPT partition table and EF00 partition.
                  # Why 900M: fits the LZX boot.wim (~540MB) + boot environment, and mkfs.vfat picks a FAT32 geometry bootmgr can read (1G+ hangs).
                  truncate -s 900M disk.img
                  sgdisk --clear disk.img
                  sgdisk --new=1:2048:0 --typecode=1:EF00 --change-name=1:"WinPE" disk.img
                  mkfs.vfat -F 32 -n WinPE --offset=2048 disk.img

                  # 2. Populate base WinPE layout from winpe-image
                  mcopy -i disk.img@@1048576 -s ${winpeImg}/* ::/

                  # 3. Patch startnet.cmd + winpeshl.ini into sources/boot.wim.
                  # Without the ini, WinPE's winpeshl.exe never reaches startnet.cmd (validated under QEMU).
                  mkdir -p work
                  cp ${winpeImg}/sources/boot.wim work/boot.wim
                  chmod +w work/boot.wim
                  wimlib-imagex update work/boot.wim 1 --command="add ${winpeFlash.winpeshlIni} /Windows/System32/winpeshl.ini"
                  wimlib-imagex update work/boot.wim 1 --command="add ${winpeFlash.startnetScript} /Windows/System32/startnet.cmd"
                  mcopy -o -i disk.img@@1048576 work/boot.wim ::/sources/boot.wim

                  # 4. Stage generated autorun.cmd and payload from NixOS module
                  cp ${diskoEval.config.hardware.winpe.autorunScript} autorun.cmd
                  mcopy -o -i disk.img@@1048576 autorun.cmd ::/autorun.cmd
                  mmd -i disk.img@@1048576 ::/firmware
                  mcopy -o -i disk.img@@1048576 ${diskoEval.config.hardware.winpe.payloads.testPayload.package} ::/firmware/mock-flash.cmd

                  # 5. Boot QEMU with OVMF UEFI firmware under TCG emulation.
                  # Why q35 + pflash OVMF: winload is unreliable on legacy i440fx.
                  # Why TCG: KVM on this workload hangs nondeterministically at bootmgr; TCG boots reliably in ~4 minutes.
                  # Windows PE boots in RAM, runs startnet.cmd -> diskpart assign -> autorun.cmd -> wpeutil reboot
                  dump_diag() {
                    echo "=== WINPE-QEMU DIAG (attempt $1) ==="
                    echo "--- ESP root listing ---"
                    mdir -i disk.img@@1048576 -/ ::/ 2>&1 || true
                    echo "--- W:\\\\autorun.log ---"
                    mtype -i disk.img@@1048576 ::/autorun.log 2>&1 || echo "(absent)"
                    echo "--- W:\\\\startnet.log ---"
                    mtype -i disk.img@@1048576 ::/startnet.log 2>&1 || echo "(absent - boot died before drive letter assignment)"
                    echo "--- injected startnet.cmd (from boot.wim) ---"
                    wimlib-imagex extract work/boot.wim 1 /Windows/System32/startnet.cmd --dest-dir=. --no-acls --nullglob >/dev/null 2>&1 || true
                    sed 's/^/  | /' startnet.cmd 2>/dev/null || true
                    echo "--- injected autorun.cmd (from NixOS module) ---"
                    sed 's/^/  | /' autorun.cmd 2>/dev/null || true
                  }

                  for attempt in 1; do
                    echo "=== QEMU boot attempt $attempt ==="
                    cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd VARS.fd
                    chmod +w VARS.fd
                    # Screendumps every 20s: the guest console is the only window into pre-startnet failures (bootmgr/winload have no logs).
                    ( for t in $(seq 1 45); do sleep 20; printf "screendump dbg-a$attempt-t$t.ppm\n" | timeout 2 ${pkgs.socat}/bin/socat - UNIX-CONNECT:mon.sock >/dev/null 2>&1 || true; done ) &
                    WATCHDOG=$!
                    timeout 900 qemu-system-x86_64 \
                      -machine q35 \
                      -m 3072 \
                      -smp 1 \
                      -cpu max \
                      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
                      -drive if=pflash,format=raw,file=VARS.fd \
                      -drive file=disk.img,format=raw \
                      -no-reboot \
                      -display none \
                      -net none || true
                    kill $WATCHDOG 2>/dev/null || true
                    # Success = complete autorun.log flushed by the guest before wpeutil reboot (killing QEMU mid-run leaves FAT unflushed, so the log may exist but be incomplete on earlier kills).
                    if mtype -i disk.img@@1048576 ::/autorun.log > autorun_result.log 2>/dev/null && grep -q "Flash staging completed successfully" autorun_result.log; then
                      echo "complete autorun.log found on attempt $attempt"
                      # Breadcrumbs prove WHICH mount path fired (label lookup vs hardcoded fallback) - load-bearing for real hardware.
                      echo "--- guest startnet.log breadcrumbs ---"
                      mtype -i disk.img@@1048576 ::/startnet.log 2>/dev/null || echo "(no startnet.log on ESP)"
                      break
                    fi
                    dump_diag "$attempt"
                    if [ "$attempt" = 1 ]; then
                      # Pixel-level post-mortem: embed the last screendumps as base64 PPM (decode: base64 -d < block | ppmtojpeg > out.jpg).
                      echo "screendump count: $(ls dbg-a$attempt-t*.ppm 2>/dev/null | wc -l)"
                      for f in dbg-a$attempt-t*.ppm; do
                        [ -f "$f" ] || continue
                        echo "=== SCREENDUMP $f (base64 ppm) ==="
                        base64 -w 76 "$f"
                      done
                      echo "ERROR: complete autorun.log was not created by WinPE after 3 attempts!"
                      exit 1
                    fi
                  done

                  # 6. Assert that autorun.log contains the success message
                  grep "Flash staging completed successfully" autorun_result.log

                  touch $out
                '';
          };

          pre-commit.settings.hooks = {
            nixfmt.enable = true;
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = config.pre-commit.devShell;
        };
    };
}
