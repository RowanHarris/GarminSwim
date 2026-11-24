import Toybox.Lang;
import Toybox.Math;

//! Multi-signal phantom-lap filter for Garmin pool swimming.
//!
//! Evaluates every incoming native lap event through a two-state machine
//! (STATE_SWIMMING / STATE_PENDING_MERGE) using:
//!   1. Rolling 4-lap median baseline + hard minimum lap floor + 0.70 ratio gate
//!   2. Heart rate delta confirmation (+8 bpm peak over prior lap avg, or post-rest)
//!   3. Compass heading reversal verification (135 deg <= delta <= 225 deg)
//!   4. Mid-lane split merge/absorb and < 10s wall double-tap glitch discard
class SwimSanityFilter {

    // -------------------------------------------------------------------------
    // Pool & Filter Configuration Constants
    // -------------------------------------------------------------------------

    //! Pool length in meters.
    //! To switch to a 25m short-course pool, change this constant to 25
    //! (the hard minimum lap floor automatically switches from 28s to 14s).
    public static const POOL_LENGTH_METERS as Number = 50;

    //! Hard minimum valid single-lap durations (seconds) by pool length.
    public static const MIN_VALID_LAP_SEC_50M as Float = 28.0;
    public static const MIN_VALID_LAP_SEC_25M as Float = 14.0;

    //! Rolling window size for baseline median lap duration.
    public static const ROLLING_WINDOW_SIZE as Number = 4;

    //! Relative drop ratio threshold: laps faster than 70% of rolling median are suspicious.
    public static const RELATIVE_DROP_RATIO as Float = 0.70;

    //! Minimum peak HR increase (bpm) above prior lap average to confirm a legitimate sprint.
    public static const HR_SPRINT_DELTA_BPM as Float = 8.0;

    //! Compass heading thresholds (degrees).
    public static const HEADING_REVERSAL_MIN_DEG as Float = 135.0;
    public static const HEADING_REVERSAL_MAX_DEG as Float = 225.0;
    public static const HEADING_SAME_DIR_MAX_DEG as Float = 90.0;

    //! Wall double-tap glitch rejection window (seconds) immediately after a committed lap.
    public static const DOUBLE_TAP_GLITCH_SEC as Float = 10.0;

    // -------------------------------------------------------------------------
    // State Machine & Evaluation Result Constants
    // -------------------------------------------------------------------------

    public static const STATE_SWIMMING as Number = 0;
    public static const STATE_PENDING_MERGE as Number = 1;

    public static const RESULT_ACCEPTED as Number = 0;
    public static const RESULT_MERGED_ACCEPTED as Number = 1;
    public static const RESULT_PENDING_MERGE as Number = 2;
    public static const RESULT_DISCARDED_DOUBLE_TAP as Number = 3;
    public static const RESULT_IGNORED_PAUSED as Number = 4;

    // -------------------------------------------------------------------------
    // Instance State
    // -------------------------------------------------------------------------

    private var _poolLengthMeters as Number;
    private var _minValidLapSec as Float;

    private var _state as Number;
    private var _validLaps as Number;
    private var _filteredPhantomCount as Number;

    private var _recentLapDurations as Array<Float>;
    private var _pendingDurationSec as Float;

    private var _lapStartHeadingDeg as Float?;

    private var _lapHrSum as Number;
    private var _lapHrCount as Number;
    private var _lapPeakHR as Number;
    private var _prevLapAvgHR as Float?;

    private var _isPaused as Boolean;
    private var _isPostRestLap as Boolean;
    private var _justCommittedValidLap as Boolean;
    private var _discardedSinceCommitSec as Float;

    //! Construct a SwimSanityFilter using the given pool length (meters).
    //! Pass SwimSanityFilter.POOL_LENGTH_METERS in production; pass 25 or 50 in tests.
    public function initialize(poolLengthMeters as Number) {
        _poolLengthMeters = poolLengthMeters;
        _minValidLapSec = SwimSanityFilter.minValidLapForPoolLength(poolLengthMeters);

        _state = STATE_SWIMMING;
        _validLaps = 0;
        _filteredPhantomCount = 0;

        _recentLapDurations = [] as Array<Float>;
        _pendingDurationSec = 0.0;

        _lapStartHeadingDeg = null;

        _lapHrSum = 0;
        _lapHrCount = 0;
        _lapPeakHR = 0;
        _prevLapAvgHR = null;

        _isPaused = false;
        _isPostRestLap = false;
        _justCommittedValidLap = false;
        _discardedSinceCommitSec = 0.0;
    }

    //! Reset all filter state for a fresh swim session.
    public function reset() as Void {
        _state = STATE_SWIMMING;
        _validLaps = 0;
        _filteredPhantomCount = 0;

        _recentLapDurations = [] as Array<Float>;
        _pendingDurationSec = 0.0;

        _lapStartHeadingDeg = null;

        _lapHrSum = 0;
        _lapHrCount = 0;
        _lapPeakHR = 0;
        _prevLapAvgHR = null;

        _isPaused = false;
        _isPostRestLap = false;
        _justCommittedValidLap = false;
        _discardedSinceCommitSec = 0.0;
    }

    // -------------------------------------------------------------------------
    // Pure, Unit-Testable Static Helper Methods
    // -------------------------------------------------------------------------

    //! Returns the hard minimum single-lap duration in seconds for a pool length.
    //! Default: 28s for 50m pools, 14s for 25m pools.
    public static function minValidLapForPoolLength(poolLengthMeters as Number) as Float {
        if (poolLengthMeters <= 25) {
            return MIN_VALID_LAP_SEC_25M;
        }
        return MIN_VALID_LAP_SEC_50M;
    }

    //! Converts a heading in radians (Sensor.Info.heading) to normalized degrees in [0, 360).
    public static function radiansToDegrees(radians as Float) as Float {
        var piFloat = Math.PI.toFloat();
        var deg = (radians * 180.0) / piFloat;
        while (deg < 0.0) {
            deg += 360.0;
        }
        while (deg >= 360.0) {
            deg -= 360.0;
        }
        return deg;
    }

    //! Computes the shortest angular difference in degrees [0, 180] between two headings.
    public static function computeDeltaHeading(headingADeg as Float, headingBDeg as Float) as Float {
        var diff = headingADeg - headingBDeg;
        if (diff < 0.0) {
            diff = -diff;
        }
        while (diff >= 360.0) {
            diff -= 360.0;
        }
        if (diff > 180.0) {
            diff = 360.0 - diff;
        }
        return diff;
    }

    //! Returns true when deltaHeading indicates a legitimate wall turn (~180 deg reversal).
    public static function isHeadingReversal(deltaHeadingDeg as Float) as Boolean {
        return (deltaHeadingDeg >= HEADING_REVERSAL_MIN_DEG) &&
               (deltaHeadingDeg <= HEADING_REVERSAL_MAX_DEG);
    }

    //! Returns true when deltaHeading indicates continued same-direction travel (mid-lane false trigger).
    public static function isSameDirection(deltaHeadingDeg as Float) as Boolean {
        return deltaHeadingDeg < HEADING_SAME_DIR_MAX_DEG;
    }

    //! Computes the median of a non-empty Float array without mutating the input array.
    //! Returns null if the array is empty.
    public static function computeMedian(values as Array<Float>) as Float? {
        var n = values.size();
        if (n == 0) {
            return null;
        }

        // Copy and insertion-sort (max 4 items in rolling window)
        var sorted = [] as Array<Float>;
        for (var i = 0; i < n; i++) {
            sorted.add(values[i]);
        }

        for (var i = 1; i < n; i++) {
            var key = sorted[i];
            var j = i - 1;
            while (j >= 0 && sorted[j] > key) {
                sorted[j + 1] = sorted[j];
                j--;
            }
            sorted[j + 1] = key;
        }

        var mid = n / 2;
        if ((n % 2) == 1) {
            return sorted[mid];
        }
        return (sorted[mid - 1] + sorted[mid]) / 2.0;
    }

    //! Calculates average pace in seconds per 100m. Returns 0.0 when distance is zero.
    public static function computePaceSecPer100m(totalActiveSeconds as Float, validDistanceMeters as Number) as Float {
        if (validDistanceMeters <= 0 || totalActiveSeconds <= 0.0) {
            return 0.0;
        }
        return (totalActiveSeconds / validDistanceMeters.toFloat()) * 100.0;
    }

    // -------------------------------------------------------------------------
    // Lifecycle & Sensor Sampling
    // -------------------------------------------------------------------------

    //! Suspend phantom-lap evaluation during a manual rest/pause interval.
    //! Marks the next lap after resuming as post-rest so fast sprint starts are allowed.
    public function onPause() as Void {
        _isPaused = true;
        _isPostRestLap = true;
        _state = STATE_SWIMMING;
        _pendingDurationSec = 0.0;
        _justCommittedValidLap = false;
        _discardedSinceCommitSec = 0.0;
        _lapStartHeadingDeg = null;
        resetCurrentLapHeartRate();
    }

    //! Resume phantom-lap evaluation after a pause/rest interval.
    public function onResume(currentHeadingRad as Float?) as Void {
        _isPaused = false;
        _justCommittedValidLap = false;
        _discardedSinceCommitSec = 0.0;
        if (currentHeadingRad != null) {
            _lapStartHeadingDeg = SwimSanityFilter.radiansToDegrees(currentHeadingRad);
        } else {
            _lapStartHeadingDeg = null;
        }
    }

    //! Record a live heart rate sample (bpm) during the active lap.
    public function recordHeartRateSample(heartRate as Number?) as Void {
        if (_isPaused || heartRate == null || heartRate <= 0) {
            return;
        }
        _lapHrSum += heartRate;
        _lapHrCount += 1;
        if (heartRate > _lapPeakHR) {
            _lapPeakHR = heartRate;
        }
    }

    //! Record a live heading sample (radians from Sensor.Info.heading).
    //! Captures lapStartHeading automatically if it has not been anchored yet for the current lap.
    public function recordHeadingSample(headingRad as Float?) as Void {
        if (_isPaused || headingRad == null) {
            return;
        }
        if (_lapStartHeadingDeg == null && _state == STATE_SWIMMING) {
            _lapStartHeadingDeg = SwimSanityFilter.radiansToDegrees(headingRad);
        }
    }

    //! Explicitly anchor lapStartHeading in degrees [0, 360) (useful for initialization & unit tests).
    public function setLapStartHeadingDegrees(headingDeg as Float?) as Void {
        if (headingDeg == null) {
            _lapStartHeadingDeg = null;
            return;
        }
        var normalized = headingDeg;
        while (normalized < 0.0) {
            normalized += 360.0;
        }
        while (normalized >= 360.0) {
            normalized -= 360.0;
        }
        _lapStartHeadingDeg = normalized;
    }

    // -------------------------------------------------------------------------
    // Core Evaluation Helpers (Unit-Testable)
    // -------------------------------------------------------------------------

    //! Check 1a: Hard minimum lap duration floor.
    public function passesHardFloor(durationSec as Float) as Boolean {
        return durationSec >= _minValidLapSec;
    }

    //! Check 1b: Relative drop gate (< 0.70 * rollingMedianSeconds).
    public function isSuspiciouslyFast(durationSec as Float) as Boolean {
        var median = getRollingMedianSeconds();
        if (median == null) {
            return false;
        }
        return durationSec < (RELATIVE_DROP_RATIO * median);
    }

    //! Check 2: Heart rate delta confirmation for suspiciously fast laps.
    //! Accepted only if lapPeakHR >= (prevLapAvgHR + 8 bpm) OR first lap after pause/rest.
    public function isHeartRateSprintConfirmed() as Boolean {
        if (_isPostRestLap) {
            return true;
        }
        var prevAvgHR = _prevLapAvgHR;
        if (_lapHrCount <= 0 || prevAvgHR == null) {
            return false;
        }
        return _lapPeakHR.toFloat() >= (prevAvgHR + HR_SPRINT_DELTA_BPM);
    }

    //! Check 3: Compass heading reversal verification against lapStartHeading.
    //! Returns true when deltaHeading is within [135 deg, 225 deg].
    //! Degrades gracefully to true when compass heading is unavailable (null).
    public function isHeadingValidated(currentHeadingDeg as Float?) as Boolean {
        var startHeadingDeg = _lapStartHeadingDeg;
        if (startHeadingDeg == null || currentHeadingDeg == null) {
            return true;
        }
        var delta = SwimSanityFilter.computeDeltaHeading(currentHeadingDeg, startHeadingDeg);
        if (SwimSanityFilter.isSameDirection(delta)) {
            return false;
        }
        return SwimSanityFilter.isHeadingReversal(delta);
    }

    // -------------------------------------------------------------------------
    // Native Lap Interception & State Machine
    // -------------------------------------------------------------------------

    //! Intercept and evaluate an incoming native lap event.
    //!
    //! @param lapDurationSec    Elapsed active seconds since the previous native lap event.
    //! @param currentHeadingRad Current Sensor.Info.heading in radians (or null if unavailable).
    //! @return One of RESULT_ACCEPTED, RESULT_MERGED_ACCEPTED, RESULT_PENDING_MERGE,
    //!         RESULT_DISCARDED_DOUBLE_TAP, or RESULT_IGNORED_PAUSED.
    public function onNativeLapEvent(lapDurationSec as Float, currentHeadingRad as Float?) as Number {
        if (_isPaused) {
            return RESULT_IGNORED_PAUSED;
        }

        var currentHeadingDeg = null;
        if (currentHeadingRad != null) {
            currentHeadingDeg = SwimSanityFilter.radiansToDegrees(currentHeadingRad);
        }

        // 4b. Wall Double-Tap Glitch Rejection:
        // Discard any lap event firing < 10s immediately after a just-committed valid lap.
        if (_state == STATE_SWIMMING && _justCommittedValidLap) {
            if ((_discardedSinceCommitSec + lapDurationSec) < DOUBLE_TAP_GLITCH_SEC) {
                _discardedSinceCommitSec += lapDurationSec;
                _filteredPhantomCount += 1;
                return RESULT_DISCARDED_DOUBLE_TAP;
            }
            _justCommittedValidLap = false;
            _discardedSinceCommitSec = 0.0;
        }

        var wasPendingMerge = (_state == STATE_PENDING_MERGE);
        var candidateDuration = wasPendingMerge ? (_pendingDurationSec + lapDurationSec) : lapDurationSec;

        if (evaluateCandidateLap(candidateDuration, currentHeadingDeg)) {
            commitValidLap(candidateDuration, currentHeadingDeg);
            return wasPendingMerge ? RESULT_MERGED_ACCEPTED : RESULT_ACCEPTED;
        }

        // 4a. Mid-Lane Split -> Enter or stay in STATE_PENDING_MERGE.
        // Do not increment validLaps; preserve original lapStartHeading and lap HR stats.
        _state = STATE_PENDING_MERGE;
        _pendingDurationSec = candidateDuration;
        _filteredPhantomCount += 1;
        return RESULT_PENDING_MERGE;
    }

    //! Evaluates all three sanity checks (time floor/ratio, HR delta, compass reversal).
    private function evaluateCandidateLap(candidateDuration as Float, currentHeadingDeg as Float?) as Boolean {
        // Check 1a: Hard floor (28s for 50m pool, 14s for 25m pool)
        if (!passesHardFloor(candidateDuration)) {
            return false;
        }

        // Check 3: Compass heading reversal (135 deg <= deltaHeading <= 225 deg)
        if (!isHeadingValidated(currentHeadingDeg)) {
            return false;
        }

        // Check 1b + Check 2: Relative drop gate (< 0.70 * rollingMedian) requires HR sprint delta or post-rest
        if (isSuspiciouslyFast(candidateDuration)) {
            if (!isHeartRateSprintConfirmed()) {
                return false;
            }
        }

        return true;
    }

    //! Commits a single validated lap and advances baseline, HR history, and heading anchor.
    private function commitValidLap(durationSec as Float, newHeadingDeg as Float?) as Void {
        _validLaps += 1;
        _state = STATE_SWIMMING;
        _pendingDurationSec = 0.0;
        _isPostRestLap = false;
        _justCommittedValidLap = true;
        _discardedSinceCommitSec = 0.0;

        // Update rolling window of last 4 valid lap durations
        pushRollingDuration(durationSec);

        // Save completed lap's average HR as baseline for the next lap
        var lapAvgHR = getCurrentLapAvgHR();
        if (lapAvgHR != null) {
            _prevLapAvgHR = lapAvgHR;
        }
        resetCurrentLapHeartRate();

        // Anchor the new lap's start heading to the post-turn swimming direction
        if (newHeadingDeg != null) {
            _lapStartHeadingDeg = newHeadingDeg;
        }
    }

    //! Appends a valid lap duration to the FIFO rolling window (max 4 entries).
    private function pushRollingDuration(durationSec as Float) as Void {
        if (_recentLapDurations.size() >= ROLLING_WINDOW_SIZE) {
            // Shift left to keep the most recent ROLLING_WINDOW_SIZE - 1 entries
            var trimmed = [] as Array<Float>;
            for (var i = 1; i < ROLLING_WINDOW_SIZE; i++) {
                trimmed.add(_recentLapDurations[i]);
            }
            trimmed.add(durationSec);
            _recentLapDurations = trimmed;
        } else {
            _recentLapDurations.add(durationSec);
        }
    }

    private function resetCurrentLapHeartRate() as Void {
        _lapHrSum = 0;
        _lapHrCount = 0;
        _lapPeakHR = 0;
    }

    // -------------------------------------------------------------------------
    // Manual Lap Overrides (Bottom-Right Button / Menu)
    // -------------------------------------------------------------------------

    //! Manually add +1 valid lap (if native detection missed a real wall turn).
    public function addManualLap() as Number {
        _validLaps += 1;
        _state = STATE_SWIMMING;
        _pendingDurationSec = 0.0;
        _isPostRestLap = false;
        _justCommittedValidLap = false;
        _discardedSinceCommitSec = 0.0;
        return _validLaps;
    }

    //! Manually subtract -1 valid lap (clamped to >= 0).
    public function removeManualLap() as Number {
        if (_validLaps > 0) {
            _validLaps -= 1;
        }
        return _validLaps;
    }

    // -------------------------------------------------------------------------
    // Public Getters
    // -------------------------------------------------------------------------

    public function getValidLaps() as Number {
        return _validLaps;
    }

    //! Valid distance strictly derived as validLaps * poolLengthMeters.
    public function getValidDistanceMeters() as Number {
        return _validLaps * _poolLengthMeters;
    }

    public function getAveragePaceSecPer100m(totalActiveSeconds as Float) as Float {
        return SwimSanityFilter.computePaceSecPer100m(totalActiveSeconds, getValidDistanceMeters());
    }

    public function getRollingMedianSeconds() as Float? {
        return SwimSanityFilter.computeMedian(_recentLapDurations);
    }

    public function getState() as Number {
        return _state;
    }

    public function getPendingDurationSeconds() as Float {
        return _pendingDurationSec;
    }

    public function getLapStartHeadingDegrees() as Float? {
        return _lapStartHeadingDeg;
    }

    public function getCurrentLapAvgHR() as Float? {
        if (_lapHrCount <= 0) {
            return null;
        }
        return _lapHrSum.toFloat() / _lapHrCount.toFloat();
    }

    public function getCurrentLapPeakHR() as Number? {
        if (_lapHrCount <= 0) {
            return null;
        }
        return _lapPeakHR;
    }

    public function getPrevLapAvgHR() as Float? {
        return _prevLapAvgHR;
    }

    public function getPoolLengthMeters() as Number {
        return _poolLengthMeters;
    }

    public function getMinValidLapSeconds() as Float {
        return _minValidLapSec;
    }

    public function isPaused() as Boolean {
        return _isPaused;
    }

    public function isPostRestLap() as Boolean {
        return _isPostRestLap;
    }

    public function getFilteredPhantomCount() as Number {
        return _filteredPhantomCount;
    }
}
