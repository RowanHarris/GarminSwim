import Toybox.Lang;
import Toybox.Math;

//! Pure, unit-testable workout state machine for Venu 3 HIIT Swim.
//!
//! Structure:
//!   READY -> WARM-UP (open swim, logs laps)
//!         -> 4x [ FAST (4 laps, 3:00 reference countdown, manual Top-Right finish)
//!                 -> REST (1:1 equal-time stationary countdown matching exact Fast duration) ]
//!         -> COOL-DOWN (open swim, logs laps)
//!         -> COMPLETE (opens Save / Discard menu with confirmation)
//!
//! Top-Right button cleanly advances through every stage.
//! Fast intervals NEVER auto-end at 0:00; they count overtime (+00:01...) until
//! Top-Right is pressed after completing the 4 fast laps, logging exact 4-lap
//! distance and setting the following Rest countdown equal to the exact Fast time.
class HIITWorkoutEngine {

    // -------------------------------------------------------------------------
    // Configurable Workout Constants
    // -------------------------------------------------------------------------

    //! Target laps per Fast interval (4 laps x 50m = 200m).
    public static const FAST_TARGET_LAPS as Number = 4;

    //! Reference countdown duration shown during each Fast swim (3:00 = 180s).
    //! The Fast stage continues past 0:00 until Top-Right is pressed.
    public static const FAST_COUNTDOWN_TARGET_SEC as Number = 180;

    //! Number of Fast + Rest cycles.
    public static const TOTAL_CYCLES as Number = 4;

    //! Minimum rest countdown floor (ms) to keep quick dry-land testing clean.
    public static const MIN_REST_DURATION_MS as Number = 1000;

    // -------------------------------------------------------------------------
    // Stage Constants
    // -------------------------------------------------------------------------

    public static const STAGE_READY as Number = 0;
    public static const STAGE_WARMUP as Number = 1;
    public static const STAGE_FAST as Number = 2;
    public static const STAGE_REST as Number = 3;
    public static const STAGE_COOLDOWN as Number = 4;
    public static const STAGE_COMPLETE as Number = 5;

    // -------------------------------------------------------------------------
    // Tick Notification Constants
    // -------------------------------------------------------------------------

    public static const TICK_NONE as Number = 0;
    public static const TICK_FAST_TARGET_REACHED as Number = 1;
    public static const TICK_REST_COUNTDOWN_PULSE as Number = 2;
    public static const TICK_REST_FINISHED_NEXT_FAST as Number = 3;
    public static const TICK_REST_FINISHED_COOLDOWN as Number = 4;

    // -------------------------------------------------------------------------
    // Instance State
    // -------------------------------------------------------------------------

    private var _poolLengthMeters as Number;
    private var _stage as Number;
    private var _cycleIndex as Number; // 1..TOTAL_CYCLES during FAST / REST

    private var _stageElapsedMs as Number;
    private var _totalElapsedMs as Number;
    private var _warmupElapsedMs as Number;
    private var _totalFastSwimMs as Number;
    private var _cooldownElapsedMs as Number;

    private var _currentRestTargetMs as Number;
    private var _fastTargetAlertFired as Boolean;
    private var _lastRestCountdownSec as Number;

    private var _warmupLaps as Number;
    private var _completedFastLaps as Number;
    private var _cooldownLaps as Number;

    // Snapshot of the most recently completed stage (for MESG_TYPE_LAP FIT fields)
    private var _lastCompletedStageLaps as Number;
    private var _lastCompletedStageDistance as Number;

    public function initialize(poolLengthMeters as Number) {
        _poolLengthMeters = poolLengthMeters;
        _stage = STAGE_READY;
        _cycleIndex = 0;

        _stageElapsedMs = 0;
        _totalElapsedMs = 0;
        _warmupElapsedMs = 0;
        _totalFastSwimMs = 0;
        _cooldownElapsedMs = 0;

        _currentRestTargetMs = FAST_COUNTDOWN_TARGET_SEC * 1000;
        _fastTargetAlertFired = false;
        _lastRestCountdownSec = -1;

        _warmupLaps = 0;
        _completedFastLaps = 0;
        _cooldownLaps = 0;

        _lastCompletedStageLaps = 0;
        _lastCompletedStageDistance = 0;
    }

    public function reset() as Void {
        _stage = STAGE_READY;
        _cycleIndex = 0;

        _stageElapsedMs = 0;
        _totalElapsedMs = 0;
        _warmupElapsedMs = 0;
        _totalFastSwimMs = 0;
        _cooldownElapsedMs = 0;

        _currentRestTargetMs = FAST_COUNTDOWN_TARGET_SEC * 1000;
        _fastTargetAlertFired = false;
        _lastRestCountdownSec = -1;

        _warmupLaps = 0;
        _completedFastLaps = 0;
        _cooldownLaps = 0;

        _lastCompletedStageLaps = 0;
        _lastCompletedStageDistance = 0;
    }

    // -------------------------------------------------------------------------
    // Stage Transitions (Top-Right Button & Rest Completion)
    // -------------------------------------------------------------------------

    //! Advance cleanly to the next linear workout stage on Top-Right button press.
    //! Returns the newly active STAGE_* constant.
    public function advanceStage() as Number {
        if (_stage == STAGE_READY) {
            _stage = STAGE_WARMUP;
            _cycleIndex = 0;
            _stageElapsedMs = 0;
            return _stage;
        }

        if (_stage == STAGE_WARMUP) {
            _warmupElapsedMs += _stageElapsedMs;
            _lastCompletedStageLaps = _warmupLaps;
            _lastCompletedStageDistance = _warmupLaps * _poolLengthMeters;

            enterFastStage(1);
            return _stage;
        }

        if (_stage == STAGE_FAST) {
            var fastDurMs = _stageElapsedMs;
            _totalFastSwimMs += fastDurMs;
            _completedFastLaps += FAST_TARGET_LAPS;
            _lastCompletedStageLaps = FAST_TARGET_LAPS;
            _lastCompletedStageDistance = FAST_TARGET_LAPS * _poolLengthMeters;

            enterRestStage(_cycleIndex, fastDurMs);
            return _stage;
        }

        if (_stage == STAGE_REST) {
            _lastCompletedStageLaps = 0;
            _lastCompletedStageDistance = 0;

            if (_cycleIndex < TOTAL_CYCLES) {
                enterFastStage(_cycleIndex + 1);
            } else {
                enterCooldownStage();
            }
            return _stage;
        }

        if (_stage == STAGE_COOLDOWN) {
            _cooldownElapsedMs += _stageElapsedMs;
            _lastCompletedStageLaps = _cooldownLaps;
            _lastCompletedStageDistance = _cooldownLaps * _poolLengthMeters;

            _stage = STAGE_COMPLETE;
            _stageElapsedMs = 0;
            return _stage;
        }

        return _stage;
    }

    //! Re-enter swimming cool-down from the completion screen if the user wants more cool-down laps.
    public function resumeCooldown() as Void {
        if (_stage == STAGE_COMPLETE) {
            _stage = STAGE_COOLDOWN;
            _stageElapsedMs = 0;
        }
    }

    //! Advance timers by deltaMs and trigger countdown / rest-completion notifications.
    public function tick(deltaMs as Number) as Number {
        if (deltaMs <= 0 || _stage == STAGE_READY || _stage == STAGE_COMPLETE) {
            return TICK_NONE;
        }

        _stageElapsedMs += deltaMs;
        _totalElapsedMs += deltaMs;

        if (_stage == STAGE_FAST) {
            var targetMs = FAST_COUNTDOWN_TARGET_SEC * 1000;
            if (!_fastTargetAlertFired && _stageElapsedMs >= targetMs) {
                _fastTargetAlertFired = true;
                return TICK_FAST_TARGET_REACHED;
            }
            return TICK_NONE;
        }

        if (_stage == STAGE_REST) {
            var remainingMs = _currentRestTargetMs - _stageElapsedMs;
            if (remainingMs <= 0) {
                _lastCompletedStageLaps = 0;
                _lastCompletedStageDistance = 0;

                if (_cycleIndex < TOTAL_CYCLES) {
                    enterFastStage(_cycleIndex + 1);
                    return TICK_REST_FINISHED_NEXT_FAST;
                } else {
                    enterCooldownStage();
                    return TICK_REST_FINISHED_COOLDOWN;
                }
            }

            // Fire crisp 3-2-1 haptic pulses in the final 3 seconds of stationary rest
            var remainingWholeSec = Math.ceil(remainingMs.toFloat() / 1000.0).toNumber();
            if (remainingWholeSec >= 1 && remainingWholeSec <= 3 && remainingWholeSec != _lastRestCountdownSec) {
                _lastRestCountdownSec = remainingWholeSec;
                return TICK_REST_COUNTDOWN_PULSE;
            }
        }

        return TICK_NONE;
    }

    // -------------------------------------------------------------------------
    // Lap Count Sync (Warm-up & Cool-down via SwimSanityFilter + Manual Override)
    // -------------------------------------------------------------------------

    //! Synchronize valid lap count from SwimSanityFilter during Warm-up or Cool-down.
    public function setActiveOpenStageLaps(validLaps as Number) as Void {
        if (validLaps < 0) {
            validLaps = 0;
        }
        if (_stage == STAGE_WARMUP) {
            _warmupLaps = validLaps;
        } else if (_stage == STAGE_COOLDOWN) {
            _cooldownLaps = validLaps;
        }
    }

    // -------------------------------------------------------------------------
    // Internal Stage Initializers
    // -------------------------------------------------------------------------

    private function enterFastStage(cycleNum as Number) as Void {
        _stage = STAGE_FAST;
        _cycleIndex = cycleNum;
        _stageElapsedMs = 0;
        _fastTargetAlertFired = false;
    }

    private function enterRestStage(cycleNum as Number, fastDurationMs as Number) as Void {
        _stage = STAGE_REST;
        _cycleIndex = cycleNum;
        _stageElapsedMs = 0;
        _currentRestTargetMs = (fastDurationMs < MIN_REST_DURATION_MS) ? MIN_REST_DURATION_MS : fastDurationMs;
        _lastRestCountdownSec = -1;
    }

    private function enterCooldownStage() as Void {
        _stage = STAGE_COOLDOWN;
        _stageElapsedMs = 0;
    }

    // -------------------------------------------------------------------------
    // Public Getters & Derived Metrics
    // -------------------------------------------------------------------------

    public function getStage() as Number {
        return _stage;
    }

    public function getCycleIndex() as Number {
        return _cycleIndex;
    }

    public function getPoolLengthMeters() as Number {
        return _poolLengthMeters;
    }

    //! True when recording is halted (Ready on launch or Complete) or stationary Rest.
    public function shouldShowOrangeRing() as Boolean {
        return (_stage == STAGE_READY) || (_stage == STAGE_REST) || (_stage == STAGE_COMPLETE);
    }

    //! True during open swimming stages where SwimSanityFilter actively tracks laps.
    public function isOpenSwimStage() as Boolean {
        return (_stage == STAGE_WARMUP) || (_stage == STAGE_COOLDOWN);
    }

    //! Short stage header text rendered at top of Venu 3 display.
    public function getStageLabel() as String {
        if (_stage == STAGE_READY || _stage == STAGE_WARMUP) {
            return "WARM-UP";
        }
        if (_stage == STAGE_FAST) {
            return "FAST " + _cycleIndex.format("%d") + "/" + TOTAL_CYCLES.format("%d");
        }
        if (_stage == STAGE_REST) {
            return "REST " + _cycleIndex.format("%d") + "/" + TOTAL_CYCLES.format("%d");
        }
        if (_stage == STAGE_COOLDOWN) {
            return "COOL-DOWN";
        }
        return "DONE";
    }

    public function getStageElapsedSeconds() as Float {
        return _stageElapsedMs.toFloat() / 1000.0;
    }

    public function getTotalElapsedSeconds() as Float {
        return _totalElapsedMs.toFloat() / 1000.0;
    }

    //! Warm-up elapsed seconds (live while in Warm-up).
    public function getWarmupElapsedSeconds() as Float {
        var ms = _warmupElapsedMs + ((_stage == STAGE_WARMUP) ? _stageElapsedMs : 0);
        return ms.toFloat() / 1000.0;
    }

    //! Cool-down elapsed seconds (live while in Cool-down).
    public function getCooldownElapsedSeconds() as Float {
        var ms = _cooldownElapsedMs + ((_stage == STAGE_COOLDOWN) ? _stageElapsedMs : 0);
        return ms.toFloat() / 1000.0;
    }

    //! Remaining seconds for the 3:00 Fast reference countdown.
    //! Positive while <= 3:00; negative when overtime past 3:00 (e.g. -30.0 for +00:30).
    public function getFastCountdownSeconds() as Float {
        return FAST_COUNTDOWN_TARGET_SEC.toFloat() - (_stageElapsedMs.toFloat() / 1000.0);
    }

    //! Remaining seconds for the 1:1 equal-time stationary Rest countdown (clamped >= 0.0).
    public function getRestRemainingSeconds() as Float {
        var remainingMs = _currentRestTargetMs - _stageElapsedMs;
        if (remainingMs <= 0) {
            return 0.0;
        }
        return remainingMs.toFloat() / 1000.0;
    }

    public function getCurrentRestTargetMs() as Number {
        return _currentRestTargetMs;
    }

    public function getWarmupLaps() as Number {
        return _warmupLaps;
    }

    public function getCompletedFastLaps() as Number {
        return _completedFastLaps;
    }

    public function getCooldownLaps() as Number {
        return _cooldownLaps;
    }

    public function getCurrentStageLaps() as Number {
        if (_stage == STAGE_WARMUP) {
            return _warmupLaps;
        }
        if (_stage == STAGE_FAST) {
            return FAST_TARGET_LAPS;
        }
        if (_stage == STAGE_COOLDOWN) {
            return _cooldownLaps;
        }
        return 0;
    }

    public function getCurrentStageDistanceMeters() as Number {
        return getCurrentStageLaps() * _poolLengthMeters;
    }

    public function getTotalValidLaps() as Number {
        return _warmupLaps + _completedFastLaps + _cooldownLaps;
    }

    public function getTotalValidDistanceMeters() as Number {
        return getTotalValidLaps() * _poolLengthMeters;
    }

    //! Active swimming seconds across Warm-up + Fast intervals + Cool-down (excludes stationary Rests).
    public function getTotalActiveSwimSeconds() as Float {
        var ms = _warmupElapsedMs + _totalFastSwimMs + _cooldownElapsedMs;
        if (_stage == STAGE_WARMUP || _stage == STAGE_FAST || _stage == STAGE_COOLDOWN) {
            ms += _stageElapsedMs;
        }
        return ms.toFloat() / 1000.0;
    }

    public function getCleanAvgSwimPaceSecPer100m() as Float {
        return SwimSanityFilter.computePaceSecPer100m(
            getTotalActiveSwimSeconds(),
            getTotalValidDistanceMeters()
        );
    }

    public function getLastCompletedStageLaps() as Number {
        return _lastCompletedStageLaps;
    }

    public function getLastCompletedStageDistanceMeters() as Number {
        return _lastCompletedStageDistance;
    }
}
