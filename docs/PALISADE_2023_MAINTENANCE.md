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

---

## LDW (Lane Departure Warning) — research in progress

Open thread: when openpilot is engaged (lateral active), the cluster's LDW chime + lane recolor does NOT fire on lane crossing without blinker. In stock (no openpilot) and even in SCC-only mode the same camera/cluster fire LDW normally. Goal: restore LDW while engaged.

### Existing related code

- DBC fix for the RH bit position is committed: `opendbc` `df5928ca` — `CF_Lkas_LdwsRHWarning` moved from `10|2` (stock layout) to `14|2` (verified by recording). bits 10-11 are unused on this model.
- `hyundaican.py:create_lkas11_can_canfd_blended` lines 137-148 already does `max(int(left_lane_depart), int(lkas11["CF_Lkas_LdwsLHWarning"]))` (and the same for RH), gated by `HYUNDAI_PALISADE_2023 AND CAN_CANFD_BLENDED`. The intention was that even when openpilot's own internal LDW (`selfdrive/controls/lib/ldw.py:21`) goes silent during `CC.latActive`, the camera's value would still propagate. **But this assumes the camera publishes a non-zero LDW bit.**

### What we proved with rlog / CSV analysis (2026-06-28..30)

Comparing camera's outgoing `0x340` (LKAS11) on bus 2 across three driving scenarios:

| Scenario | byte 1 | byte 3 | byte 4 | byte 5 | StrToq | ActToi | Activemode | FcwOpt_USM | NEW_SIGNAL_1/2 | LDW fires? |
|---|---|---|---|---|---|---|---|---|---|---|
| Dashcam (no engagement) | `0x00` baseline / `0xX0` on LDW | `0xCC` | `0xX2` | 0x37..0x64 (varies) | varies (-34..-180 if LKA on) | 1 | 3 | 2 | 0 / 0 | ✓ |
| SCC ON, no openpilot | `0x00` / `0xX0` on LDW | `0xCC` | `0xX2` (LDW: 1/3) | varies | -34 baseline, -180 during LDW (camera nudging wheel) | 1 | 3 | 2 (LDW: 1/3) | 0 / 0 | ✓ 263 events in segment 41 |
| **Openpilot engaged** | **`0x0F` constant** | **`0x04`** | **`0xX4`** | **`0x64` stable (100)** | **0** | **0** | **0** | **4** | **3 / 3** | **✗ 0/11893 frames over segments 30+31** |

Camera's `hyundai_checksum(bytes[1:8])` matches our `mk_crc8_fun(CRC8J1850, init_crc=0xFD, xor_out=0xDF)` on 5997/5997 frames — checksum is NOT the bug.

LDW value semantics (bench-verified, see [[project-palisade-2023-ldw-lkas11]] memory): `LdwsLH/RHWarning = 0` silent / `1` blink + chime / `2` blink + chime (visually same as 1) / **`3` VISUAL-ONLY (blink WITHOUT chime)** — the "downgrade" mode the cluster has internally.

LKAS11 byte field semantics also bench-pinned same session:
- `CF_Lkas_LdwsActivemode (byte 3 b6-7)`: 0=no lanes / 1=LH only / 2=RH only / **3=both lanes** (lane overlay control)
- `CF_Lkas_FcwOpt_USM (byte 4 b0-2)`: 0=LKAS icon HIDDEN / 1=ready (grey) / 2=enabled (green) / **4=observer ("ADAS active elsewhere")**
- `NEW_SIGNAL_1 (byte 1 b0-1)` + `NEW_SIGNAL_2 (byte 1 b2-3)`: both = 3 in observer mode, 0 in normal — likely the camera's "I am passive observer" state markers. Not in our DBC by these names; positions match `CF_Lkas_LdwsSysState` / SysWarning fragments in stock layout but shifted.

Bench-tested LKAS11 bits that DO NOT affect cluster's chime decision (with `LdwsLH = 1` injected on a disconnected cluster): `ActToi`, `CR_Lkas_StrToqReq` (torque), `ToiFlt`, `LdwsActivemode`, `FcwOpt_USM`. So the downgrade we see on car when engaged is NOT cluster downgrading our outgoing frame — the cluster faithfully shows whatever LDW bits it receives. The bug is upstream: camera publishes 0 on those bits.

### Hypothesis (CORRELATION confirmed, CAUSATION not yet proven)

When openpilot transmits LKAS11 (with non-zero torque, ActToi=1, etc.) on bus 0, panda by default echoes that frame to bus 2 — where the camera lives. Camera reads the echo, sees "someone else is doing lateral" (active torque + ActToi=1 with frame source that isn't herself), and switches to "ADAS observer mode": stops her own LKA torque, stops LDW logic, sets the `byte 1 = 0x0F` marker. In this state our `max(camera=0, op=0)` pass-through has nothing to forward.

Strong correlation evidence:
- Stock SCC mode: camera in NORMAL mode (Activemode=3, ActToi=1) — LDW works.
- Openpilot engaged: camera in OBSERVER pattern (byte 1=0x0F, Activemode=0, ActToi=0, NEW1/2=3) — LDW silent in 5893+6000 frames.
- Differentiator vs SCC is precisely "is openpilot transmitting LKAS11?" — SCC is engaged in both but only openpilot triggers observer mode.

NOT yet proven:
- That the observer-mode trigger is specifically "our LKAS11 echo on bus 2" (could be MDPS state or some other side effect).
- That the camera would resume publishing LDW if she stopped seeing our echo.

### Proposed fix (planned, NOT YET COMMITTED) — Variant A

Add one case to `opendbc/safety/modes/hyundai.h::hyundai_fwd_hook`:

```c
static bool hyundai_fwd_hook(int bus_num, int addr) {
  return ((bus_num == 2) && ((addr == 0x4EC) || (addr == 0x53E))) ||
         ((bus_num == 0) && (addr == 0x340));   // ← new: hide our LKAS11 from camera
}
```

Effect: panda stops forwarding our outgoing LKAS11 (bus 0) to bus 2 (camera). Cluster still sees our frame (it's on bus 0 already). Camera no longer "sees" external LKA active → stays in normal mode → continues LDW logic → publishes LDW bits when departure happens → our existing `max(camera_LDW, op_LDW)` pass-through in `hyundaican.py:144` propagates them into outgoing frame → cluster fires chime + recolor.

The 0x340 content is NOT modified by this change — it's purely a routing decision (don't echo it to bus 2). The existing LDW `max()` pass-through stays as-is.

### Risks / unknowns to verify with one drive after applying Variant A

1. **Does the trigger turn out to NOT be the echo?** Then camera stays in observer mode anyway, fix does nothing. Reversible: revert the C line.
2. **Does the camera fault without seeing our LKAS11 on bus 2?** Some cameras use the echo as a watchdog. Unlikely (camera is the natural producer of LKAS11, doesn't need to see herself echoed) but possible. Would show as steering error / fault in logs.
3. **Wheel-nag escalation.** Camera back in normal mode → starts her internal driver-attention timer. In stock SCC the driver wiggles the wheel periodically to reset. With openpilot rulling, the driver isn't wiggling, so the timer could escalate to "red+beep" or eventually disengage camera's own LKA. The user thinks this is moot because openpilot's continuous micro-corrections move the wheel & MDPS column torque, which the camera should read as "driver active" — but this is an assumption, real-car test needed. Visually it won't show up on cluster (we don't pass `SysWarning` through to outgoing frame), but the camera might disengage own LKA after long timeout, and if disengagement also kills her LDW, we lose the alarm.

   Optional pre-confirmation: in stock SCC + LKA, deliberately go hands-off and time:
   - When does the cluster show yellow "hands on wheel" warning (SysWarning=4)?
   - When does it escalate to red + beep?
   - When does the camera disengage LKA (icon goes grey / steering wheel symbol off)?
   - After disengage, does deliberate lane crossing still fire LDW chime? If YES → safe for us (camera disengages LKA but LDW survives). If NO → camera shuts down LDW with LKA → we need an ack mechanism for the nag.

4. **Global Hyundai impact.** The new fwd_hook entry is NOT gated to Palisade 2023 — it applies to ALL cars using `hyundai_hooks`. If on another Hyundai the cluster actually NEEDS to see camera's LKAS11 (e.g., for some passthrough we don't have here), it could break. Mitigation if needed: per-car gating using the same pattern as the TSR feature (carFingerprint check at init, set a static global, check in fwd_hook).

### Where we paused (2026-06-30)

User confirmed Variant A direction (camera-based, not openpilot-model-based — see "не нужно ориентироваться на модель, нужно ориентироваться на камеру"). Hasn't yet given green light to commit; wants to either (a) confirm the trigger hypothesis with a bench inject of fake openpilot LKAS11 onto camera bus + watch camera response, or (b) just apply on car and see.

Model-based path (Variant B = remove `not CC.latActive` from `ldw.py:21`) is OFF the table — analysis of segment 30/31 showed the model NEVER detected lane departure even during user-confirmed deliberate crossings (272+238 lane-close moments, 0 full departures = desire>0.1 AND lane close), so the model isn't a reliable source here.

### Useful file references

- Panda safety: [`opendbc_repo/opendbc/safety/modes/hyundai.h`](opendbc_repo/opendbc/safety/modes/hyundai.h) — `hyundai_fwd_hook` near line 552, `HYUNDAI_CAN_CANFD_BLENDED_TX_MSGS` near line 339
- LKAS11 generation: [`opendbc_repo/opendbc/car/hyundai/hyundaican.py`](opendbc_repo/opendbc/car/hyundai/hyundaican.py) — `create_lkas11_can_canfd_blended` lines 106-203, the `max()` pass-through at lines 143-145
- DBC: [`opendbc_repo/opendbc/dbc/generator/hyundai/hyundai_palisade_2023.dbc`](opendbc_repo/opendbc/dbc/generator/hyundai/hyundai_palisade_2023.dbc) — BO_ 832 LKAS11 around line 278
- Reference rlogs (in `/home/infection/sunnypilot/`):
  - `7ce1f2def8ac957b_00000003--a27979562b--19--rlog.zst` — dashcam (no engagement, no SCC): 289 LDW events
  - `7ce1f2def8ac957b_00000003--a27979562b--41--rlog.zst` — SCC ON (cruise 64 km/h), no openpilot: 263 LDW events (proves camera+cluster fire LDW with SCC active)
  - `7ce1f2def8ac957b_00000065--a5fe0dddea--30--rlog.zst` and `--31--` — openpilot engaged with user-confirmed deliberate lane crossings: 0 LDW events across 11893 camera frames (proves camera silent when engaged)
  - Per-bus CSVs: `/home/infection/sunnypilot/lkas1.csv` and `lkas2.csv` — same data as segments 19/41 in CSV form
