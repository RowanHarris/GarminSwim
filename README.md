# GarminSwim (Garmin Venu 3 Connect IQ Apps)

Two standalone Garmin Connect IQ Watch Apps in Monkey C targeting the **Garmin Venu 3** (`venu3`, 454×454 AMOLED), engineered for underwater goggle legibility, zero touchscreen splash interference, and multi-signal phantom-lap filtering.

## Apps Included

### 1. CleanSwim (`/`)
A high-contrast, minimalist replacement for the built-in Pool Swim app.

- **Display:** Pure white typography on pure black (`Graphics.COLOR_BLACK`) with 3 vertically stacked metrics: **Total Distance (`m`)**, **Active Elapsed Time**, and **Average Pace (`/100m`)**. An amber outer bezel ring indicates when recording is stopped (initial Ready or Paused) and disappears while actively swimming.
- **Multi-Signal Phantom-Lap Filter (`source/SwimSanityFilter.mc`):**
  - Hard single-lap floor (`28s` for 50m pools; `14s` for 25m pools — configure `POOL_LENGTH_METERS` at the top of `SwimSanityFilter.mc`).
  - Rolling 4-lap median baseline with `0.70×` relative drop gate.
  - Heart-rate delta confirmation (`lapPeakHR >= prevLapAvgHR + 8 bpm`, or post-rest lap).
  - Compass heading reversal check (`135° <= deltaHeading <= 225°`, same-direction `< 90°` rejected).
  - Mid-lane split absorption (`STATE_PENDING_MERGE`) and `< 10s` wall double-tap glitch discard.
- **Physical Button Controls (touchscreen ignored underwater):**
  - **Top-Right (`KEY_ENTER`):** Start → Pause → Pause menu (`Resume` / `Save` / `Discard` with *"Are you sure?"* confirmation / `Undo Lap (-1)`).
  - **Bottom-Right (`KEY_ESC`):** Exit when Ready; short press = `+1` lap, hold (~0.7s) = `-1` lap during workout.
- **Developer FIT Fields (`MESG_TYPE_SESSION`):** `clean_distance`, `clean_laps`, `clean_avg_pace`.

### 2. HIIT Swim (`HIITSwim/`)
A standalone guided high-intensity pool interval watch app replicating structured swim intervals on the Venu 3 (which lacks native Garmin Connect structured pool swim workouts).

- **Workout Flow (linear Top-Right `KEY_ENTER` progression):**
  1. **Warm-up** *(open swim)* — Tracks warm-up distance, laps (via `SwimSanityFilter` + Bottom-Right `+1`/`-1`), and time.
  2. **4 × [4-Lap Fast Swim → 1:1 Equal-Time Stationary Rest]:**
     - **Fast (`FAST 1/4`..`4/4`):** Shows a **3:00 reference countdown** (`03:00 → 00:00`, then `+00:01` overtime) + **live Heart Rate**. Does **not** auto-end at `00:00`—press **Top-Right** after completing your 4 fast laps to log exact `4 laps` (`200 m`) and lock in an equal rest timer.
     - **Rest (`REST 1/4`..`4/4`, orange bezel ring):** Stationary 1:1 countdown matching the exact duration of the Fast swim you just completed + **live Heart Rate** (with 3-2-1 haptic pulses before auto-advancing to the next Fast swim; press Top-Right anytime to advance early, including stopping `REST 4/4` early to enter Cool-down).
  3. **Cool-down** *(open swim)* — Tracks cool-down distance, laps, and time. Press **Top-Right** when finished to open **Save / Discard** (with *"Are you sure?"* confirmation on Discard) / **More Cool-down**.
- **FIT Recording:** Records continuously as a standard Pool Swim (`SPORT_SWIMMING` / `SUB_SPORT_LAP_SWIMMING`, named `"HIIT Swim"`) to capture your full heart-rate recovery curve during rests, emits `session.addLap()` at every stage boundary, and writes session (`clean_distance`, `clean_laps`, `clean_avg_pace`) and per-stage lap (`stage_distance`, `stage_laps`) FIT fields.

## Building & Testing

Requires the **Garmin Connect IQ SDK** (with the `venu3` device profile downloaded via Connect IQ SDK Manager) and a local developer signing key (`developer_key.der`, excluded from git):

```bash
# One-time signing key generation (not tracked in git)
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt

# Build CleanSwim for Venu 3 (strict type checking + warnings)
monkeyc -d venu3 -f monkey.jungle -o bin/CleanSwim.prg -y developer_key.der -l 3 -O 2 -w

# Build HIIT Swim for Venu 3
monkeyc -d venu3 -f HIITSwim/monkey.jungle -o HIITSwim/bin/HIITSwim.prg -y developer_key.der -l 3 -O 2 -w

# Compile unit tests (-t)
monkeyc -t -d venu3 -f monkey.jungle -o bin/CleanSwim-test.prg -y developer_key.der -l 3 -w
monkeyc -t -d venu3 -f HIITSwim/monkey.jungle -o HIITSwim/bin/HIITSwim-test.prg -y developer_key.der -l 3 -w
```
