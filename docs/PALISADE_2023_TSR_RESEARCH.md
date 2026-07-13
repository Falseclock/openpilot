# Palisade 2023 — TSR / speed-limit CAN research

Working document. Verified facts vs hypotheses are clearly separated — do not promote
hypotheses to facts without runtime checks. Each round of recording extends this file.

End goal: implement a filter through comma that suppresses the cluster's speed-alert
chime unless the actual over-speed exceeds a user-configurable offset (e.g. +10 km/h),
**independent of the camera's country coding** (KR coding exposes the offset setting
in the cluster UI; RU coding hides it and forces alert at any over-speed).

## Research questions

1. **Sign-change chime — source.** When the camera TSR mode is ON, sign changes are
   accompanied by a sound on cluster + HUD. When TSR is OFF and the speed limit is
   injected from the head unit / map / APK, the displayed limit also changes — but
   **without sound**. Is the chime triggered by a CAN signal (presumably from the
   camera), or is it generated locally by the cluster reacting to its own input source?
2. **Over-speed warning — source.** When ego speed exceeds the displayed limit, the
   speed-sign on HUD/cluster gets a red ring; if the over-speed continues or is large,
   the cluster also chimes. Is this driven by a CAN signal from the camera, or is it
   cluster-local logic that compares ego speed vs displayed limit?
3. **Offset configuration.** With KR coding the cluster lets you pick the over-speed
   offset (-10, -5, 0, +5, +10 km/h) before warning. With RU coding the menu disappears
   and the offset is effectively 0. Where does this setting live, and how can we
   replicate "configurable offset" via comma regardless of camera coding?

## Verified facts (round 1, recording `speed_alerts.csv`)

- Recording: `/home/infection/sunnypilot/speed_alerts.csv`, 400 s, 2.7 M frames,
  approximate start time 18:45:58.
- **Two speed-limit sources, with the camera arbitrating between them:**
  - **`0x544` `SpeedLim_Nav_Clu`** bus 0 (NAV/HU side; comment in DBC:
    "Speed limit displayed on Nav, Cluster and HUD"; only 4 transitions in 400 s)
  - **`0x53E` LKAS12** bus 2 (camera-side; 6 transitions in 400 s)
    - `CF_Lkas_TsrSpeed_Display_Clu` — byte 3, 8-bit km/h (cluster value)
    - `CF_LkasTsrSpeed_Display_Navi` — byte 4, 8-bit km/h (HUD/NAVI value)
    - In this recording both signals were always equal.
  - Pairing transitions of 0x544 → next 0x53E with the same new value:
    `lag = 0.09 s` (NAV and camera agreed simultaneously),
    `lag = 13.48 s` (camera adopted NAV's value after ~13.5 s, matches user's
    observation that the camera follows NAV with a 10-15 s delay), and longer
    lags when NAV gave a value the camera disagreed with for a while.
- A camera-side TSR state message **`0x4EC` bus 2** (not in
  `hyundai_palisade_2023_generated.dbc`, identified empirically) carries:
  - byte 3 — TSR speed in km/h (matches `0x53E`)
  - byte 4 — state bits (observed values: `0x00, 0x01, 0x02, 0x10, 0x11, 0x20, 0x21, 0x22`)
  - **bit 5 (`0x20`)** is set in byte 4 exactly when a *new* sign value is reported;
    fires simultaneously with each `0x53E` transition, then drops to 0 within ~0.5 s.
- Bus mapping in this recording: messages also seen with `bus = bus_real + 128`
  in the log; bit 7 = "TX/sent" flag from the panda log format — duplicates that
  can be skipped for change analysis.
- Wheel-speed data is in **`WHL_SPD11` (`0x386`)** bus 0 — four 14-bit signals
  `WHL_SPD_FL/FR/RL/RR`, scale 0.03125 km/h per LSB. Real vehicle speed = mean
  of the four (matches user's definition).

## Hypotheses

Marked H1/H2/…; each lists what's needed to confirm.

- **H1 (likely correct, needs a TSR-off recording to fully confirm): the chime
  is triggered by the camera via `0x4EC`.** Bus 2 is the forward CAN from the
  camera ECU. Map/APK injection arrives via the NAV side (`0x544` on bus 0); if
  the camera disagrees or TSR is off, the camera does not update `0x53E` and
  does not fire the chime on `0x4EC`. To fully confirm: record the same stretch
  with camera TSR turned off; verify that `0x53E` does NOT change while NAV
  source still updates the displayed limit elsewhere.
- **H2 (strong, partially confirmed): byte 4 of `0x4EC` encodes two independent
  triggers.**
  - **bit 5 (`0x20`) = displayed-limit-value-changed pulse.** Fires for ~0.5 s
    at exactly each `0x53E` value transition. Verified 4/4 across both
    recordings (97.31 s, 143.42 s, 207.13 s in round 1; 484.43 s in round 2).
    Important: this is NOT "new sign every time the camera sees a sign" —
    e.g. in round 2 the driver passed many "20" signs but the bit only fired
    once, at the 20→40 transition. Driving past more signs of the same
    value does not pulse this bit.
  - **bit 4 (`0x10`) = candidate "over-speed warning"**. In this recording it
    fires only with `0x20`-absent transitions, observed at 64-67 s, 109.2 s,
    222.7 s, 368.8 s — at least three of these coincide with sustained
    over-speed intervals (real wheel-avg > displayed `0x53E`). Not yet proven
    that this bit corresponds to the over-speed alert (could also be a periodic
    reminder). Needs a recording with deliberately timed over-speed and noted
    chime audibility.
  - bits 1, 0 — sub-states during transitions (no clear semantics yet).
- **H3 vs H3': what drives the red-ring + over-speed chime — cluster-local
  comparison (H3) or a CAN flag from the camera (H3')?**
  - If `0x4EC` byte 4 bit 4 (H2) is confirmed as the over-speed flag, then
    **H3' is correct** (CAN-driven, from camera) and the offset filtering
    happens *inside* the cluster on top of the bit's information.
  - To verify and to learn where the offset filter sits, see "Open data needs"
    below.

## Open data needs

To answer the questions above, we need at least these additional recordings:

1. **TSR-off route**: same road segment with camera TSR mode disabled; speed
   limits injected from HU/map. Need: `0x53E` and `0x4EC` traces aligned with
   noted sign-change moments.
2. **RU-coded over-speed route**: camera coded for RU (no offset menu), driver
   deliberately exceeds the limit, with timestamps written down. Need: ego
   speed (`CF_Clu_VehicleSpeed` in CLU11 or `WHL_SPD11` 0x386) and any
   message-level flags at the moment the cluster starts warning.
3. *(optional)* **KR-coded over-speed route** with offset set to +10; deliberately
   exceeded by 5 then by 15. If the warning bit/flag fires only at +15, the
   offset is being filtered locally in the cluster (H3); if the bit fires at +5
   too but the warning rendering ignores it, the offset is rendered-only.

For each recording: write down the approximate start clock time and a list of
event timestamps (sign change, over-speed start/stop). With those we can compute
relative-time windows and search CAN deltas.

## End-goal implementation sketch (to revisit after data)

Implementation note (corrected): the sunnypilot fork already actively rewrites
camera-forward CAN (radar-disable in the Palisade port). A chime-gating filter
on `0x4EC` is in the same architectural class — not a new safety risk — but it
does change driver-facing alert behavior, so it must be backed by **confirmed**
hypotheses (not "code reads this way") and validated on the road. The rule is
"no patches on UNCONFIRMED hypotheses", not "do not touch camera-forward".

Plan, once H2 + H3' are confirmed:

- Handler on the camera-forward bus that **masks `0x4EC` byte 4 bit 4 (`0x10`)**
  unless our own comparison says `real_speed > displayed_limit + user_offset`.
  `real_speed` from `WHL_SPD11` (`0x386`) wheel-average; `displayed_limit` from
  `0x53E` byte 3; `user_offset` from a Param UI control (default 0).
- Optional: bit 5 (`0x20`) — displayed-limit-value-changed pulse — left untouched (user wants the
  beep on sign change); only the over-speed nag is gated.
- Also possible: an additional offset compensating for cluster-shown speed bias
  (~5 % + tire-diameter delta) so the comparison reflects actual ego speed
  rather than what the cluster shows.
- If we instead find a CAN write that programs the cluster's offset directly
  (KR-coding equivalent), prefer that — cleaner than rewriting a bit each cycle.

## File pointers

- DBC for cluster TSR display: `opendbc_repo/opendbc/dbc/hyundai_palisade_2023_generated.dbc`,
  message `BO_ 1342 LKAS12` (search for `CF_LkasTsrSpeed`).
- `0x4EC` is not in the Palisade DBC; treat byte 3 as `tsr_speed_kph`, byte 4
  as `tsr_state_bits` until a proper signal definition is added.
- Round-1 analysis scripts (local, throwaway): `/tmp/analyze_speed.py`,
  `/tmp/find_all_alerts.py`, `/tmp/inspect_candidates.py`.

## Change log

- Round 1 (2026-05-28): identified `0x53E` LKAS12 as display source, `0x4EC` bus 2
  as candidate chime trigger (camera side). Open: source-of-sound (H1),
  over-speed mechanism (H3 vs H3'), offset config location.
- Round 1b (2026-05-28, same recording, deeper read):
  - Found `0x544 SpeedLim_Nav_Clu` as the NAV input; confirmed by data that the
    camera arbitrates and follows NAV with ~13.5 s lag in at least one case
    (matches user's "10-15 s" description).
  - Decoded `WHL_SPD11` (`0x386`) — real ego speed = average of four wheel
    speeds; ranged 0-62 km/h in this trip.
  - Found 6 over-speed intervals in the recording (longest 24-26 s, with the
    real speed up to ~+7 km/h over the camera-shown limit).
  - Re-classified user's noted 5 "events": **ev3 is a pure sign-chime (no
    over-speed), ev5 is a pure over-speed alert (no sign change)** — a clean
    contrast for future bit-level disentanglement.
  - **`0x4EC` byte 4 bit 4 (`0x10`)** observed at 4 moments, 3 of which fall
    inside sustained over-speed intervals → candidate for the over-speed
    warning bit (H2 strengthened).
  - Implementation-policy correction: comma already modifies camera-forward
    CAN, so chime gating is in scope. Rule is "no patches on UNCONFIRMED
    hypotheses", not blanket "don't touch camera-forward".

- Round 2 (2026-05-29, recording `/home/infection/sunnypilot/29.05.2026.csv`,
  focus window 392.634-536.685 s, RU coding, driver-annotated):
  - In this window the camera limit was 20 km/h until t=484.43 s, then changed
    to 40 km/h with a NEWSIGN-chime fire on `0x4EC` byte 4 bit 5 (`0x20`).
  - Six over-speed events observed (real speed > camera limit). Cross-tabulated
    against `0x4EC` byte 4 bit 4 (`0x10`) and the driver's audible-alert notes:

    | over-speed       | Δ km/h | duration | bit `0x10` fired | driver heard sound |
    |---|---|---|---|---|
    | 399.7-411.2 (20) | +5.2 | 11.5 s | yes @ 403.21 | yes (likely) |
    | 425.9-433.9 (20) | +2.8 |  8.0 s | yes @ 429.82 | yes (likely) |
    | 452.1-453.4 (20) | +0.4 |  1.3 s | no | no (briefly over, "dropped, no sound") |
    | **525.0-530.0 (40)** | **+4.3** |  5.0 s | **no** | **no — "red flashing only, no sound"** |

  - **Conclusion (now strongly confirmed):**
    - `0x4EC` byte 4 bit 4 = **over-speed audible-alert trigger** sent by the
      camera. Fires only after a sustained over-speed past the camera's
      country-coded threshold.
    - Red-ring on the cluster is **independent** of bit 4: at 525-530 s the
      cluster painted red but bit 4 stayed 0. Red-ring is cluster-local
      visual logic on top of `CF_Clu_VehicleSpeed` vs displayed limit.
    - Camera's own threshold under RU coding is non-trivial: +5.2 / 20 = 26 %
      and +2.8 / 20 = 14 % triggered; +4.3 / 40 = 10.75 % did NOT — consistent
      with a fractional threshold near ~12-14 %, or a fixed +5 km/h absolute
      that 4.3 doesn't reach.
  - **Sign-change chime** still cleanly identified: at t=484.43 the limit went
    20 → 40 and bit 5 (`0x20`) was set for 0.5 s on `0x4EC`.

  - Implementation direction confirmed: **gate `0x4EC` byte 4 bit `0x10` in the
    camera-forward stream**; replace it with our own decision
    `cluster_speed > displayed_limit + user_offset`. Red-ring keeps
    working untouched (cluster-side). Bit 5 (displayed-limit-value-changed pulse) is left alone
    unless the user later wants to suppress that too.

- Round 2c (2026-05-29, same window, fix on reference speed):
  - The right reference for the comparison is **`CF_Clu_VehicleSpeed`**
    (cluster's own displayed speed, ~+5 % above wheel-avg, also affected by
    tire diameter), not wheel-average. The cluster and the camera reason in
    cluster-speed units.
  - `CF_Clu_VehicleSpeed` lives in **`CLU15` (`0x52A`)**, byte 0, 8-bit km/h.
    NOT in `CLU11` as I initially assumed.
  - Re-analysis on cluster speed perfectly explains the earlier "456.62
    anomaly": at that moment wheel-avg was 19.6 km/h but cluster-speed was
    22-23 km/h — so the camera was working from cluster's view (driver had
    been over the 20 limit for ~6 s), which matches the bit-4 fire.
  - 7 over-speed intervals in the window (4 in 20-zone, 3 in 40-zone).
    Cross-tabulated with **driver's precise per-km/h notes** ("blinked at
    X, beeped at Y") and `0x4EC` bit-4 fires — **bit-4 fired exactly when
    the driver reported a beep, and stayed off exactly when the driver
    reported "blink only" or "red flash, no sound"**:

    | event              | Δ (clu) | dur   | bit `0x10` | driver report |
    |---|---|---|---|---|
    | 399.5-412.3 (20)   | +8 (peak 28) | 12.7 s | yes @403  | blink at 25, beep at 26 |
    | 425.4-434.7 (20)   | +5 (peak 25) |  9.3 s | yes @430  | blink at 23, beep at 24 |
    | 442.5-447.2 (20)   | +2 (peak 22) |  4.7 s | no        | blink only at 21-22, no sound |
    | 451.2-457.9 (20)   | +3 (peak 23) |  6.6 s | yes @457  | blink AND beep at 23 |
    | 498.9-500.5 (40)   | +2 (peak 42) |  1.7 s | no        | (40 zone, brief) |
    | 504.8-507.1 (40)   | +3 (peak 43) |  2.4 s | no        | (40 zone, brief) |
    | **524.5-531.6 (40)** | **+8 (peak 48)** | **7.1 s** | **NO** | **"red flashing only, no sound"** |

  - **H3' definitively confirmed.** Camera sends the over-speed audible alert
    via `0x4EC` byte 4 bit 4. Red-ring is cluster-local, independent.
  - Camera's RU-coded threshold under observation (driver-noted: behavior is
    primarily **duration-driven**, with a small entry threshold on Δ):
    - 20-zone fire delays from entry to bit-4: 3.7 s, 4.4 s, 5.4 s. Event
      that did NOT fire was only 4.7 s long with peak +2 — short and barely
      over.
    - 40-zone: no fire even at +8 for 7.1 s. Either the duration timer is
      much longer in 40-zone, or the Δ entry threshold is higher.
    - Working model: camera runs an internal timer while
      `cluster_speed > limit + zone_threshold`; after `zone_timer` seconds
      of continuous excess it sets bit `0x10`. `zone_threshold` and
      `zone_timer` are both small for 20-zone and substantially larger for
      40-zone.
  - **Filter spec (now actionable):**
    ```
    on every 0x4EC bus 2 frame:
      if cluster_speed > displayed_limit + user_offset:
        force  byte4 |= 0x10   # we want sound
      else:
        clear  byte4 &= ~0x10  # silence camera's own decision
      # no checksum / counter — bytes 0,1,2,5,6,7 are always 0x00 (round 3
      # analysis: 10495 frames across two recordings)
    ```
    Inputs:
    - `cluster_speed` from `CLU15` (`0x52A`) byte 0
    - `displayed_limit` from `0x53E` byte 3 (or 4)
    - `user_offset` — signed int km/h from a Param UI control (e.g. -10..+10,
      default 0 = alert on any over-speed)
    Bit `0x20` (displayed-limit-value-changed pulse) is untouched. Red-ring is unaffected
    (cluster-local).

- Round 3 (2026-05-29) — checksum/counter analysis of `0x4EC`:
  - Examined 10 495 frames of `0x4EC` across both recordings.
  - Bytes 0, 1, 2, 5, 6, 7 are constant `0x00` in every frame. Only bytes 3
    and 4 carry information (TSR_Speed_Limit at byte 3; TSR_OverSpeedLimitWarn
    at byte4 bit4; TSR_SpeedLimitChanged at byte4 bit5 — defined in BO_ 1260
    CAM_TSR_State of `hyundai_palisade_2023_generated.dbc`).
  - **There is no checksum and no counter** in this message. Rewriting byte
    4 and forwarding the frame is sufficient — the cluster does not validate
    `0x4EC` structurally.
  - Frame rate ≈ 10 Hz; each frame appears twice in the log (panda rx + tx
    capture or two-bus echo) — a normal artifact, irrelevant to the filter.
