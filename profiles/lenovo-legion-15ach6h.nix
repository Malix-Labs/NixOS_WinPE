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
}
