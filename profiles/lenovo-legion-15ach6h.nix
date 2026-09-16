{
  lib,
  pkgs,
  ...
}:
let
  biosPackage = pkgs.callPackage ../pkgs/lenovo-legion-bios { };
in
{
  imports = [
    ../nixos
  ];

  config = {
    hardware.winpe = {
      enable = lib.mkDefault true;
      payloads."lenovo-bios" = {
        enable = lib.mkDefault true;
        package = biosPackage;
        targetFileName = "GKCN65WW";
        entryPoint = "FWUpdLcl.exe";
        # FWUpdLcl CLI flags: -F selects the flash image, -Y auto-accepts the prompts.
        # QEMU-validated: with these flags FWUpdLcl runs end-to-end and fails cleanly with
        # "Unknown or Unsupported Platform" where no matching hardware exists (RESEARCH-NOTES.md §0.6).
        silentFlags = [
          "-F"
          "BIOS.fd"
          "-Y"
        ];
      };
    };
  };
}
