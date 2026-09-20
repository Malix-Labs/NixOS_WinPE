{
  lib,
  pkgs,
  ...
}:
let
  winpeImage = pkgs.callPackage ../pkgs/winpe-image { };
  biosPackage = pkgs.callPackage ../pkgs/lenovo-legion-bios {
    # x86 DLLs the Insyde flasher resolves straight from its own directory
    # (grafting them into the boot.wim's SysWOW64 instead breaks the WinPE boot,
    # see RESEARCH-NOTES.md round 21). winpe-image extracts them from the same
    # ESD and exposes them via its wow64SidecarFiles passthru.
    sidecarFiles = lib.listToAttrs (
      map (name: {
        inherit name;
        value = "${winpeImage}/sidecar/${name}";
      }) winpeImage.wow64SidecarFiles
    );
  };
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
        # H2OFFT-W.exe (Insyde flash tool) is the actual BIOS updater shipped in the
        # vendor package for this AMD machine. FWUpdLcl.exe, also present in the SFX,
        # is Intel's MEI-channel updater (banner "Intel (R) Firmware Update Utility"):
        # on real hardware round 11 it ran end-to-end (our SxS fix works on the
        # 15ACH6H) but stopped at "Error 8743: Cannot locate hardware platform
        # identification" - it identifies platforms through Intel ME/MEI, which this
        # AMD machine does not have. H2OFFT-W runs headless purely from the hardened
        # platform.ini ([UI] Silent=1 Confirm=0, [Option] Flag=0 auto-flash, FDFile
        # auto-located from CWD = BIOS.fd), so it is invoked WITHOUT CLI flags.
        entryPoint = "H2OFFT-W.exe";
        silentFlags = [ ];
      };
      # RECON FIRST (round 24, decision 2026-09-20): the flasher launches on real
      # hardware but every *.fd BIOS image is renamed in place first, so it can
      # show the real dialogs / ME-channel text without any chance of flashing;
      # the console then holds on screen for reconPauseMinutes (countdown, no keys
      # needed) so the human can read, scroll, and photograph at leisure. Flip
      # reconMode to false (nixos-rebuild switch) once the recon photos are read.
      reconMode = lib.mkDefault true;
      reconPauseMinutes = lib.mkDefault 10;
    };
  };
}
