# NixOS_WinPE 🚀

**Declarative, bare-metal Windows PE partition and automated firmware updater for NixOS.**

[![Flake Check](https://img.shields.io/badge/Nix_Flake-passing-brightgreen.svg?logo=nixos&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE.md)

---

## 🎯 The Problem

Many modern consumer laptops (e.g. **Lenovo Legion**, **ASUS ROG/TUF**, **Acer Predator**, **MSI**, **HP Omen**) do not publish BIOS, Embedded Controller (EC), or touchpad firmware updates to the Linux Vendor Firmware Service (**LVFS / `fwupd`**). 

Instead, OEMs distribute critical firmware and EC updates exclusively as Windows-only executables (`.exe`) containing proprietary flashing drivers (such as Insyde `H2OFFT64.sys`). When hardware glitches occur—such as the **ITE 8910 Embedded Controller lockup** on Lenovo Legion laptops—Linux users are typically forced to:
1. Waste 50GB+ of storage on a permanent Windows dual-boot, or
2. Find and burn an external USB recovery drive every time an update is released, or
3. Attempt running updates inside a Virtual Machine (**which fails**, because hypervisors cannot access bare-metal SPI flash chips or physical ACPI/SMI registers).

**`NixOS_WinPE`** solves this by maintaining a lightweight (~2 GB), bare-metal, headless **Windows Preinstallation Environment (WinPE)** on your internal NVMe SSD, managed 100% declaratively through NixOS.

---

## 🏗️ Architecture & Workflow

```
[NixOS System] ──── (nh os switch) ────► 1. Fetches firmware payloads (pkgs.fetchurl)
       │                                 2. Deploys autorun.cmd to /mnt/WinPE
       │
       ▼ (Run `winpe-flash reboot` or `sudo efibootmgr -n <ID> && reboot`)
[UEFI Boots WinPE Partition into RAM]
       │
       ▼
[WinPE automatically runs autorun.cmd]
       │
       ├──► Auto-discovers and silently stages firmware payload (.exe)
       │
       ▼
[Motherboard executes hardware flash of BIOS & EC]
       │
       ▼
[Automatically reboots straight back into NixOS]
```

---

## ✨ Features

- **100% Declarative & Pure:** Zero binary blobs hosted in Git. Payloads are fetched on-demand using standard Nix `pkgs.fetchurl` with cryptographic SHA-256 integrity verification.
- **Headless Automation:** Boots into WinPE in RAM, silently stages the firmware in NVRAM, and triggers the hardware flash without requiring a mouse or GUI interaction.
- **Dynamic Auto-Discovery:** Batch runner automatically finds and executes any staged firmware executables without hardcoded paths.
- **Disko Integration:** Provides modular Disko partition configurations for automated disk partitioning.
- **CLI Utility (`winpe-flash`):** Built-in CLI tool to inspect status, check staged firmware, and trigger one-time reboots.

---

## 🚀 Quickstart

### 1. Add Flake Input

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "tarball+https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    nixos-winpe = {
      url = "github:Malix-Labs/NixOS_WinPE";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-winpe, ... }: {
    nixosConfigurations.my-laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-winpe.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

---

### 2. Configure NixOS Module

In your `configuration.nix`:

```nix
{ pkgs, ... }:
{
  hardware.winpe = {
    enable = true;
    mountPoint = "/mnt/WinPE";
    partitionLabel = "WinPE";

    payloads = {
      # Example: Lenovo Legion 5 15ACH6H BIOS & EC update
      "lenovo-bios" = {
        enable = true;
        package = pkgs.fetchurl {
          name = "gkcn65ww.exe";
          url = "https://download.lenovo.com/consumer/mobiles/gkcn65ww.exe";
          hash = "sha256-QXb3lKgR+ILqMSwNjz68cR20xaixvJLccwGJjTIgwaA=";
        };
        silentFlags = [ "/SILENT" "/VERYSILENT" "/SUPPRESSMSGBOXES" ];
      };
    };
  };

  # (Optional) Include the CLI management helper in system packages
  environment.systemPackages = [
    # nixos-winpe.packages.${pkgs.system}.default
  ];
}
```

---

### 3. Disk Partitioning (Disko or Manual)

#### Using Disko:
```nix
# In your disko configuration
disko.devices.disk.main.content.partitions.WinPE = {
  priority = 2;
  size = "2G";
  type = "0700"; # Microsoft Basic Data / FAT32
  content = {
    type = "filesystem";
    format = "vfat";
    mountpoint = "/mnt/WinPE";
    mountOptions = [ "nofail" "fmask=0077" "dmask=0077" ];
  };
};
```

---

### 4. Triggering a Firmware Update

1. Ensure your laptop is **connected to AC power**.
2. Run:
   ```bash
   nix run github:Malix-Labs/NixOS_WinPE#winpe-flash -- reboot
   # or manually:
   nix shell nixpkgs#efibootmgr -c sudo efibootmgr -n <WinPE_Boot_ID> && sudo reboot
   ```
3. The system will boot into WinPE, stage the update, and flash the motherboard.

---

## ⚠️ Security & TPM Considerations

> [!WARNING]
> **TPM / Measured Boot & Secure Boot:**
> Updating motherboard BIOS/EC firmware alters **PCR 0** (Core Firmware Executables). 
> - If you use **Lanzaboote / TPM auto-unlock** on an encrypted LUKS drive, the system will prompt for your **manual LUKS recovery passphrase** on the first boot after the firmware flash before re-sealing to the new BIOS version.
> - **Always verify your manual LUKS recovery passphrase before performing a firmware update.**

> [!IMPORTANT]
> **AC Power:** Never attempt a BIOS/EC flash on battery power.

---

## 📄 License

Licensed under [GPL-3.0](../LICENSE.md).
