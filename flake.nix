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
    inputs@{ flake-parts, ... }:
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
          winpe-flash = pkgs.callPackage ./pkgs/winpe-flash { };
          lenovo-legion-15ach6h-bios = pkgs.callPackage ./pkgs/lenovo-legion-bios { };
        in
        {
          packages = {
            inherit winpe-flash lenovo-legion-15ach6h-bios;
            default = winpe-flash;
          };

          checks = {
            inherit winpe-flash;

            module-test =
              let
                nixosEval = inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.lenovo-legion-15ach6h
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
              nixosEval.config.system.build.etc;
          };

          pre-commit.settings.hooks = {
            nixfmt.enable = true;
          };

          formatter = config.pre-commit.settings.hooks.nixfmt.package;

          devShells.default = config.pre-commit.devShell;
        };
    };
}
