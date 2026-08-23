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
        package = biosPackage.src;
        targetFileName = biosPackage.src.name;
        silentFlags = [
          "/SILENT"
          "/VERYSILENT"
          "/SUPPRESSMSGBOXES"
        ];
      };
    };
  };
}
