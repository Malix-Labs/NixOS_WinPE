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
          pkgs,
          system,
          ...
        }:
        let
          inherit (nixpkgs) lib;
          inherit (self) nixosModules diskoModules;
          winpe-flash = pkgs.callPackage ./pkgs/winpe-flash { };
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
        in
        {
          packages = {
            inherit winpe-flash lenovo-legion-15ach6h-bios;
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

            wim-injection = pkgs.runCommand "test-wim-injection" { nativeBuildInputs = [ pkgs.wimlib ]; } ''
              mkdir -p root/Windows/System32
              echo "wpeinit" > root/Windows/System32/startnet.cmd
              wimcapture root test.wim

              wimupdate test.wim 1 --command="add ${pkgs.writeScript "startnet.cmd" ''
                @echo off
                wpeinit
                for %%d in (c d e f g h i j k l m n o p q r s t u v w x y z) do (
                    if exist %%d:\autorun.cmd (
                        call %%d:\autorun.cmd
                        goto :done
                    )
                )
                cmd.exe
                :done
              ''} /Windows/System32/startnet.cmd"

              mkdir -p extracted
              wimextract test.wim 1 /Windows/System32/startnet.cmd --dest-dir=extracted

              grep -Fq "wpeinit" extracted/startnet.cmd
              grep -Fq "for %%d in" extracted/startnet.cmd
              grep -Fq "call %%d:\autorun.cmd" extracted/startnet.cmd

              touch $out
            '';

            disko-module =
              let
                eval = evalNixos [
                  nixosModules.default
                  diskoModules.default
                  (
                    { lib, ... }:
                    {
                      options.disko.devices.disk.main.content.partitions.WinPE = lib.mkOption {
                        type = lib.types.attrs;
                        default = { };
                      };
                    }
                  )
                ];
              in
              assert eval.config.hardware.winpe.autoMount == false;
              assert
                eval.config.disko.devices.disk.main.content.partitions.WinPE.content.mountpoint.content
                == "/mnt/WinPE";
              pkgs.runCommand "test-disko-module" { } "touch $out";

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
                evalInteractive = evalNixos [
                  nixosModules.default
                  {
                    hardware.winpe.enable = true;
                    hardware.winpe.nonInteractive = false;
                  }
                ];
                evalNonInteractive = evalNixos [
                  nixosModules.default
                  {
                    hardware.winpe.enable = true;
                    hardware.winpe.nonInteractive = true;
                  }
                ];
                autorunInteractive = evalInteractive.config.hardware.winpe.autorunScript;
                autorunNonInteractive = evalNonInteractive.config.hardware.winpe.autorunScript;
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
                  # Static Assertion: Ensure start /wait is present to prevent detached GUI execution
                  grep -Fq 'start /wait ""' ${autorunInteractive}
                  grep -Fq 'start /wait ""' ${autorunNonInteractive}

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
                  printf '@exit 0\r\n' > "$WINEPREFIX/drive_c/winpe/firmware/mock.bat"

                  wine cmd.exe /c "C:\winpe\autorun.cmd"
                  grep -q "Flash staging completed successfully" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  # Test Case 2: Interactive mode - Mock executable fails (exit code 3) -> drops to cmd.exe
                  printf '@exit 3\r\n' > "$WINEPREFIX/drive_c/winpe/firmware/mock.bat"

                  wine cmd.exe /c "C:\winpe\autorun.cmd"
                  grep -q "Flasher process failed" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  # Test Case 3: Non-Interactive mode - Mock executable fails (exit code 3) -> reboots immediately
                  install_mock_autorun ${autorunNonInteractive}

                  wine cmd.exe /c "C:\winpe\autorun.cmd"
                  grep -q "Non-interactive mode active: rebooting" "$WINEPREFIX/drive_c/winpe/autorun.log"

                  # Test Case 4: Real Windows GUI PE Binary (PE32/PE32+ GUI Subsystem)
                  install_mock_autorun ${autorunInteractive}

                  rm -f "$WINEPREFIX/drive_c/winpe/firmware/mock.bat"
                  printf '@echo off\r\necho Mock GUI executed\r\nexit /b 0\r\n' > "$WINEPREFIX/drive_c/winpe/firmware/gui_payload.cmd"
                  wine cmd.exe /c "C:\winpe\autorun.cmd"
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
                  bash -e "${autoBootScript}"

                  touch $out
                '';

            uefi-boot-test = pkgs.testers.runNixOSTest {
              name = "winpe-uefi-boot-test";
              nodes.machine =
                { ... }:
                {
                  imports = [
                    nixosModules.default
                  ];
                  hardware.winpe = {
                    enable = true;
                    nonInteractive = true;
                    autoMount = false;
                    payloads.testPayload = {
                      package = pkgs.writeText "GKCN65WW.exe" "payload-content";
                      targetFileName = "GKCN65WW.exe";
                    };
                  };
                };
              testScript = ''
                start_all()
                machine.wait_for_unit("multi-user.target")
                machine.succeed("winpe-flash help")
                machine.succeed("winpe-flash status")
                machine.succeed("winpe-flash logs")
              '';
            };
          };

          pre-commit.settings.hooks = {
            nixfmt.enable = true;
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = config.pre-commit.devShell;
        };
    };
}
