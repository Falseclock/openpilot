# Palisade 2023 sunnypilot fork — maintainer notes

Context and decisions for maintaining this fork (Falseclock) of the Hyundai Palisade 2023 /
Kia Telluride sunnypilot port. Written 2026-05-27.

## TL;DR / current setup

- **Car:** Hyundai Palisade 2023, **non-HDA2**, on a **comma 4**.
- **Use case:** openpilot for **steering/lateral only**. Longitudinal is **stock** (factory radar
  SCC/AEB). Reason: the stock radar works in fog, the camera does not. No ESCC hardware installed.
- **Working base (chosen):** the *matched* pre-MADS-field set from bryangerlach's fork:
  - openpilot `pal23sp-long` = bryan's base + opendbc submodule repointed to `Falseclock/opendbc`
  - opendbc pin `7b9ab1cf` (bryan's Palisade port, radar-disable intact)
  - panda pin `6ddc631b` (2026-03-17, before the MADS `controls_allowed_lateral` field)
- **Deploy:** `git push --force-with-lease falseclock pal23sp-long`, then reinstall the comma from
  `Falseclock/pal23sp-long`.

## Key facts (why it's set up this way)

1. **Palisade 2023 (non-HDA2) exists ONLY in bryangerlach's fork.** Mainline sunnypilot opendbc has
   only `HYUNDAI_PALISADE` (2020-22). `HYUNDAI_PALISADE_2023` + the DBC `hyundai_palisade_2023_generated`
   + fingerprints + radar handling are bryan's custom work. sunnypilot's own `palisade-2023-port-1-new`/
   `-2-new` branches are stale (2024-09 / 2025-02). → There is **no fresh clean mainline path** for this
   car; it must be based on bryan's work.

2. **bryan abandoned the project** (his branch frozen ~2026-04-28; previously synced sunnypilot master
   ~weekly). Staying fresh is now the maintainer's job.

3. **opendbc and panda are tightly coupled — you cannot freshen one and freeze the other.** The safety
   code (the `health` struct and globals like `controls_allowed_lateral`) lives in `opendbc/safety/`
   and is **compiled into the panda firmware**. A fresh panda expects the matching fresh opendbc safety
   API. Mixing fresh panda (`0a9ef7ab`, has `controls_allowed_lateral`) with old opendbc (`7b9ab1cf`,
   lacks it) → panda build fails: `'controls_allowed_lateral' undeclared in panda/board/main_comms.h`.
   So "maintain bryan's opendbc" really means "continuously merge sunnypilot/opendbc master into it".

4. **radar-disable / `RADAR_SCC` is part of the port, not a removable add-on.** It is how openpilot
   takes over longitudinal on a non-HDA2 Palisade WITHOUT ESCC (disables stock radar SCC, which also
   disables AEB/FCA). It is **entirely gated by `CP.openpilotLongitudinalControl`**
   (`= alpha_long and alphaLongitudinalAvailable`). With stock long it never runs — radar stays active.
   ⚠️ Do NOT enable "Experimental / alpha longitudinal" in settings unless you want the radar disabled.

5. **ESCC alternative (non-HDA2):** an aftermarket module on the radar lets openpilot longitudinal run
   without disabling the radar (keeps AEB/FCA + radar lead data). Needs custom panda firmware
   (`bryangerlach/panda` branch `escc-pal23sp`, `cd panda/board && make flash`). In code: gated by
   `HyundaiFlagsSP.ENHANCED_SCC`; ESCC talks on CAN id `0x2AB`. Not currently used.

## Modernization plan (future — to become the Palisade maintainer, incl. radar)

Goal: track fresh sunnypilot and re-implement the full port (including radar-disable) on top.

- A naive `git merge` of modern sunnypilot/opendbc into the Palisade branch auto-merges most files but
  is **semantically broken** in the Hyundai files:
  - flag renames: `CANFD_LKA_STEERING`→`CANFD_LKA_STEER_MSG`, `..._ALT` likewise,
    `ENABLE_BLINKERS`→`CANFD_ENABLE_BLINKERS`
  - `RADAR_SCC` (`2**14`) collides with modern `CANFD_RADAR_SCC` (`2**14`); `RADAR_SCC` is dropped from
    the enum but still referenced → `AttributeError: HyundaiFlags has no attribute 'RADAR_SCC'`
  - modern `interface.py` wins the merge and **drops** the radar-disable logic
    (`if not ret.flags & HyundaiFlags.RADAR_SCC: ...`).
- **A clean build does NOT mean radar/safety behavior survived.** To keep radar-disable working, its
  logic must be re-applied onto modern's refactored `opendbc/car/hyundai/` and `opendbc/safety/`.
- Conflicts are concentrated in `opendbc/car/hyundai/{carcontroller,interface}.py` + `values.py`
  (HyundaiFlags enum) + `opendbc/safety/`. **Validate on road** for any safety-relevant change.
- A parked first attempt lives at `Falseclock/opendbc` branch **`pal23sp-long-modern` (`8e7e3cc4`)**:
  modern `4dad7b09` merged into Palisade `7b9ab1cf`. It builds panda but has the RADAR_SCC break and
  lost radar-disable — use it as a reference, not as-is.
- For a lateral-only build you could resolve the radar conflicts toward mainline (radar-disable erodes
  away); for a full maintainer build you must port the radar logic forward.

## Repo / git gotchas (Windows + WSL)

- Run git via WSL: `wsl.exe -d Ubuntu-24.04 -- bash -lc "cd /home/infection/sunnypilot/openpilot && ..."`.
  Windows-side git breaks on symlinks (`third_party/libyuv`, `third_party/snpe`).
- Needed once: `git config --global --add safe.directory '%(prefix)///wsl.localhost/...'`.
- Submodule updates may need `-c protocol.file.allow=always`.
- `tinygrad_repo` pins an orphaned commit (`3501a714...`) not on any branch tip; fetch it directly:
  `git -C tinygrad_repo fetch origin 3501a714785ff370cffb966a45d5f9cdf6c9ea7a` then
  `git -c protocol.file.allow=always submodule update --no-fetch tinygrad_repo`.

## Remotes

- `falseclock` — your fork (openpilot `git@github.com:Falseclock/openpilot`, opendbc `https://github.com/Falseclock/opendbc.git`)
- `bryangerlach` — upstream Palisade port source (abandoned)
- `sunnypilot` — mainline
