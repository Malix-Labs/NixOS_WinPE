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

**ROOT CAUSE #2 CONFIRMED (2026-09-12 evening, from that log):** the hardware startnet.log shows the ENTIRE mount chain SUCCEEDING (san policy ✓, volume table: p1 512M ESP + p4 WinPE, [3] WinPE volume = 1 → "DiskPart successfully assigned" → [5] found autorun.cmd on W:) — the break was the ESP's autorun.cmd ITSELF: 787B STALE v0.5-era script (module's current = 2589B) because tmpfiles C+ does NOT overwrite existing destinations (verified with fakeroot systemd-tmpfiles: C+ over an existing file is a no-op). startnet called the ancient script, which predates autorun.log entirely → no log, quick reboot, no flash. Fix: autorun.cmd is now staged by a new unconditional oneshot service `winpe-stage-autorun` (`install -D -m 0755`, overwrites every boot) instead of the C+ entry; flake check `stage-autorun-service` asserts the service + that tmpfiles no longer references autorun.cmd. FOLLOW-UP (same bug class): populateImage's C+ directory copy also cannot refresh an existing ESP base tree — the Legion's ESP runs an old 366MB boot.wim for the same reason; refresh via re-staging or fixing populateImage later. Payload freshness is NOT affected: the D rule empties firmware/ before C+ recreates it.

**Also new (850da04):** diagnostic startnet dumps breadcrumbs + dp.out to disk0/part1 as winpe-debug.log / winpe-dpout.log on every boot; winpe-auto-boot self-re-arms BootNext on every NixOS boot (observed 14:07 re-arm).

**FOLLOW-UP: payload root cause found + fixed (2026-09-12 evening).** With staging fixed, hardware round 3 got further: autorun.log now exists ("Executing flasher: W:\firmware\GKCN65WW.exe -s -noconfirm -n -b" → "Flasher process failed") — the new diagnostic startnet also wrote winpe-debug.log/winpe-dpout.log to disk0/part1 ✓. The payload itself is a 7z-SFX-wrapped InsydeFlash toolchain (H2OFFT-W.exe + platform.ini + BIOS.fd + H2OFFT64.sys drivers); run via the SFX it fails deterministically in ANY environment (QEMU replica AND hardware). Fix: bios package now ships the EXTRACTED toolchain (7z x) with platform.ini hardened for headless WinPE ([UI] Silent=1 Confirm=0; [AC_Adapter] Flag=0 + [Platform_Check] Flag=0 — the battery/model probes are unreliable or unsatisfiable under WinPE, placeholder names AA/BB; [Log_file] Flag=1 → H2OFFT.log on the ESP; RETURN_SUCCESSFUL=0,3010 → 0,0 so silent success returns 0); module gained a payload `entryPoint` option (directory payloads staged into firmware/<targetFileName>/ and autorun calls firmware/<dir>/<entryPoint>); autorun now cd's into the payload dir (InsydeFlash resolves platform.ini/BIOS.fd from CWD), captures flasher console output into firmware/payload.out + autorun.log, and snapshots the exit code into FLASH_RC before branching. Two bugs caught by the wine autorun check during development: (1) X:\payload.out redirect — X: does not exist under wine (and would not under wine either way), use the payload dir; (2) the type calls after the redirected call reset errorlevel before the branch — snapshot into FLASH_RC first. Wine quirk note: the check's payload-less autorun (for-loop fallback path) loses errorlevel across redirected calls inside a for-called subroutine — production autoruns use the activePayloads branch, so the check evals now define a testPayload to exercise the production path.

**Round 4 (2026-09-13): the output capture paid off immediately** — the console showed H2OFFT-W failing to START with "The application has failed to start because its side-by-side configuration is incorrect" (classic VC90 SxS). Root cause: the SFX's flat layout (Microsoft.VC90.CRT.manifest + msvcr90.dll etc. loose next to the exe) relies on the shared WinSxS store, which normal Windows has but WinPE does not. Fix (ae26a92): private-assembly layout — Microsoft.VC90.CRT/ (manifest + msvcr90.dll + msvcp90.dll) and Microsoft.VC90.MFC/ (manifest + mfc90u.dll) subdirectories next to H2OFFT-W.exe; installCheck asserts the layout. Wine cannot reproduce this (its SxS is lenient / provides builtin VC90), so validation is hardware round 5. Possible next hurdles after SxS: H2OFFT64.sys driver load under WinPE (WDF), then the actual flash (~2 min). All evidence self-collects: autorun.log + payload.out + H2OFFT.log on the ESP.

**Round 5 (2026-09-13): SxS persisted WITH the private-assembly layout.** Root cause: the vendor assembly manifests declare files the SFX never ships — CRT lists msvcm90.dll (we have only msvcr90+msvcp90), MFC lists mfc90.dll/mfcm90.dll/mfcm90u.dll (we have only mfc90u) — and binding an INCOMPLETE private assembly fails with the same generic SxS error. The embedded manifest of H2OFFT-W.exe (extracted with icoutils wrestool --raw --type=24) requests exactly Microsoft.VC90.CRT/MFC 9.0.21022.8, so identities matched and the file lists were the defect; on normal Windows the shared WinSxS store masks all of this. Fix (917259e): trim each assembly manifest to the shipped file set via sed on the <file /> elements. installCheck asserts the trimmed lists. Wine cannot reproduce SxS failures (lenient + builtin VC90) — hardware rounds are the only validator for this class.

**Round 5 prep (2026-09-13): switch-time staging was ALSO stale — tmpfiles purge semantics nailed down empirically.** The user's post-switch ESP listing was a MERGE (new VC90 subdirs + old flat msvcr90.dll/mfc90u.dll/manifests still at top level). Root cause: tmpfiles `C+` merges into existing directories (never deletes), and `D`/`e` DO NOT EMPTY under plain `--create` (what `nh os switch` runs) — they only purge under `--remove`/`--boot` (verified with fakeroot tests; note: a hand-written D line with an extra argument field is silently ignored — the nix-generated line omits the argument). Historical check green is explained: the clean-firmware check runs `--remove --create` where D does purge. Fix (fb862e9-lineage): the winpe-stage-files oneshot service (renamed from winpe-stage-autorun) now stages autorun.cmd (install) AND payloads — directories via `rm -rf` + `cp -r`, files via `install` — unconditionally on every switch and boot, so ESP state always matches the configuration byte-for-byte; tmpfiles keeps only the best-effort D purge (boot-time) for unmanaged strays. Check renamed to stage-files-service (asserts service lines + that tmpfiles no longer stages payloads); clean-firmware-directory check now models reality: tmpfiles purge (boot semantics) + service staging. populateImage C+ keeps first-copy semantics (documented in module: delete ESP contents to re-stage).

**Remaining: full `nix flake check -L` (repo-wide comment reformat pending validation) → commit main (NO tag without user approval) → push → dotfiles `nix flake update nixos-winpe` → hardware round 3 with diagnostics.**

Real-hardware expectation: `san policy=onlineall` brings the NVMe online,
`list volume` shows the FAT32 `WinPE` partition (disko EF00), label match →
`select volume N` → `assign letter=W` → autorun. Breadcrumbs [1]..[5] +
`startnet.log` on W: tell the story if not.

**Round 6-7 (2026-09-13, continued): THE REAL ROOT CAUSE OF THE SXS CLASS — Win11 WoW64 processes require the x86 `Microsoft.Windows.SystemCompatible` assembly, and the ESD WinPE does not ship it.**

- **The SxS error reproduces deterministically in the QEMU replica** (4-partition Legion-like disk, hardware's own boot.wim + payload): same ERROR_SXS_CANT_GEN_ACTCTX as on the Legion. This ends the reboot-driven debugging for this bug class — iteration now happens locally in minutes.
- The round-4 BSOD was a transient (the re-run of the identical disk booted cleanly through startnet to the SxS error).
- **Manifest-content theories are dead.** Three configurations fail IDENTICALLY: (a) vendor manifest with VC90 deps, (b) private assemblies with trimmed manifests, (c) dependency-free manifest with assemblyIdentity, (d) and finally a 32-bit binary with NO manifest resource at all (all RT_MANIFEST directory entries zeroed via pefile) — still SxS. When even a no-manifest 32-bit binary fails, the failure is in the DEFAULT activation context that the loader creates for every 32-bit process.
- **THE DEFAULT CONTEXT for Win11 WoW64 (32-bit) processes references the `Microsoft.Windows.SystemCompatible` assembly.** The guest WinPE's WinSxS contains the amd64 SystemCompatible manifest (microsoft.windows.systemcompatible 6.0.26100.1, token 6595b64144ccf1df) but ZERO x86 copies (verified: 2 amd64 entries, 0 x86). Its WinSxS x86/wow64 population is servicing-stack/boot-environment leftovers only. Hence: every 32-bit process (with or without its own manifest) dies at default-context creation.
- The vendor binaries' own manifests were surveyed (wrestool per binary): H2OFFT-W.exe = VC90.CRT+MFC deps (the reason rounds 4-5 failed even if WoW64 worked); BiosImageProc.dll = Common-Controls 6 (system assembly, needs x86 in WinSxS); mfc90u.dll = OPTIONAL MFCLOC (harmless); FWUpdLcl.exe/WDFInst.exe = NO VC90 deps (trustInfo only). **FWUpdLcl.exe is the official Insyde CLI flasher, imports only system DLLs (SETUPAPI/KERNEL32/ADVAPI32 — verified via objdump), and is the correct SxS-free payload entry point** (it sits unused in the vendor SFX).
- **THE FIX (official files only): graft the x86 `Microsoft.Windows.SystemCompatible` (+ x86 IsolationAutomation if required by it) from the full OS image inside the same ESD (Image 3/4) into the WinPE WIM's WinSxS/Manifests — Microsoft's own files, official store location, zero vendor-binary modification.** The winpe-flash arm already injects files into boot.wim via wimupdate; the graft uses the same mechanism. The payload entry point is FWUpdLcl.exe (profile entryPoint), with platform.ini hardening retained. The patch-manifest.py binary-patch layer was REVERTED (dead end).
- **OPERATIONAL ISSUE discovered en route: the pinned ESD store path held a TRUNCATED download** (3.09GB partial — wiminfo fails "unexpectedly reached end of file"). It blocks all winpe-image builds. Re-downloading in the background (nix build .#packages.x86_64-linux.winpe-image.src). NOTE for the future: interrupted fetchurl downloads leave unregistered partial outputs at the output path; detect with wiminfo before using.
- QEMU replica harness recipe (validated): 4-partition disk (512M ESP + 1G raw + 512M swap + 2G WinPE FAT32 label WinPE), stage = result-winpe Boot/EFI + hardware's own boot.wim copy + current autorun + payload dir, boot = OVMF 202608 pflash + TCG -cpu max + TCP monitor + 15s screendumps, collect = mtype autorun.log/payload.out/H2OFFT.log from the ESP. Iteration cost: ~3-8 min per run, no user involvement.

## 0.6 HANDOFF STATE (2026-09-16 ~22:15, HARDWARE ROUND 9 FAILED → STALE-boot.wim DEPLOY BUG FIXED, AWAITING RETRY) — READ FIRST

**User decision (binding): minimal unofficial modification, official binaries/tools only; update scripts must not break (or fail with named errors) and everything must be checkable. All work committed+pushed. Latest: NixOS_WinPE main = 868e3ef; dotfiles = 28059b4 (nixos-winpe → 868e3ef). `nix flake check -L` = GREEN at 868e3ef. NO tag yet.**

**STATE: the user ran `nh os switch` (2026-09-16 21:28) and rebooted → HARDWARE ROUND 9 FAILED: FWUpdLcl died at ERROR_SXS_CANT_GEN_ACTCTX, payload.out never created (CreateProcess failure). ROOT CAUSE (log-forensics-confirmed): the partition's boot.wim was NEVER refreshed — `winpe-stage-files` only stages autorun.cmd+payloads; the boot.wim went through tmpfiles `C+`, whose documented semantics are "will not refresh an existing tree". So the 422MB setup-PE image (a06c89e-era, SxS-broken by design, zero wow64 files, no sxs-winners.cmd) survived the switch that staged the 590MB WinRE-based image; `winpe-flash arm` then verified the hook against the stale file, startnet's `[2b]` `if exist %SYSTEMROOT%\sxs-winners.cmd` guard silently skipped, and the flasher died exactly like the old base dictates. The QEMU checks could not catch it because they stage fresh disks every run. FIX (868e3ef): `winpe-stage-files` now installs `${imagePackage}/sources/boot.wim` unconditionally on every switch (overwrite semantics), then winpe-auto-boot re-injects the startnet hook. stage-files check asserts the deploy line; flake check green.**

**DIAGNOSTIC EVIDENCE FROM ROUND 9 (all consistent with the stale-image story):** partition boot.wim = 422,896,411 bytes LZX (stale setup-PE), wimdir greps = 0 wow64.dll / 0 sxs-winners.cmd / 0 SysWOW64/kernel32.dll; startnet.log has NO [2b] lines (the `if exist` guard skipped); autorun.log = "Found firmware package: GKCN65WW / Executing flasher: W:\firmware\GKCN65WW\FWUpdLcl.exe -F BIOS.fd -Y" then the SxS message then "[WinPE] Flasher process failed."; the ESP volume = disk0p1 (512MB FAT32, no letter), WinPE = 2047MB = W:. The user must re-run `nh os switch` (the bumped dotfiles) → verify `sudo ls -la /mnt/WinPE/sources/boot.wim` shows ~590,070,835 bytes → reboot → expect `cat /sys/class/dmi/id/bios_version` = GKCN65WW. If it fails again: `sudo winpe-flash logs` + `/mnt/WinPE/startnet.log` (grep for \[2b\]) + payload.out.

**ROOT CAUSE + SOLUTION (validated 2026-09-15 evening, 30+ QEMU runs r16-r36): the ESD setup-PE (image 2) cannot run ANY 32-bit app — Microsoft dropped WOW64 packaging from WinPE after Win10 2004, and the wow64 runtime only exists in full-OS images at a DIFFERENT build (26100.4202) than the PE's kernel (26100.1), so grafting it there crashes the session (0xC000021A). SOLUTION: boot.wim base = the ESD's own WinRE.wim (image 4; version-consistent 4202 PE with winpeshl/wpeinit/diskpart) + verbatim grafts from the same ESD image: the WOW64 subsystem (System32\wow64*.dll ×5), 10 core 32-bit DLLs (advapi32/gdi32/kernel32/msvcrt/ole32/rpcrt4/sechost/user32/wldp + cmd.exe canary), the x86 6595 SxS family (SystemCompatible/IsolationAutomation/ProxyStub/Common-Controls/GdiPlus manifests + payloads, ALL versions), and a build-time-generated sxs-winners.cmd with `reg add` lines for the SxS Winners registry index (mined from image 4's SOFTWARE hive via hivexregedit; the binder resolves system assemblies through this registry index, NOT the directory scan — that was the invisible-graft mystery). KEY negative results: offline hive rewrite via hivex breaks the boot (use runtime reg add); reg.exe import of hivexregedit's `[\...]`-style .reg silently no-ops ("completed successfully" but keys land nowhere) — hence generated reg-add batch; 32-bit exes with EMBEDDED manifests (cmd.exe/reg.exe, identity-only) fail actctx with 14001 even in the working environment, while manifest-LESS 32-bit exes run — the bios package's RT_MANIFEST stripping (a06c89e) is exactly right.**

**VALIDATION CHAIN (all green): replica ladder on boot-b3/b4/b5: T32 probes RC=42; FWUpdLcl.exe -F BIOS.fd -Y prints banner + usage + "Error 8743: Unknown or Unsupported Platform" (expected under QEMU — no Intel ME; the real Legion passes this check); the flake's winpe-qemu check boots the BUILT image with the REAL lenovo-legion-bios payload and asserts FWUpdLcl's banner + the flashfail branch completes. `nix flake check -L` exit 0 (2026-09-15 ~23:50).**

**THE PRODUCTION CHANGES (uncommitted):** `pkgs/winpe-image/default.nix` = boot.wim now built from image-4's Winre.wim (discovered by scanning images for /Windows/System32/Recovery/Winre.wim — version-agnostic), LZX-exported, then one atomic wimupdate applies: wow64 trio+2, the 10 SysWOW64 core files (7z-extracted because some SxS names contain a literal ".." that wimlib globs cannot address), all x86 6595 manifests+payloads, and /Windows/sxs-winners.cmd (generated per-ESD from the hive via hivexregedit→awk→reg-add batch; CRLF-converted). updateScript validates the new ESD has a Winre.wim-bearing image before touching default.nix; installCheck extract-asserts every required graft file plus sxs-winners.cmd content. `pkgs/winpe-flash` startnet = +[2b] `call %SYSTEMROOT%\sxs-winners.cmd` (runtime registry, additive). `profiles/lenovo-legion-15ach6h.nix` = silentFlags = ["-F" "BIOS.fd" "-Y"] (QEMU-validated flag set). flake.nix winpe-qemu check = RAM 4096 (WinRE WIM is ~595MB), timeout 1200, stages the real bios payload, asserts the banner; imageSize stays 900M (WinRE WIM ~595MB + boot env fits).

**REMAINING STEPS (in order):**
1. Commit + push main (user approval per contract; files: the 5 modified above).
2. Dotfiles `nix flake update nixos-winpe` (currently locked at f86c33f) → user runs `nh os switch` (or sudo nixos-rebuild) → `winpe-flash arm` + reboot → real flash (~2 min, fans max) → verify `cat /sys/class/dmi/id/bios_version` = GKCN65WW.
3. Ask user about v0.6.1 tag. Cleanup promise stands (.debug scratch, dead files autorun-fwupdlcl.cmd/autorun-eval.nix).
- Update-script notes: `nix run .#winpe-image.updateScript` re-fetches the newest client ESD from the MS catalog and only rewrites url/hash/version — the build re-discovers the WinRE image, the graft families and the Winners values from that ESD, so a routine ESD bump needs no manual graft edits. If the catalog/ESD layout changes structurally, the updateScript exits with a named ERROR before rewriting default.nix, and `nix flake check -L` catches any silent breakage (installCheck asserts every grafted file is extractable; winpe-qemu asserts the real flasher runs). The bios updateScript is unchanged and its output structure (FWUpdLcl.exe + BIOS.fd + hardened platform.ini) is what winpe-flash consumes.
- Real-hardware risk notes: the WinRE boot.wim is ~595MB (the partition is 2046MB — fits); the 32-bit ESD console tools (cmd.exe/reg.exe embedded manifests) fail actctx in this environment — harmless, nothing in the flow uses them; FWUpdLcl + the stripped-manifest toolchain are the only 32-bit binaries the flow runs.

**ARTIFACT MAP (scratch, gitignored):** `.debug/hwreplica/boot-b5.wim` = the reference manually-built WinRE image that validated the ladder (t64/t64-sc/t32/t32-sc/t32-iso/t32-bare all RC=42) and FWUpdLcl; boot-g2..g6/boot-wr1/wr2 = the iteration history; `.debug/hwcheck/{esd,boot.wim,bios-pkg,sxs,sxs7,wow64,winpeshl-real.ini,startnet-real.cmd}`; `.debug/hives/` = the extracted PE hives; `/tmp/opencode/{sw64,cc,winre,sw4,chkwork,wi-out}` = the extraction/graft scratch. Replica recipe unchanged (stage-replica.sh, WIM_FILE/AUTORUN_FILE overrides, QEMU flags in the §0.5 handoff; note -m 4096 and ~700-1400s runs for the ~595MB WinRE WIMs).

**PRIOR HANDOFF (2026-09-15 ~11:45) — kept for the diagnostic history: the probe-ladder facts, the SxS store forensics, the Winners registry discovery, the WIMLIB `..` mystery, the replica recipe and pitfalls are all still accurate; the solution superseded the open questions.**

**WHERE WE ARE: the replica harness is fully working and the WHOLE pipeline validates end-to-end (startnet label-lookup → autorun → payload launch → clean self-reboot, QEMU-EXIT=0). The ONLY remaining blocker: EVERY 32-bit process in the ESD PE dies at CreateProcess with ERROR_SXS_CANT_GEN_ACTCTX ("side-by-side configuration is incorrect") — regardless of grafts, manifests, or the WOW64 layer. Five QEMU iterations (r16-r24) systematically killed my favorite theories; the honest state: the x86/32-bit SxS subsystem of THIS ESD boot PE is broken in a way none of the grafts fixed so far.**

**THE PROBE-LADDER FACTS (r20-r24, zig-built test exes in `W:\sxsprobe\`, autorun-probe.cmd; RC=42 = ran):**

- T64-RC=42 (64-bit, no manifest) and T64-SC-RC=42 (64-bit, EXPLICIT dep on `Microsoft.Windows.SystemCompatible` 6.0.26100.1 amd64 → its required dep IsolationAutomation "1.0.0.0" → ProxyStub "1.0.0.0" — the FULL amd64 chain bound from the guest's WinSxS!). ⇒ the guest's SxS binder is HEALTHY for amd64: directory scan works, version semantics accept "1.0.0.0"→1.0.26100.x, no policy files needed.
- T32-RC=1, T32-SC-RC=1 (explicit dep on the grafted x86 SystemCompatible!), T32-ISO-RC=1 (explicit dep IsolationAutomation x86) — ALL die with the identical SxS error. The 32-bit failure happens BEFORE/DURING the app's own manifest processing — independent of manifest content (matches rounds 4-5 hardware data: vendor/trimmed/dependency-free/no-manifest all identical).
- Grafts tested so far (all verbatim official files from ESD image 4): x86 SystemCompatible manifest + x86 IsolationAutomation manifest + sxsoa.dll + x86 ProxyStub manifest + sxsoaps.dll + sxsoaps.tlb (TRUE truncated names, current wimlib handles `..`!), the WOW64 layer (System32\wow64.dll + wow64cpu.dll + wow64win.dll + SysWOW64\kernel32.dll + user32.dll — the ESD PE lacks the entire wow64 layer), and deletion of ~3790 PA30 delta blobs from WinSxS/Manifests. NONE fixed the 32-bit failure (r16-r24).
- NEW root-cause candidate: the "System Default Context" for WOW64 processes (real-world evidence: MS Q&A 3277587 — one corrupt `x86_microsoft.windows.i..utomation.proxystub_*.manifest` made EVERY manifest-less 32-bit app fail with exactly our error; sxstrace showed the binder parsing that manifest during System-Default-Context creation). In our guest even after the full fix-set, 32-bit actctx creation still fails ⇒ something else in the 32-bit SxS path is missing in this PE (Components/registry store? 32-bit sxs support DLLs? deeper WinPE-WOW64 packaging?) — UNKNOWN as of now.

**KEY FACTS ABOUT THE ESD (verified):** 10 images: 1 = Windows Setup Media (no WinSxS at all), 2 = Microsoft Windows PE (amd64) = OUR PE SOURCE, 3 = Windows Setup (amd64) ≈ same family as 2 (4507 manifests, 332 PA30 + 2 raw in the x86/wow64 subset, also NO wow64 trio — swapping the PE source is a dead end), 4-10 = the OS editions. PE payload arch: FWUpdLcl.exe = pei-i386 (32-bit, imports only SETUPAPI/KERNEL32/ADVAPI32), H2OFFT-W.exe = pei-i386, BiosImageProc.dll = pei-i386, WDFInst.exe = **pei-x86-64 (64-bit!)**, FlsHook.exe arch UNKNOWN (unchecked — TODO). The guest's SysWOW64 = 345 files but MISSING the core 32-bit DLLs (kernel32/user32 — grafted from image 4 now) and System32 lacked the wow64 trio (grafted). Guest Manifests had ~4132 entries of which ~3790 were PA30 DELTA-COMPRESSED BLOBS (magic bytes `44 43 4d 01 50 41 33 30` = "DCM\x01PA30") — servicing leftovers that CBS only expands during real installation; they are UNPARSEABLE by the SxS binder; they are now DELETED from boot-g1.wim (Manifests down to ~344 raw-XML; the surviving set still includes the 6595-token amd64 trio + our x86 grafts).

**WIMLIB `..` MYSTERY (practical guidance):** the session's earlier wimlib build REJECTED any path containing `..` ("path list is not valid: WIM path cannot contain `..` path components" — extract-by-name, wimupdate add/delete dest, wimcapture) AND globs silently no-match `..` paths; multiple `wimlib-1.14.5` builds exist in the store and the message text exists in NONE of them (source forensics dead end). TODAY's `nix shell nixpkgs#wimlib` build (fd0zfsysr7gl769wv31n80a6j67xgd78) DOES accept `..` in explicit add/delete paths (verified: added the truncated proxystub manifest into a test WIM) — but globs STILL silently no-match `..`-paths in that build, and extraction by exact `..`-path still failed earlier. RULE: verify empirically per invocation; use 7-Zip (`nix shell nixpkgs#p7zip`) for anything wimlib refuses — 7z reads WIMs with image-prefixed paths (`4/Windows/...`) and handles `..` names fine.

**REPLICA RECIPE (validated r15-r24, keep):** stage = `bash .debug/hwreplica/stage-replica.sh` (OPTIONAL `AUTORUN_FILE=.debug/hwreplica/autorun-probe.cmd` override) — always reformats p4 (`mkfs.vfat -C /tmp/opencode/p4.fat -F 32 -n WinPE 2096128` + `dd bs=1M seek=2049 conv=notrunc`, p4 offset 2,148,532,224 = 2049 MiB, GPT size 4196352 sectors — mformat's EOF-sizing overshoots the partition and HANGS BOOTMGR FOREVER at the TianoCore spinner), mcopy result-winpe boot/EFI + boot-g1.wim → sources/boot.wim + autorun.cmd + sxsprobe/* + firmware/GKCN65WW/* (bios-pkg). Boot = `timeout 600 qemu-system-x86_64 -machine q35 -m 3072 -smp 1 -cpu max -drive if=pflash,format=raw,readonly=on,file=$OVMF/FV/OVMF_CODE.fd -drive if=pflash,format=raw,file=$PWD/VARS.fd -drive file=$PWD/disk.img,format=raw -no-reboot -display none -net none -monitor unix:$PWD/mon.sock,server,nowait` with OVMF = nixpkgs OVMF-202608 (`nix eval --raw nixpkgs#legacyPackages.x86_64-linux.OVMF.fd`; fresh VARS each run), screendumps every 15s via socat on mon.sock. QEMU-EXIT=0 = the guest finished the autorun (fail branch = 20s ping → wpeutil reboot) and self-rebooted. Collect = `mtype -i disk.img@@2148532224 ::/autorun.log` / `::/firmware/GKCN65WW/payload.out` / `::/startnet.log` (p4) — p1 ESP gets winpe-debug.log/winpe-dpout.log breadcrumbs. ALWAYS verify stage.log + p4 mdir BEFORE a QEMU run (silent stage failures burned r13/r14).

**GUEST-SIDE TRUTH (all validated in-replica):** startnet label-lookup works ([3] WinPE volume = 2 → assign W: → [5] found autorun.cmd); autorun stages + runs the payload via `call ... > payload.out 2>&1`, snapshots FLASH_RC before `type` resets errorlevel; fail branch = 20s pause → reboot. winpeshl.ini (LF-only) is fine; the "no commands were successfully launched" error was ONLY the symlink-injection bug (wimlib stores symlinks AS symlinks — always `cp -L` real files). Production autorun eval: `nix build --impure --expr 'let flake = builtins.getFlake "/home/malix/Repositories/Malix-Labs/NixOS_WinPE"; sys = flake.inputs.nixpkgs.lib.nixosSystem { system = "x86_64-linux"; modules = [ (import <repo>/profiles/lenovo-legion-15ach6h.nix) { system.stateVersion = "26.11"; boot.loader.grub.enable = false; fileSystems."/".device = "/dev/dummy"; fileSystems."/".fsType = "ext4"; nixpkgs.hostPlatform = "x86_64-linux"; nixpkgs.config.allowUnfree = true; } ]; }; in sys.config.hardware.winpe.autorunScript' -o autorun.cmd` (`pkgs.lib.nixosSystem`/`pkgs.nixosSystem` DON'T exist in this nixpkgs — use the flake input's lib).

**TEST-WIM STATE (`boot-g1.wim`, 395,673,991B, the one staged on p4):** base = hardware's own boot.wim (`.debug/hwcheck/boot.wim` = PRISTINE, never modify) + real-file startnet.cmd (4005B current) + winpeshl.ini (65B) + x86 6595-token grafts (SystemCompatible manifest-only, IsolationAutomation manifest + sxsoa.dll, ProxyStub manifest + sxsoaps.dll/tlb under TRUE truncated names) + WOW64 layer (wow64.dll/wow64cpu.dll/wow64win.dll in System32; kernel32.dll/user32.dll in SysWOW64) + PA30 blobs purged from Manifests. The production fix will need to reproduce ALL of this cleanly (a graft script in winpe-image/populateImage + the PA30 purge decision).

**SXS DIAGNOSTICS TRIED + DEAD: sxstrace in the guest** (present in System32! autorun-diag.cmd runs `start /b sxstrace trace -logfile:X:\sxstrace.etl` before the payload + parses after; a QEMU-monitor `sendkey x` loop (starting ~t=225s, every 10s) stops the trace — CRITICAL: the trace MUST be stopped BEFORE `sxstrace parse` reads the etl, else it parses an empty live buffer (r18 bug); persist sxstrace.txt/etl to W: before reboot — X: is RAM) — the trace captured ZERO events (the SideBySide ETW provider is likely unregistered in WinPE) → sxstrace is a dead end here. Event log = dead in WinPE. ntdll/kernel32/wow64-trio strings contain NO SystemCompatible/IsolationAutomation references (the default-context reference is constructed or elsewhere).

**NEXT STEPS (priority order):**
1. Check `FlsHook.exe` arch (objdump -f) — if 64-bit, explore what it does (Insyde flash helper?).
2. RESEARCH Lenovo's OFFICIAL bootable WinPE BIOS update ISO for the Legion 5 15ACH6H ("BIOS Update Utility (WinPE)") — the vendor may ship a WORKING WinPE flasher on their support site; that would sidestep the whole 32-bit-in-ESD-PE problem with 100% official files. Also research how Insyde/Lenovo WinPE flashers normally run (do vendor WinPE packs include the WOW64 optional component?).
3. ADK WinPE route: Microsoft's WinPE add-on with the WinPE-WOW64 optional component is the OFFICIAL way to get 32-bit support in WinPE — but CBS-registered manifests/registry deltas make manual grafting fragile; only pursue if Lenovo's ISO doesn't pan out.
4. More 32-bit diagnostics IF the binary route stays attractive: check for a COMPONENTS registry hive in the guest (`/Windows/System32/config/*`), whether the SxS assembly store is registry-driven for 32-bit; consider grafting x86 Common-Controls (guest has only amd64 CC 5.82/6.0) as another explicit-dep probe.
5. WHEN THE 32-BIT PATH WORKS: the production autorun (AUTORUN_FILE override off) → FWUpdLcl usage text → set profiles/lenovo-legion-15ach6h.nix silentFlags → iterate → full `nix flake check -L` → commit → push → dotfiles bump → user `nh os switch` + reboot → verify bios_version = GKCN65WW → ask about v0.6.1 tag.
- Productionization notes: the graft belongs beside populateImage's existing winpeshl/startnet injection (pkgs/winpe-flash L179-185); the PA30-purge + wow64-layer decisions need user sign-off (they DELETE/ADD official files); installCheck should assert the grafted manifests exist in the built WIM.
- Cleanup promise: `.debug` = gitignored scratch; after the mission either generalize the committed winpe-qemu check with a disk-layout parameter or distill + delete. Dead files: `autorun-fwupdlcl.cmd`, `autorun-eval.nix`, old dumps.

**ARTIFACT MAP (as of compaction):** `.debug/hwcheck/`: `esd` → vf1mfb8n (4.68GB VERIFIED, GC-rooted), `boot.wim` = PRISTINE (never modify!), `sxs/` (3 raw-XML x86 files), `sxs-extract/` (amd64 SystemCompatible manifest), `sxs7/` (7z-extracted image-4 x86 closure incl. TRUNCATED proxystub files), `wow64/` (the 5 wow64-layer files), `startnetScript`/`winpeshlIni` out-links + `-real` copies, `wimupdate-cmds*.txt` (fix = 3793 lines: 3788 PA30 deletes + proxystub deletes + truncated adds), `bios-pkg` → a4p3c8aj, `autorun-path.txt`. `.debug/hwreplica/`: `boot-g1.wim` (the current test WIM described above), `disk.img`, `stage-replica.sh`, `stage.log`, `autorun.cmd` → qkxp5qrk (production eval), `autorun-diag.cmd` (sxstrace version), `autorun-probe.cmd` (ladder), `sxsprobe/` (zig exes t64/t32/t64-sc/t32-sc/t32-iso + manifests — built with `nix shell nixpkgs#zig`; zig 0.16 dropped std.fs.cwd — probes just return exit code 42), `ovmf-dir-fd`, `VARS.fd`, dumps r11-r24, `sxstrace.etl` (empty). `.debug/.guest-tree/` = full 7z extraction of boot-g1.wim (3978 manifests incl. the PA30 blobs — the PA30 delete list source). DEAD debris: `autorun-fwupdlcl.cmd`, `autorun-eval.nix`, old dumps.
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

**DEEP-E2E ADDENDUM (2026-09-16, pre-hardware tests r37-r39): attempted two QEMU-level increments before the real flash. (1) SMBIOS spoof: ran the replica with -smbios type=0/1/2 carrying the machine's real identity (LENOVO/82JU/"LEGION 5 15ACH6H"/LNVNB161216, incl. the trailing-space quirks read from /sys/class/dmi/id/). RESULT: FWUpdLcl still fails at 8743 "Cannot locate hardware platform identification" -> the platform ID is NOT DMI/SMBIOS-based; FWUpdLcl (banner: "Intel (R) Firmware Update Utility", usage mentions MEI and MeBX password) identifies the platform through the Intel ME/MEI channel, which QEMU q35 cannot emulate. This is a structural QEMU wall, not a flaw in the image. (2) WDFInst.exe (the 64-bit KMDF driver installer for H2OFFT.sys) ran natively but exited rc=2 with no console output - the driver install path fails in QEMU; note this driver belongs to the H2OFFT-W toolchain which the flow does NOT use (the entry point is FWUpdLcl). CONCLUSION: every software-reachable step is now exercised; the first genuinely-untested step is the ME-channel handshake + SPI transaction on real hardware. Deploy mitigations unchanged: one-shot BootNext, silent+no-self-reboot platform.ini, surviving logs (autorun.log/payload.out/H2OFFT.log), winpe-flash logs for post-mortem.**
