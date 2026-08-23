{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.winpe.profiles.lenovoLegion;
  biosPackage = pkgs.callPackage ../pkgs/lenovo-legion-bios { };
in
{
  imports = [
    ../nixos
  ];

  options.hardware.winpe.profiles.lenovoLegion = {
    enableUdevRules = lib.mkEnableOption "experimental udev access rules for the ITE 8910 keyboard controller";
  };

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

    services.udev.extraRules = lib.mkIf cfg.enableUdevRules ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="048d", ATTR{idProduct}=="c965", MODE="0666", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="048d", ATTR{idProduct}=="c101", MODE="0666", TAG+="uaccess"
    '';
  };
}
