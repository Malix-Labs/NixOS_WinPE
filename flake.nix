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

            all-profiles-test =
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

            wim-injection-test =
              pkgs.runCommand "test-wim-injection" { nativeBuildInputs = [ pkgs.wimlib ]; }
                ''
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

            disko-module-test =
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

            clean-firmware-directory-test =
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
          };

          pre-commit.settings.hooks = {
            nixfmt.enable = true;
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = config.pre-commit.devShell;
        };
    };
}
