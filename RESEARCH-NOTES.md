# NixOS_WinPE — `winpe-qemu` debugging research log

**RESOLVED (v0.5.0): `nix flake check -L` fully green.**
Final root cause of the last blocker: `start /wait` in autorun.cmd — WinPE's
desktop heap cannot allocate the second console window it spawns
("Not enough memory resources are available to process this command.").
Fix: `call %~1 %~3` (same console, waits, propagates errorlevel; wine-safe
when the mock payload uses `exit /b` not bare `exit`).

**Post-v0.5.0 hardening (commit 718dc66):** LZX + CRLF tripwires,
startnet.log persisted to the ESP, and winpe-qemu failure dumps (ESP
listing, logs, injected scripts, base64 screendumps) into the build log.

## Target pipeline (what the check validates)

1. `winpe-image`: extracts WinPE from Microsoft ESD `26100.4349...CLIENTCONSUMER_RET_x64FRE_en-us.esd`
2. ESP layout: GPT, 1 partition `EF00`, FAT32 label `WinPE`, 900M
3. ESP contents: `/boot` (bcd, boot.sdi, fonts, resources), `/EFI/Boot/bootx64.efi`, `/EFI/Microsoft/boot/*` (bcd, fonts, resources, cipolicies), `/sources/boot.wim` (LZX), `/autorun.cmd`, `/firmware/mock-flash.cmd`
4. WIM patches: `winpeshl.ini` (launches `cmd /s /k startnet.cmd`) + `startnet.cmd` (breadcrumb logging, diskpart assigns W:, calls `W:\autorun.cmd`)
5. Guest: boots WinPE → startnet → autorun.cmd (module-generated) → `start /wait "" W:\firmware\mock-flash.cmd /SILENT /VERYSILENT /SUPPRESSMSGBOXES` → mock echoes success → `if errorlevel 1 (...) else (log success + ping + wpeutil reboot)` → QEMU `-no-reboot` exits → host asserts `autorun.log` contains "Flash staging completed successfully"

## SOLVED root causes (each masked the next)

| #   | Symptom                                                                                              | Root cause                                                                                                                                        | Fix                                                          |
| --- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1   | Flat blue screen, hang, zero text                                                                    | Only 3 files extracted from ESD Image 1; bootmgr needs `fonts/*.ttf` + `resources/bootres.dll` + MUI to render anything                           | `winpe-image` extracts full `/boot` + `/efi/microsoft` trees |
| 2   | Recovery screen `winload.efi 0xc00000bb`                                                             | ESD Image 2 is LZMS-compressed; bootmgr ramdisk loader can't read LZMS WIMs                                                                       | export with `--compress=LZX` (538MB)                         |
| 3   | Pre-graphics bootmgr hang                                                                            | 1G disk → mkfs.vfat picks FAT32 geometry bootmgr chokes on                                                                                        | 900M disks work; keep `imageSize = "900M"`                   |
| 4   | Batch abort after payload echo, "Not enough memory resources are available to process this command." | `timeout /t` spawn unreliable in WinPE sessions                                                                                                   | `ping -n N 127.0.0.1 >nul` sleep idiom                       |
| 5   | wine check regression                                                                                | wine cmd rejects QUOTED `call` targets ("Invalid name") and quoted `start` targets                                                                | use `%~1` (unquoted) everywhere; ESP paths have no spaces    |
| 6   | wim-injection check regression                                                                       | startnet had literal `\\` double backslashes                                                                                                      | single backslashes throughout                                |
| 7   | static assertion in autorun check                                                                    | asserts `start /wait ""` present (anti-detach); don't replace with `call`                                                                         | keep `start /wait "" %~1 %~3`                                |
| 8   | Guest script dies at `if errorlevel 1 (` block                                                       | **LF-only batch files**: real Windows cmd aborts at parenthesized blocks; Wine is lenient (why wine check passed while VM failed)                 | `toCRLF` conversion for `autorun.cmd` + `startnet.cmd`       |
| 9   | Broken nixpkgs qemu in check                                                                         | locked flake nixpkgs (2026-08-22) qemu builds fail the payload spawn; floating nixpkgs qemu_kvm `f0l6wcpd9mfx0chsn27d45fyz8fwd3px` (11.1.0) works | `nix flake update nixpkgs` (now dc5d91f84032, qemu f0l6wc)   |

## CURRENT BLOCKER (the last 10%) — REVISED UNDERSTANDING

**KEY REALIZATION (user-prompted): stop trial-and-error on script content — DIFF THE TWO DISK IMAGES.**

I have both images: `.debug/disk-swap.img` (SUCCESS) and `.debug/disk-repro.img` (FAIL, built with
identical store paths & full env). Extract every file from both ESPs, byte-compare (cmp/md5):
autorun.cmd, sources/boot.wim (538MB — if WIMs differ, the two wimlib builds produce different
bytes → different X: ramdisk → spawn failure), ini, startnet, boot files.

Also noted: c14's success used an **LF** autorun (extracted from disk-swap), out5's failure used
**CRLF** replica on checkcmd-disk → confounded; the image diff resolves all confounds at once.

Failure signature (screendump-confirmed): payload child echoes, then
`Not enough memory resources are available to process this command.`, child window stays at prompt,
parent (startnet /k) frozen at `start /wait` — before writing the success line to W:\autorun.log.

**Works manually, fails identically-in-sandbox AND in `env -i` shell AND with full env.**

Guest console screenshot at failure: payload echo line, then
`Not enough memory resources are available to process this command.`, then `X:\Windows\System32>` prompt. Log stops at "[WinPE] Executing flasher: ..." — i.e. death immediately after `start /wait` returns, before `if errorlevel 1` writes anything.

Key contradiction to resolve:

- Manual runs (my shell, full env, direct qemu on pre-built disk, **replica autorun script**): SUCCESS ×6 (186s, complete log, reboot)
- Builder runs (nix daemon, sandbox or `--option sandbox false`): FAIL 0/3
- `env -i` + builder PATH + **exact builder script** (module autorun, current store paths): FAIL (reproduced manually! → **NOT nix-special**)
- full env + builder PATH + **exact builder script**: FAIL (out4) → **NOT env vars either!**
- ⇒ the variable is **the DISK CONTENT built by the check script** (module autorun + single-glob mcopy build) vs my manual disk (replica autorun + per-dir mcopy). The QEMU process env is exonerated by out4.

### Eliminated causes (do NOT re-test)

- KVM flakiness theory (red herring; mixed with qemu-build + host-memory issues)
- OVMF version 202605 vs 202608 (both work manually; A/B tested)
- QEMU package full vs qemu_kvm (037j0x failed once manually but f0l6wc failed in builder → not the binary)
- -smp 4 vs 1, -m 3072 vs 4096 (both work manually)
- winpeshl.ini present/absent (present = required; absent = boot never reaches startnet)
- winpeshl.ini escaping (`\\` double vs `\` single — both work; single is current)
- CRLF vs LF scripts (CRLF required; #8)
- `/s /k` vs `/c` in winpeshl.ini (`/s /k` current, works)
- disk 700M/900M/1G (900M correct)
- GPT/EF00 vs MBR (both boot manually; GPT is the target)
- q35 vs i440fx, pflash vs -bios OVMF (q35+pflash is what works)
- `-cpu host` vs `max` (both work manually)

### Repro artifacts on disk

- `.debug/` — disks (disk-swap.img=GOOD, disk-check6.img=current-scripts), extracts, roots/ (GC-root symlinks)
- `.debug/buildtest/checkcmd.sh` — extracted exact builder buildCommand
- Failed check outputs keep `/nix/store/*-winpe-qemu-check/diag/` (screendumps ppm, autorun_result.log, root.txt, builder-env.txt)
- Screendump technique: `-monitor tcp:HOST:PORT` or `unix:mon.sock` + `screendump file.ppm` via nc/socat; convert with `ppmtojpeg` (nixpkgs#netpbm); view via read_file
- Nixpkgs hivex binaries have broken `#!/bin/bash` shebang — patch with sed to real bash path

## Candidate explanations for the last blocker

1. **Module autorun.cmd content** (vs my working replica): semantically near-identical, CRLF, but module has extra lines (failure-branch error box, comments, un-nested `wpeutil reboot` in no-payload branch). cmd parses whole `( )` blocks upfront — one bad construct anywhere in the block aborts the block. **NEXT TEST: build check disk but with replica autorun → boot.** If passes: binary-search module script lines.
2. **Disk build order**: check uses single `mcopy -s $IMG/* ::/` glob (copies original 538MB LZMS boot.wim THEN overwrites with updated 538MB) vs manual per-dir copies. FAT allocation order differs. Possible FAT/long-filename weirdness.
3. Guest desktop heap exhausted by second console window (start /wait child) — but replica with start /wait works manually, so only if combined with #1/#2.

## Fix candidates if module script is guilty

- Reduce module autorun to replica shape (move failure-branch box out of the block / replace `%%` lines)
- Or: keep module text but `call` the payload with `%~1` (my very first manual success used call; wine assertion needs update)

## Check design (current)

- TCG (-smp 1), q35, pflash OVMF_CODE+VARS(copy), -m 3072, 900M disk, 3 attempts × 900s, mtype+grep assert, debug diag dump on failure (remove once green)
- QEMU from new-lock nixpkgs (f0l6wc)

## Environment gotchas encountered (operational)

- /tmp wiped between tool calls — use `.debug/` in project
- nix store GC eats paths mid-debugging — root with `nix build <drv>^out -o roots/name`
- hivex/netpbm/ppmtojpeg need nix shell/store-path usage
- `nix eval --raw` for store paths; `nix derivation show` for buildCommand extraction
- The `.debug/` workspace must stay out of git (add to .gitignore before commits!)
