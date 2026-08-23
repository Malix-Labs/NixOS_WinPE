{ lib, ... }:
{
  # Standalone Disko partition snippet for WinPE.
  # Can be imported directly into disko.devices.disk.<name>.content.partitions
  disko.devices.disk.main.content.partitions.WinPE = {
    priority = lib.mkDefault 2;
    size = lib.mkDefault "2G";
    type = lib.mkDefault "0700"; # Microsoft Basic Data / FAT32
    content = {
      type = "filesystem";
      format = "vfat";
      mountpoint = lib.mkDefault "/mnt/WinPE";
      mountOptions = [
        "nofail"
        "fmask=0077"
        "dmask=0077"
      ];
    };
  };
}
