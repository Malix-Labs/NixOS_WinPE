# NixOS_WinPE — `winpe-qemu` debugging research log (COMPACT-SAFE MASTER STATE)

> **READ THIS FIRST.** This file is the single source of truth for the debugging
> session. It is written to survive context compaction. Every store path,
> command recipe, finding, and next step is here. Update it as you go.

## 0. MISSION & CURRENT STATE (2026-09-10 evening)

- Repo: `/home/malix/Repositories/Malix-Labs/NixOS_WinPE` (branch main)
- **v0.6.0 tagged & pushed** at commit `731d42c` (full `nix flake check -L` green
  on that tree: all 18 checks ✅).
- dotfiles (`/home/malix/Repositories/Malix-Labs/dotfiles`, branch main, commit
  `8153738`) locked to nixos-winpe `731d42c` (v0.6.0), pushed.
- User said: **no new tag without their explicit green light.** New commits go on
  main, untagged; tag comes later.
- **REAL HARDWARE TEST FAILED** (user's Lenovo Legion 5 15ACH6H, screenshot seen):
  v0.6.0's startnet.cmd (hardcoded `select disk 0` / `select partition 1` /
  `assign letter=W`) never mounted the ESP on the real laptop → fallback letter
  scan found nothing → "[!] ERROR: WinPE partition with autorun.cmd not found" →
  stuck at `cmd.exe` prompt (guest escapes with `wpeutil reboot`).
- **Fix written (UNCOMMITTED in working tree):** startnet.cmd now does
  `san policy=onlineall` + `list volume` + label-based lookup of the volume
  named "WinPE" → `select volume %VOLNUM%` + `assign letter=W`. No hardcoded
  disk/partition numbers (multi-disk + partition-reorder safe).
  Also: `list volume` table echoed to console AND startnet.log for post-mortem.
- **QEMU CHECK STATUS WITH THE FIX: FAILED 3/3** (`/tmp/v06fix2.log`, drv
  `/nix/store/acjmmx1hrccsr1fs3kapk819imv69d4g-winpe-qemu-check.drv`). The
  label-lookup script does NOT mount W: in QEMU either. **7 screendumps were
  captured in that build** ("screendump count: 7") and are embedded in
  `/tmp/v06fix2.log` as base64 PPM blocks — **NOT YET VIEWED. That is the
  immediate next step** (they show the guest console incl. the diskpart
  `list volume` table, because startnet echoes it).

## 0.5 ROOT CAUSE FOUND (2026-09-12): ESD WinPE has NO findstr.exe — FIX APPLIED

**The label-lookup failure was never about diskpart output parsing or the SAN
policy — the ESD-extracted WinPE image ships without findstr.exe.** The old
script's `for /f ('findstr /i "WinPE" X:\dp.out')` died with `'findstr' is not
recognized as an internal or external command` → VOLNUM never set → assign
skipped → no drive letter → scan found nothing → interactive cmd.exe → 900s
check timeout.

**Evidence (ground truth, 8 manual-boot screendumps):** `.debug/manual/s1.jpg`
… `s8.jpg` (+ original .ppm), captured via QEMU TCP monitor (`-monitor
tcp:127.0.0.1:4499,server,nowait`; `printf "screendump sN.ppm\n" | timeout 3 nc
127.0.0.1 4499`; convert `nix shell nixpkgs#netpbm -c ppmtojpeg`). s2.jpg is the
money shot (findstr error + `[3] WinPE volume = ` empty). s5–s8 identical:
static `cmd.exe` prompt = the hang. `dp.out`'s table was never captured (flashed
by between dumps) — irrelevant: the fix uses no text tools at all.

**Corollary: assume find.exe is absent too. Guest scripts must use NO external
text tools — pure batch only.**

**Fix (uncommitted, in this tree):**

- `pkgs/winpe-flash/default.nix` startnetScript: dp.out parsed with
  `setlocal enabledelayedexpansion` + `for /f "delims="` + case-insensitive
  substring test (`if /i not "!LN:WinPE=!" == "!LN!"`) + `tokens=2` (the
  `Volume N` number; works with/without a Ltr column); `endlocal & set
"VOLNUM=%VOLNUM%"` idiom to export past endlocal. Retry loop unchanged.
  Hardcoded `select disk 0 / partition 1 / assign letter=W` KEPT as last resort
  before the letter scan — required by the `uefi-boot` check's `assert "select
disk 0"`, and harmless on hardware (letter assignment touches no data;
  `W:\autorun.cmd` gates everything). Error path: `ping -n 21` (20s readable)
  - `wpeutil reboot` — fail fast, no interactive cmd.exe (BootNext one-shot →
    back to NixOS).
- `flake.nix` wim-injection check: added `enabledelayedexpansion` grep +
  tripwire: startnet.cmd must NOT contain "findstr" (case-insensitive!). Note
  the batch text itself cannot even mention the word — the comment says
  "lacks some standard text tools" instead.
- Wine smoke test of the parser attempted + ABANDONED same day:
  `nix shell nixpkgs#wine` first-run prefix init hangs the terminal (RpcSs
  marshal errors, never returns). Wine is lenient anyway; winpe-qemu is the
  only real validator.

**Hardware round 2 (2026-09-12 afternoon):** user's two WinPE boots reached startnet; ESP got `startnet.log` (942B, Sep 12 14:06) but NO `autorun.log`; BIOS still GKCN64WW. The earlier "no startnet.log" was a false negative (fmask=0077 → permission denied swallowed by `2>/dev/null`). ESP listing (sudo): autorun.cmd (2589B) + firmware/GKCN65WW.exe staged correctly; boot.wim = 384,180,603B (~366MB) = an OLDER LZX "Microsoft Windows PE (amd64)" image (NOT the current 538MB winpe-image output) — ships diskpart/cmd/wpeutil/find.exe, no findstr — with the pre-850da04 pure-batch startnet injected. QEMU replica of the Legion layout (512M ESP + 1G raw + 512M swap + 2G WinPE at p4; SAME boot.wim copy + autorun bytes + payload; .debug/hwreplica) PASSES end-to-end (startnet.log 1023B: [3] WinPE volume = 2 → assign → [5] found autorun.cmd on W: → autorun ran → payload failed-in-VM as expected) → the hardware failure is hardware-specific, NOT layout/script-reproducible in QEMU.

**Decisive next artifact: `sudo cat /mnt/WinPE/startnet.log`** (942B — smaller than the replica's 1023B, so its story differs).

**Also new (850da04):** diagnostic startnet dumps breadcrumbs + dp.out to disk0/part1 as winpe-debug.log / winpe-dpout.log on every boot; winpe-auto-boot self-re-arms BootNext on every NixOS boot (observed 14:07 re-arm).

**Remaining: full `nix flake check -L` (repo-wide comment reformat pending validation) → commit main (NO tag without user approval) → push → dotfiles `nix flake update nixos-winpe` → hardware round 3 with diagnostics.**

Real-hardware expectation: `san policy=onlineall` brings the NVMe online,
`list volume` shows the FAT32 `WinPE` partition (disko EF00), label match →
`select volume N` → `assign letter=W` → autorun. Breadcrumbs [1]..[5] +
`startnet.log` on W: tell the story if not.

## 1. HOW TO EXTRACT THE EVIDENCE (exact recipe)

`/tmp/v06fix2.log` = full `nix build -L` log of the failing check (STILL EXISTS,
39KB+… verify: it should contain many MB if base64 blocks are in it — earlier
`wc -c /tmp/q3log.txt` = 39KB was a DIFFERENT log (nix log of an older drv).
`grep -c SCREENDUMP /tmp/v06fix2.log` tells the truth).

Extraction recipe (worked before; previous attempts failed due to buggy
one-liners, not missing data):

```
grep -n "=== SCREENDUMP" /tmp/v06fix2.log          # list markers
# pick two marker line numbers L and N (next marker)
sed -n "$((L+1)),$((N-1))p" /tmp/v06fix2.log > b64.txt
base64 -d b64.txt > pic.ppm
nix shell nixpkgs#netpbm -c ppmtojpeg pic.ppm > pic.jpg   # then read_file pic.jpg
```

Marker names look like `=== SCREENDUMP dbg-a1-t20.ppm (base64 ppm) ===`.
Earlier attempts at extraction failed with "invalid input" because the sed
range accidentally included the trailing `ERROR:` line — filter it or pick
markers strictly.

Also available: `nix log /nix/store/acjmmx1hrccsr1fs3kapk819imv69d4g-winpe-qemu-check.drv`
(same content, but NOTE: `nix log` on an older drv returned a truncated/older
log once — prefer /tmp/v06fix2.log or re-run `nix build -L --keep-failed`).

`--keep-failed` keeps the whole build dir at
`/nix/var/nix/builds/nix-<id>/build` (contains disk.img, autorun.cmd,
autorun_result.log, VARS.fd, work/, env-vars; verified to work).

## 2. THE REAL-HARDWARE FAILURE (v0.6.0 on the Legion)

Screenshot evidence (user-provided): verbose startnet ran; [3] diskpart
attempts happened; fallback scan ran through ALL letters (C..Z, saw V/Y/Z);
"[!] ERROR: WinPE partition with autorun.cmd not found"; dropped to `cmd.exe`.
⇒ `select disk 0` + `select partition 1` + `assign letter=W` did not mount the
ESP on real hardware. QEMU never caught this because there disk 0/part 1 IS the
ESP (single-partition disk).

Why the ESP might not mount on real hardware (hypotheses, untested):

- Multi-disk laptop → disk 0 ≠ the WinPE disk.
- Partition 1 on the Legion GPT ≠ the ESP (Lenovo ships extra partitions; our
  disko module puts WinPE at priority 2).
- WinPE SAN policy leaving disks offline (WinPE default SAN = OfflineShared on
  some media) → volumes never get letters.
  The new startnet (san policy=onlineall + label lookup) addresses all three.

## 3. THE LABEL-LOOKUP SCRIPT (current, uncommitted)

Location: `pkgs/winpe-flash/default.nix` → `startnetScript` (CRLF-converted).
Flow:

1. `san policy=onlineall` + `rescan` + `list volume` via diskpart → output to
   `X:\dp.out`; **also echoed to console and startnet.log** (post-mortem gold).
2. Retry loop (5×): `findstr /i "WinPE" X:\dp.out` → `for /f "tokens=2" %%v`
   → VOLNUM = volume number → `select volume %VOLNUM%` + `assign letter=W`.
3. `if exist W:\autorun.cmd goto :found` → copy breadcrumbs → call autorun.
4. Fallback: scan letters C..Z (skip W,X) for autorun.cmd; copy breadcrumbs.
5. Last resort: cmd.exe (human recovers with wpeutil reboot).

Known QEMU result with this script: **FAILS 3/3** (see /tmp/v06fix2.log).
Working hypothesis: the label lookup itself or something in the new flow fails
in the guest; the 7 embedded screendumps in /tmp/v06fix2.log will show
`--- list volume ---` output from the guest = ground truth of what diskpart
sees. VIEW THEM FIRST.

## 4. PROVEN-GOOD BASELINE (what previously worked end-to-end in QEMU)

- Disk: 900M GPT, single EF00 partition, FAT32 labeled WinPE, built with
  per-dir mcopy; WIM = LZX export of ESD image 2 + winpeshl.ini (single
  backslash form) + LF startnet (6f5wy-era content, double backslashes).
- autorun.cmd = the hand-written replica (CRLF): header, for-loop payload
  discovery, `call %~1 %~3` (or %1), small `if errorlevel 1 ( ... ) else (
... )`, ping sleeps, wpeutil reboot. **This exact script is preserved in
  git history: the file `extract2/swap-autorun.cmd` content — reconstructible
  from the diff in the session log; also `.debug` corpus was DELETED (GC+rm),
  so re-create if needed.**
- QEMU: q35, TCG (-smp 1, -cpu max, -m 3072), pflash OVMF_CODE+VARS from
  nixpkgs#OVMF.fd (f0l6wc qemu build), boot ~180-230s to payload success.
- Success signature: guest reboots → QEMU exits → `mtype` ESP shows
  autorun.log with "Flash staging completed successfully".

## 5. SOLVED ROOT CAUSES (v0.5.0/v0.6.0 era) — do not re-litigate

1. Bare BCD/blue hang → extract full /boot + /efi/microsoft trees (fonts,
   bootres.dll, MUI).
2. winload 0xc00000bb → boot.wim must be LZX (ESD LZMS rejected by ramdisk
   loader).
3. 1G-disk bootmgr hang → keep 900M (FAT32 geometry).
4. `timeout /t` → use `ping -n N 127.0.0.1 >nul`.
5. wine rejects quoted call/start targets → `%~1` unquoted (no-space paths).
6. startnet literal `\\` → single backslashes.
7. wine static assertion → `call %~1 %~3` (update greps together!).
8. **LF batches abort at parenthesized blocks in real cmd** (Wine lenient) →
   CRLF via `toCRLF`.
9. Old-lock qemu build fails payload spawn → flake.lock bumped to
   dc5d91f84032 (qemu f0l6wcpd9mfx0chsn27d45fyz8fwd3px works).
10. `start /wait` → second console window → WinPE desktop heap cannot
    allocate → "Not enough memory resources are available to process this
    command." → use `call %~1 %~3` (same console, waits, propagates rc).
    NOTE: `exit` (no /b) in a called batch kills cmd.exe — wine mock payloads
    must use `exit /b`.

## 6. CHECK DESIGN (current flake.nix)

- `autorunScripts.<interactive|nonInteractive>` hoisted at perSystem `let`
  level (feeds autorun + wim-injection checks).
- `wim-injection` greps: wpeinit, san policy=onlineall, list volume, assign
  letter=W, diskpart /s, for %%d in, call %%d:\autorun.cmd + CRLF tripwire on
  startnet + both autorun variants.
- `autorun` (wine): 4 cases; mock.bat uses `exit /b N` (NOT bare exit);
  `wine cmd.exe /c ... || true` on failure-path tests (non-zero rc intended);
  greps assert on the log.
- `winpe-qemu`: TCG (-smp 1, -cpu max, -m 3072), q35, pflash OVMF
  (nixpkgs#OVMF.fd), 900M disk, glob-mcopy build, watchdog screendumps via
  unix mon.sock + socat every 20s, retry 3×900s, label-lookup startnet,
  failure → dump_diag() into the build log (ESP listing, autorun.log,
  startnet.log, injected scripts) + base64 last screendumps + exit 1.
- CURRENT known status: **FAILS 3/3 with the label-lookup script** — see §3.

## 7. OPERATIONAL GOTCHAS (all bitten, all real)

- `/tmp` is a 6.8G tmpfs — nix-prefetch temp dirs filled it (disk full during
  prefetch). Clean `/tmp/nix-*`. Use `.debug/` in the project for artifacts.
- Root fs had 91% used at one point — `df -h /` and `/tmp` before long runs.
- nix store GC deletes inputs mid-session — root with
  `nix build <drv>^out -o roots/<name>` (GC root symlinks). `.debug/roots/`.
- Store paths change between flake states — always re-derive via
  `nix eval --raw .#...` / `nix build --print-out-paths`, never trust old
  paths in notes for >1 hour.
- hivex binaries from nixpkgs have broken `#!/bin/bash` shebang — copy +
  sed to `$(which bash)`.
- netpbm (ppmtojpeg) via `nix build nixpkgs#netpbm`.
- Screendumps: `-monitor tcp:127.0.0.1:PORT,server,nowait` + `nc` (works), or
  unix mon.sock + socat (works interactively; inside builder it produced NO
  files once — unexplained, see §8).
- `nix log <drv>` can return stale/older logs for re-used drv names — prefer
  the `nix build -L` captured log file.
- **Nix indented strings: `${` is interpolation — escape as `''${`** (bit me
  with `${1:-}` in the updateScript).
- **`grep … | head -n1` under pipefail SIGPIPEs when input has >1 match**
  (exit 141) — use `grep -m1` or `tail -n1`. Bit the updateScript AND
  winpe-flash arm.
- Bash in builder = stdenv bash; `$'\r'` ANSI-C quoting works in buildCommand.
- git commit messages: backticks get EXECUTED by the shell in -m strings —
  avoid or use single-quoted heredoc.

## 8. OPEN QUESTIONS / SUSPECTED (unverified)

- RESOLVED 2026-09-12: label lookup failed in QEMU because the ESD WinPE has no
  findstr.exe (§0.5). Not a diskpart/SAN-policy/parsing problem.
- Whether `san policy=onlineall` alone would have fixed the real-hardware
  mount (vs the label lookup being the necessary part). Both are in now.
- Builder-embedded screendumps (base64 in `-L` log) are unreliable: markers
  appeared but blocks were missing/truncated (see §1 recipe; count said 7, kept
  dir had 0). Manual boot + TCP monitor is the proven path. Root cause of the
  truncation still unexplained; not load-bearing.
- The interactive-mode UX regression: flash-failure path always reboots (no
  cmd.exe drop); interactive success uses silent ping not visible timeout.
  User said backwards compat doesn't matter; interactive recovery niceness
  could be restored later with small-in-block cmd.exe.

## 9. NEXT STEPS (in order)

1. DONE 2026-09-12: viewed 8 manual screendumps → root cause = missing
   findstr.exe (§0.5); pure-batch parser fix + tripwires applied to
   default.nix + flake.nix (uncommitted).
2. DONE 2026-09-12: `winpe-qemu` GREEN. Discriminating evidence (success-path
   breadcrumb dump added to the check): guest startnet.log shows
   `Volume 1  WinPE  FAT32 ... Healthy  Hidden` + `[3] WinPE volume = 1` →
   the LABEL parser fired (no Ltr column; tokens=2 handles the shift), NOT the
   hardcoded fallback. ESP shows a "Hidden" info column — normal, ignored.
3. DONE 2026-09-12: full `nix flake check -L` green (wim-injection findstr
   tripwire + uefi-boot `select disk 0` assert included).
4. Committed on main (this commit, untagged). Awaiting user go-ahead for:
   push, dotfiles `nix flake update nixos-winpe` + commit/push, tag decision,
   real-hardware retry (expected guest flow in §0.5).

## 10. KEY STORE PATHS (volatile — re-derive if GC'd)

- qemu (working, new lock): /nix/store/f0l6wcpd9mfx0chsn27d45fyz8fwd3px-qemu-host-cpu-only-11.1.0
- OVMF: nixpkgs#OVMF.fd → FV/OVMF_CODE.fd + FV/OVMF_VARS.fd (+ OVMF.fd)
- mtools: /nix/store/b1ndywa8j68pfgwsag2bq93f6136f1pw-mtools-4.0.49
- wimlib: /nix/store/fmgrizq5lmvs39805xx7sdvpl8flrhkg-wimlib-1.14.5 (old lock)
  — new lock wimlib may differ; derive via nix build.
- gptfdisk: /nix/store/7x10akngwdym2ii6zmdl3anbl3ia7ins-gptfdisk-1.0.10
- dosfstools: /nix/store/ifnpj2j6pffqjrh9d6s7fn96add9cp29-dosfstools-4.2
- ESD (pinned): /nix/store/vf1mfb8n7g9c33rnr98zr2dd8h0n5wqy-26100.4349...esd
- netpbm (ppmtojpeg), hivex (patch shebang), socat — via nix build.
