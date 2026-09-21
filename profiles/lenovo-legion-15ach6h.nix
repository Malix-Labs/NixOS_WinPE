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
      # The winpe-flash nonInteractive flow is the one with the explicit HUMAN PAUSE
      # + single ENTER (no typed commands); interactive/config mode drops to cmd.exe
      # which requires typing "wpeutil reboot" - unsafe with unknown keyboard layout
      # (round 14 constraint).
      nonInteractive = lib.mkDefault true;
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
      # RECON COMPLETE (rounds 26/27, 2026-09-21): recon proved on real hardware the
      # real Insyde tool RUNS (empty-body "Error" modal is its precondition-fail
      # dialog for the renamed-away BIOS.fd; body renders empty under WinPE both in
      # QEMU and on hardware), exits RC=0 even on failure (so exit code is not a
      # success marker - asyncio dmidecode bios-version post-check is the ground
      # truth), and a manual single-button dismissal lets it exit cleanly.
      # reconMode stays false for the real flash; re-enable for re-recon any time.
      reconMode = lib.mkDefault false;
    };
  };
}
