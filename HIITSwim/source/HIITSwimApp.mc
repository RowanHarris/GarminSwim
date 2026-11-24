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

//! Main entry point and session controller for HIIT Swim (Venu 3).
//!
//! Records a standard Pool Swim FIT activity (SPORT_SWIMMING / SUB_SPORT_LAP_SWIMMING)
//! split by session.addLap() at every workout stage transition, with custom session
//! and per-stage FitContributor fields so Warm-up, 4x(4-lap Fast + 1:1 Rest), and
//! Cool-down sync cleanly to Garmin Connect alongside continuous heart-rate telemetry.
class HIITSwimApp extends Application.AppBase {

    // Developer FIT field IDs matching HIITSwim/resources/fitcontributions/fitContributions.xml
    private static const FIT_FIELD_CLEAN_DISTANCE_ID as Number = 0;
    private static const FIT_FIELD_CLEAN_LAPS_ID as Number = 1;
    private static const FIT_FIELD_CLEAN_AVG_PACE_ID as Number = 2;
    private static const FIT_FIELD_STAGE_DISTANCE_ID as Number = 3;
    private static const FIT_FIELD_STAGE_LAPS_ID as Number = 4;

    // 250ms tick gives crisp 1:1 rest countdowns and 3-2-1 haptic alerts
    private static const POLL_INTERVAL_MS as Number = 250;

    private var _engine as HIITWorkoutEngine;
    private var _filter as SwimSanityFilter;
    private var _session as ActivityRecording.Session?;

    private var _fitCleanDistance as FitContributor.Field?;
    private var _fitCleanLaps as FitContributor.Field?;
    private var _fitCleanAvgPace as FitContributor.Field?;
    private var _fitStageDistance as FitContributor.Field?;
    private var _fitStageLaps as FitContributor.Field?;

    private var _pollTimer as Timer.Timer?;
    private var _lastTickSystemMs as Number?;
    private var _lastNativeDistanceMeters as Float;
    private var _lastNativeLapActiveMs as Number;
    private var _stageLapClockMs as Number;
    private var _latestHeadingRad as Float?;
    private var _currentHeartRate as Number?;

    public function initialize() {
        AppBase.initialize();
        _engine = new HIITWorkoutEngine(SwimSanityFilter.POOL_LENGTH_METERS);
        _filter = new SwimSanityFilter(SwimSanityFilter.POOL_LENGTH_METERS);
        _session = null;

        _fitCleanDistance = null;
        _fitCleanLaps = null;
        _fitCleanAvgPace = null;
        _fitStageDistance = null;
        _fitStageLaps = null;

        _pollTimer = null;
        _lastTickSystemMs = null;
        _lastNativeDistanceMeters = 0.0;
        _lastNativeLapActiveMs = 0;
        _stageLapClockMs = 0;
        _latestHeadingRad = null;
        _currentHeartRate = null;
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

        var session = _session;
        if (session != null && session.isRecording()) {
            syncSessionFitFields();
            session.stop();
        }
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new HIITSwimView(self);
        var delegate = new HIITSwimDelegate(self);
        return [view, delegate];
    }

    // -------------------------------------------------------------------------
    // Sensor & Periodic Polling
    // -------------------------------------------------------------------------

    public function onSensorEvent(sensorInfo as Sensor.Info) as Void {
        var heading = sensorInfo.heading;
        if (heading != null) {
            _latestHeadingRad = heading;
            if (_engine.isOpenSwimStage()) {
                _filter.recordHeadingSample(heading);
            }
        }
        var hr = sensorInfo.heartRate;
        if (hr != null && hr > 0) {
            _currentHeartRate = hr;
        }
    }

    public function onPollTimer() as Void {
        var stage = _engine.getStage();
        if (stage == HIITWorkoutEngine.STAGE_READY || stage == HIITWorkoutEngine.STAGE_COMPLETE) {
            // Keep live HR fresh on Ready/Complete screens without advancing workout timers
            sampleHeartRate(Activity.getActivityInfo());
            return;
        }

        var nowMs = System.getTimer();
        var deltaMs = 0;
        var prevTick = _lastTickSystemMs;
        if (prevTick != null) {
            var diff = nowMs - prevTick;
            if (diff > 0 && diff < 10000) {
                deltaMs = diff;
            }
        }
        _lastTickSystemMs = nowMs;

        var actInfo = Activity.getActivityInfo();
        var hr = sampleHeartRate(actInfo);
        var headingRad = readCurrentHeadingRad();

        // Advance HIIT workout clock & check Rest auto-transitions / countdown ticks
        var tickEvent = _engine.tick(deltaMs);
        if (tickEvent == HIITWorkoutEngine.TICK_FAST_TARGET_REACHED) {
            // Subtle buzz at 3:00 mark; Fast continues until Top-Right is pressed
            vibrateTick();
        } else if (tickEvent == HIITWorkoutEngine.TICK_REST_COUNTDOWN_PULSE) {
            vibrateTick();
        } else if (tickEvent == HIITWorkoutEngine.TICK_REST_FINISHED_NEXT_FAST) {
            commitLapMarkerToFit();
            prepareStageSensorState(HIITWorkoutEngine.STAGE_FAST, actInfo, headingRad);
            vibrateGoAlert();
        } else if (tickEvent == HIITWorkoutEngine.TICK_REST_FINISHED_COOLDOWN) {
            commitLapMarkerToFit();
            prepareStageSensorState(HIITWorkoutEngine.STAGE_COOLDOWN, actInfo, headingRad);
            vibrateGoAlert();
        }

        // During open swimming stages (Warm-up & Cool-down), filter native lap events
        if (_engine.isOpenSwimStage()) {
            _stageLapClockMs += deltaMs;
            _filter.recordHeartRateSample(hr);
            _filter.recordHeadingSample(headingRad);
            interceptNativeLaps(actInfo, headingRad);
        } else {
            // Keep native distance baseline synced during Fast/Rest so zero stale delta leaks
            syncNativeDistanceBaseline(actInfo);
        }

        syncSessionFitFields();
        WatchUi.requestUpdate();
    }

    // -------------------------------------------------------------------------
    // Top-Right Stage Progression & Session Lifecycle
    // -------------------------------------------------------------------------

    //! Called on Top-Right physical button press (KEY_ENTER).
    //! Returns the new STAGE_* constant so the delegate knows when to open Save/Discard.
    public function advanceWorkoutStage() as Number {
        var currentStage = _engine.getStage();

        if (currentStage == HIITWorkoutEngine.STAGE_READY) {
            startNewSession();
            return _engine.getStage();
        }

        if (currentStage == HIITWorkoutEngine.STAGE_COMPLETE) {
            return HIITWorkoutEngine.STAGE_COMPLETE;
        }

        var actInfo = Activity.getActivityInfo();
        var headingRad = readCurrentHeadingRad();
        var newStage = _engine.advanceStage();

        if (newStage == HIITWorkoutEngine.STAGE_COMPLETE) {
            writeCompletedStageLapFields();
            syncSessionFitFields();
            var session = _session;
            if (session != null && session.isRecording()) {
                session.stop();
            }
            _lastTickSystemMs = null;
            vibrateDouble();
            WatchUi.requestUpdate();
            return newStage;
        }

        // Close previous stage's FIT lap block and prepare sensors for the new stage
        commitLapMarkerToFit();
        prepareStageSensorState(newStage, actInfo, headingRad);
        syncSessionFitFields();

        if (newStage == HIITWorkoutEngine.STAGE_FAST) {
            vibrateGoAlert();
        } else if (newStage == HIITWorkoutEngine.STAGE_REST) {
            vibrateDouble();
        } else {
            vibrateShort();
        }

        WatchUi.requestUpdate();
        return newStage;
    }

    //! Resume swimming cool-down from the completion menu if the user wants extra laps.
    public function resumeCooldown() as Void {
        if (_engine.getStage() != HIITWorkoutEngine.STAGE_COMPLETE) {
            return;
        }

        var actInfo = Activity.getActivityInfo();
        syncNativeDistanceBaseline(actInfo);
        _lastNativeLapActiveMs = _stageLapClockMs;
        _lastTickSystemMs = System.getTimer();

        var session = _session;
        if (session != null && !session.isRecording()) {
            session.start();
        }

        _filter.onResume(readCurrentHeadingRad());
        _engine.resumeCooldown();

        vibrateShort();
        WatchUi.requestUpdate();
    }

    //! Finalize FIT fields, save the recorded Pool Swim activity, and exit.
    public function saveAndExit() as Void {
        syncSessionFitFields();

        var session = _session;
        if (session != null) {
            if (session.isRecording()) {
                session.stop();
            }
            session.save();
            _session = null;
        }

        _engine.reset();
        System.exit();
    }

    //! Discard the recorded activity after confirmation and exit.
    public function discardAndExit() as Void {
        var session = _session;
        if (session != null) {
            if (session.isRecording()) {
                session.stop();
            }
            session.discard();
            _session = null;
        }

        _engine.reset();
        System.exit();
    }

    //! Manual +1 lap override (Bottom-Right short press) during Warm-up or Cool-down.
    public function manualAddOpenLap() as Void {
        if (!_engine.isOpenSwimStage()) {
            return;
        }
        var laps = _filter.addManualLap();
        _engine.setActiveOpenStageLaps(laps);
        _lastNativeLapActiveMs = _stageLapClockMs;
        syncSessionFitFields();
        vibrateShort();
        WatchUi.requestUpdate();
    }

    //! Manual -1 lap override (Bottom-Right long press) during Warm-up or Cool-down.
    public function manualRemoveOpenLap() as Void {
        if (!_engine.isOpenSwimStage()) {
            return;
        }
        var laps = _filter.removeManualLap();
        _engine.setActiveOpenStageLaps(laps);
        syncSessionFitFields();
        vibrateDouble();
        WatchUi.requestUpdate();
    }

    // -------------------------------------------------------------------------
    // Public Accessors
    // -------------------------------------------------------------------------

    public function getEngine() as HIITWorkoutEngine {
        return _engine;
    }

    public function getCurrentHeartRate() as Number? {
        return _currentHeartRate;
    }

    // -------------------------------------------------------------------------
    // Internal Session, Sensor & FIT Helpers
    // -------------------------------------------------------------------------

    private function startNewSession() as Void {
        _engine.reset();
        _filter.reset();
        _lastNativeDistanceMeters = 0.0;
        _lastNativeLapActiveMs = 0;
        _stageLapClockMs = 0;
        _lastTickSystemMs = System.getTimer();

        var session = ActivityRecording.createSession({
            :name => "HIIT Swim",
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

        _fitStageDistance = session.createField(
            "stage_distance",
            FIT_FIELD_STAGE_DISTANCE_ID,
            FitContributor.DATA_TYPE_UINT16,
            {
                :mesgType => FitContributor.MESG_TYPE_LAP,
                :units => "m"
            }
        );

        _fitStageLaps = session.createField(
            "stage_laps",
            FIT_FIELD_STAGE_LAPS_ID,
            FitContributor.DATA_TYPE_UINT16,
            {
                :mesgType => FitContributor.MESG_TYPE_LAP,
                :units => "laps"
            }
        );

        _session = session;
        syncSessionFitFields();

        session.start();
        _engine.advanceStage(); // READY -> WARMUP
        _filter.recordHeadingSample(readCurrentHeadingRad());

        vibrateShort();
        WatchUi.requestUpdate();
    }

    private function prepareStageSensorState(
        newStage as Number,
        actInfo as Activity.Info?,
        headingRad as Float?
    ) as Void {
        syncNativeDistanceBaseline(actInfo);
        _stageLapClockMs = 0;
        _lastNativeLapActiveMs = 0;

        if (newStage == HIITWorkoutEngine.STAGE_COOLDOWN) {
            // Fresh counter for Cool-down laps, marked post-rest after stationary Rest 4/4
            _filter.reset();
            _filter.onPause();
            _filter.onResume(headingRad);
        } else if (newStage == HIITWorkoutEngine.STAGE_FAST || newStage == HIITWorkoutEngine.STAGE_REST) {
            // Suspend native lap counting during fixed 4-lap Fast & stationary Rest stages
            _filter.onPause();
        }
    }

    private function interceptNativeLaps(actInfo as Activity.Info?, headingRad as Float?) as Void {
        if (actInfo == null || actInfo.elapsedDistance == null) {
            return;
        }

        var nativeDist = actInfo.elapsedDistance as Float;
        var deltaDist = nativeDist - _lastNativeDistanceMeters;
        var poolLen = _filter.getPoolLengthMeters().toFloat();

        if (deltaDist >= (poolLen * 0.5)) {
            var lapCount = Math.round(deltaDist / poolLen).toNumber();
            if (lapCount < 1) {
                lapCount = 1;
            }

            var elapsedSinceLastMs = _stageLapClockMs - _lastNativeLapActiveMs;
            if (elapsedSinceLastMs < 0) {
                elapsedSinceLastMs = 0;
            }
            var perLapSec = (elapsedSinceLastMs.toFloat() / 1000.0) / lapCount.toFloat();

            _lastNativeDistanceMeters = nativeDist;
            _lastNativeLapActiveMs = _stageLapClockMs;

            var anyCommitted = false;
            for (var i = 0; i < lapCount; i++) {
                var res = _filter.onNativeLapEvent(perLapSec, headingRad);
                if (res == SwimSanityFilter.RESULT_ACCEPTED ||
                    res == SwimSanityFilter.RESULT_MERGED_ACCEPTED) {
                    anyCommitted = true;
                }
            }

            if (anyCommitted) {
                _engine.setActiveOpenStageLaps(_filter.getValidLaps());
                vibrateTick();
            }
        }
    }

    private function syncNativeDistanceBaseline(actInfo as Activity.Info?) as Void {
        if (actInfo != null && actInfo.elapsedDistance != null) {
            _lastNativeDistanceMeters = actInfo.elapsedDistance as Float;
        }
    }

    private function sampleHeartRate(actInfo as Activity.Info?) as Number? {
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
        if (hr != null && hr > 0) {
            _currentHeartRate = hr;
        }
        return hr;
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

    private function writeCompletedStageLapFields() as Void {
        var fStageDist = _fitStageDistance;
        if (fStageDist != null) {
            fStageDist.setData(_engine.getLastCompletedStageDistanceMeters());
        }
        var fStageLaps = _fitStageLaps;
        if (fStageLaps != null) {
            fStageLaps.setData(_engine.getLastCompletedStageLaps());
        }
    }

    private function commitLapMarkerToFit() as Void {
        writeCompletedStageLapFields();
        var session = _session;
        if (session != null && session.isRecording()) {
            session.addLap();
        }
    }

    private function syncSessionFitFields() as Void {
        var fDist = _fitCleanDistance;
        if (fDist != null) {
            fDist.setData(_engine.getTotalValidDistanceMeters());
        }
        var fLaps = _fitCleanLaps;
        if (fLaps != null) {
            fLaps.setData(_engine.getTotalValidLaps());
        }
        var fPace = _fitCleanAvgPace;
        if (fPace != null) {
            fPace.setData(_engine.getCleanAvgSwimPaceSecPer100m());
        }
    }

    private function vibrateTick() as Void {
        var vibe = [new Attention.VibeProfile(70, 70)] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateShort() as Void {
        var vibe = [new Attention.VibeProfile(80, 140)] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateDouble() as Void {
        var vibe = [
            new Attention.VibeProfile(80, 100),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(80, 140)
        ] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateGoAlert() as Void {
        var vibe = [new Attention.VibeProfile(100, 350)] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }
}
