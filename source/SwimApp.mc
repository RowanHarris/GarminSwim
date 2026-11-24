import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Application;
import Toybox.Attention;
import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Main entry point and session controller for CleanSwim (Venu 3 Pool Swim Watch App).
//!
//! Manages:
//!   - ActivityRecording.Session configured for SPORT_SWIMMING / SUB_SPORT_LAP_SWIMMING
//!   - Developer FIT fields (clean_distance, clean_laps, clean_avg_pace)
//!   - Continuous HR + compass heading sampling and native lap interception via SwimSanityFilter
class SwimApp extends Application.AppBase {

    public static const SESSION_READY as Number = 0;
    public static const SESSION_ACTIVE as Number = 1;
    public static const SESSION_PAUSED as Number = 2;

    // Developer FIT field IDs matching resources/fitcontributions/fitContributions.xml
    private static const FIT_FIELD_CLEAN_DISTANCE_ID as Number = 0;
    private static const FIT_FIELD_CLEAN_LAPS_ID as Number = 1;
    private static const FIT_FIELD_CLEAN_AVG_PACE_ID as Number = 2;

    // 500ms polling cadence balances turn-heading capture precision and low power draw
    private static const POLL_INTERVAL_MS as Number = 500;

    private var _filter as SwimSanityFilter;
    private var _session as ActivityRecording.Session?;
    private var _sessionState as Number;

    private var _fitCleanDistance as FitContributor.Field?;
    private var _fitCleanLaps as FitContributor.Field?;
    private var _fitCleanAvgPace as FitContributor.Field?;

    private var _pollTimer as Timer.Timer?;
    private var _lastNativeDistanceMeters as Float;
    private var _lastNativeLapActiveMs as Number;
    private var _activeElapsedMs as Number;
    private var _lastTickSystemMs as Number?;
    private var _latestHeadingRad as Float?;

    public function initialize() {
        AppBase.initialize();
        _filter = new SwimSanityFilter(SwimSanityFilter.POOL_LENGTH_METERS);
        _session = null;
        _sessionState = SESSION_READY;

        _fitCleanDistance = null;
        _fitCleanLaps = null;
        _fitCleanAvgPace = null;

        _pollTimer = null;
        _lastNativeDistanceMeters = 0.0;
        _lastNativeLapActiveMs = 0;
        _activeElapsedMs = 0;
        _lastTickSystemMs = null;
        _latestHeadingRad = null;
    }

    public function onStart(state as Dictionary?) as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE] as Array<Sensor.SensorType>);
        Sensor.enableSensorEvents(method(:onSensorEvent));

        var pollTimer = new Timer.Timer();
        pollTimer.start(method(:onPollTimer), POLL_INTERVAL_MS, true);
        _pollTimer = pollTimer;
    }

    public function onStop(state as Dictionary?) as Void {
        var pollTimer = _pollTimer;
        if (pollTimer != null) {
            pollTimer.stop();
            _pollTimer = null;
        }

        Sensor.enableSensorEvents(null);

        // Ensure an active recording session is cleanly stopped if the OS terminates the app
        var session = _session;
        if (session != null && session.isRecording()) {
            syncFitFields();
            session.stop();
        }
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new SwimView(self);
        var delegate = new SwimDelegate(self);
        return [view, delegate];
    }

    // -------------------------------------------------------------------------
    // Sensor & Polling Callbacks
    // -------------------------------------------------------------------------

    //! Live sensor callback keeping compass heading fresh and feeding HR fallback.
    public function onSensorEvent(sensorInfo as Sensor.Info) as Void {
        var heading = sensorInfo.heading;
        if (heading != null) {
            _latestHeadingRad = heading;
            if (_sessionState == SESSION_ACTIVE) {
                _filter.recordHeadingSample(heading);
            }
        }
    }

    //! Periodic 500ms tick: tracks active swim duration, samples HR/heading,
    //! intercepts native lap increments, and refreshes the Venu 3 display.
    public function onPollTimer() as Void {
        if (_sessionState != SESSION_ACTIVE) {
            return;
        }

        var actInfo = Activity.getActivityInfo();
        updateActiveElapsedMs(actInfo);

        // 1. Sample Heart Rate continuously from Activity.Info (with Sensor.Info fallback)
        var hr = null;
        if (actInfo != null && actInfo.currentHeartRate != null) {
            hr = actInfo.currentHeartRate;
        } else {
            var sInfo = Sensor.getInfo();
            var sensorHr = sInfo.heartRate;
            if (sensorHr != null) {
                hr = sensorHr;
            }
        }
        _filter.recordHeartRateSample(hr);

        // 2. Sample current compass heading (Sensor.Info.heading in radians)
        var headingRad = readCurrentHeadingRad();
        _filter.recordHeadingSample(headingRad);

        // 3. Intercept native lap-swimming engine lap completions via elapsedDistance deltas
        if (actInfo != null && actInfo.elapsedDistance != null) {
            var nativeDist = actInfo.elapsedDistance as Float;
            var deltaDist = nativeDist - _lastNativeDistanceMeters;
            var poolLen = _filter.getPoolLengthMeters().toFloat();

            if (deltaDist >= (poolLen * 0.5)) {
                var lapCount = Math.round(deltaDist / poolLen).toNumber();
                if (lapCount < 1) {
                    lapCount = 1;
                }

                var elapsedSinceLastLapMs = _activeElapsedMs - _lastNativeLapActiveMs;
                if (elapsedSinceLastLapMs < 0) {
                    elapsedSinceLastLapMs = 0;
                }
                var perLapDurationSec = (elapsedSinceLastLapMs.toFloat() / 1000.0) / lapCount.toFloat();

                _lastNativeDistanceMeters = nativeDist;
                _lastNativeLapActiveMs = _activeElapsedMs;

                var anyCommitted = false;
                for (var i = 0; i < lapCount; i++) {
                    var result = _filter.onNativeLapEvent(perLapDurationSec, headingRad);
                    if (result == SwimSanityFilter.RESULT_ACCEPTED ||
                        result == SwimSanityFilter.RESULT_MERGED_ACCEPTED) {
                        anyCommitted = true;
                    }
                }

                if (anyCommitted) {
                    vibrateShort();
                }
            }
        }

        syncFitFields();
        WatchUi.requestUpdate();
    }

    // -------------------------------------------------------------------------
    // Session Lifecycle Controls (Driven by Physical Buttons)
    // -------------------------------------------------------------------------

    //! Start a new pool-swimming recording session with native lap engine + developer FIT fields.
    public function startSession() as Void {
        if (_sessionState != SESSION_READY) {
            return;
        }

        _filter.reset();
        _lastNativeDistanceMeters = 0.0;
        _lastNativeLapActiveMs = 0;
        _activeElapsedMs = 0;
        _lastTickSystemMs = System.getTimer();

        var session = ActivityRecording.createSession({
            :name => "Pool Swim",
            :sport => Activity.SPORT_SWIMMING,
            :subSport => Activity.SUB_SPORT_LAP_SWIMMING,
            :poolLength => SwimSanityFilter.POOL_LENGTH_METERS.toFloat()
        });

        _fitCleanDistance = session.createField(
            "clean_distance",
            FIT_FIELD_CLEAN_DISTANCE_ID,
            FitContributor.DATA_TYPE_UINT32,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "m"
            }
        );

        _fitCleanLaps = session.createField(
            "clean_laps",
            FIT_FIELD_CLEAN_LAPS_ID,
            FitContributor.DATA_TYPE_UINT16,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "laps"
            }
        );

        _fitCleanAvgPace = session.createField(
            "clean_avg_pace",
            FIT_FIELD_CLEAN_AVG_PACE_ID,
            FitContributor.DATA_TYPE_FLOAT,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "s/100m"
            }
        );

        _session = session;
        syncFitFields();

        session.start();
        _sessionState = SESSION_ACTIVE;

        // Anchor initial heading if compass is already settled
        _filter.recordHeadingSample(readCurrentHeadingRad());

        vibrateShort();
        WatchUi.requestUpdate();
    }

    //! Pause active swim session: halts recording timer, suspends phantom-lap filter,
    //! and marks the next lap upon resume as a post-rest lap.
    public function pauseSession() as Void {
        if (_sessionState != SESSION_ACTIVE) {
            return;
        }

        updateActiveElapsedMs(Activity.getActivityInfo());
        _lastTickSystemMs = null;

        var session = _session;
        if (session != null && session.isRecording()) {
            session.stop();
        }

        _filter.onPause();
        _sessionState = SESSION_PAUSED;
        syncFitFields();

        vibrateDouble();
        WatchUi.requestUpdate();
    }

    //! Resume a paused swim session and re-anchor native distance and compass heading.
    public function resumeSession() as Void {
        if (_sessionState != SESSION_PAUSED) {
            return;
        }

        // Sync native distance baseline so any motion during rest cannot leak as a lap
        var actInfo = Activity.getActivityInfo();
        if (actInfo != null && actInfo.elapsedDistance != null) {
            _lastNativeDistanceMeters = actInfo.elapsedDistance as Float;
        }
        _lastNativeLapActiveMs = _activeElapsedMs;
        _lastTickSystemMs = System.getTimer();

        var session = _session;
        if (session != null && !session.isRecording()) {
            session.start();
        }

        _filter.onResume(readCurrentHeadingRad());
        _sessionState = SESSION_ACTIVE;

        vibrateShort();
        WatchUi.requestUpdate();
    }

    //! Finalize developer FIT fields, save the recorded FIT activity, and exit the app.
    public function saveAndExit() as Void {
        syncFitFields();

        var session = _session;
        if (session != null) {
            if (session.isRecording()) {
                session.stop();
            }
            session.save();
            _session = null;
        }

        _sessionState = SESSION_READY;
        System.exit();
    }

    //! Discard the recorded FIT activity and exit the app.
    public function discardAndExit() as Void {
        var session = _session;
        if (session != null) {
            if (session.isRecording()) {
                session.stop();
            }
            session.discard();
            _session = null;
        }

        _sessionState = SESSION_READY;
        System.exit();
    }

    //! Manual +1 valid lap override (Bottom-Right short press).
    public function manualAddLap() as Void {
        if (_sessionState == SESSION_READY) {
            return;
        }

        _filter.addManualLap();
        _lastNativeLapActiveMs = _activeElapsedMs;
        syncFitFields();

        vibrateShort();
        WatchUi.requestUpdate();
    }

    //! Manual -1 valid lap override (Bottom-Right long press or Pause menu option).
    public function manualRemoveLap() as Void {
        if (_sessionState == SESSION_READY) {
            return;
        }

        _filter.removeManualLap();
        syncFitFields();

        vibrateDouble();
        WatchUi.requestUpdate();
    }

    // -------------------------------------------------------------------------
    // Public State Accessors (Used by SwimView & SwimDelegate)
    // -------------------------------------------------------------------------

    public function getSessionState() as Number {
        return _sessionState;
    }

    public function getFilter() as SwimSanityFilter {
        return _filter;
    }

    public function getValidDistanceMeters() as Number {
        return _filter.getValidDistanceMeters();
    }

    public function getActiveElapsedSeconds() as Float {
        return _activeElapsedMs.toFloat() / 1000.0;
    }

    public function getAveragePaceSecPer100m() as Float {
        return _filter.getAveragePaceSecPer100m(getActiveElapsedSeconds());
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    private function updateActiveElapsedMs(actInfo as Activity.Info?) as Void {
        var nowMs = System.getTimer();
        var prevTick = _lastTickSystemMs;

        if (actInfo != null && actInfo.timerTime != null) {
            var nativeTimerMs = actInfo.timerTime as Number;
            if (nativeTimerMs >= _activeElapsedMs) {
                _activeElapsedMs = nativeTimerMs;
                _lastTickSystemMs = nowMs;
                return;
            }
        }

        if (prevTick != null) {
            var delta = nowMs - prevTick;
            if (delta > 0 && delta < 10000) {
                _activeElapsedMs += delta;
            }
        }
        _lastTickSystemMs = nowMs;
    }

    private function readCurrentHeadingRad() as Float? {
        var sInfo = Sensor.getInfo();
        var heading = sInfo.heading;
        if (heading != null) {
            _latestHeadingRad = heading;
            return heading;
        }
        return _latestHeadingRad;
    }

    //! Push latest cleaned session totals into the three FitContributor MESG_TYPE_SESSION fields.
    private function syncFitFields() as Void {
        var cleanDist = _filter.getValidDistanceMeters();
        var cleanLaps = _filter.getValidLaps();
        var cleanAvgPace = _filter.getAveragePaceSecPer100m(getActiveElapsedSeconds());

        var fDist = _fitCleanDistance;
        if (fDist != null) {
            fDist.setData(cleanDist);
        }

        var fLaps = _fitCleanLaps;
        if (fLaps != null) {
            fLaps.setData(cleanLaps);
        }

        var fPace = _fitCleanAvgPace;
        if (fPace != null) {
            fPace.setData(cleanAvgPace);
        }
    }

    private function vibrateShort() as Void {
        var vibe = [new Attention.VibeProfile(75, 120)] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateDouble() as Void {
        var vibe = [
            new Attention.VibeProfile(75, 90),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(75, 120)
        ] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }
}
