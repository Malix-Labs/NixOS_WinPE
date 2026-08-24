{ lib, ... }:
let
  partition = {
    priority = 2;
    size = "2G";
    type = "EF00";
    content = {
      type = "filesystem";
      format = "vfat";
      mountpoint = "/mnt/WinPE";
      mountOptions = [
        "nofail"
        "fmask=0077"
        "dmask=0077"
      ];
    };
  };
in
{
  disko.devices.disk.main.content.partitions.WinPE = lib.mapAttrsRecursive (
    _: lib.mkDefault
  ) partition;

  hardware.winpe.autoMount = lib.mkDefault false;
}
