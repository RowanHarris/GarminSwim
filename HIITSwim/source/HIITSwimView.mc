import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! Ultra-clean, pure-white-on-black Venu 3 (454x454 AMOLED) display for HIIT Swim.
//!
//! Stage displays:
//!   - READY / WARM-UP / COOL-DOWN: Stage label, Distance (m), Lap count, Elapsed time
//!   - FAST 1/4..4/4:               Stage label, 3:00 Countdown (+overtime past 0:00), Live HR
//!   - REST 1/4..4/4:               Orange bezel ring, Stage label, 1:1 Equal Countdown, Live HR
//!   - COMPLETE:                    Orange bezel ring, DONE label, Total Distance, Total Time
class HIITSwimView extends WatchUi.View {

    private static const COLOR_STOPPED_RING as Number = 0xFFAA00;
    private static const COLOR_DIVIDER as Number = 0x262626;

    // Large pure-white Venu 3 typography tuned for 454x454 AMOLED goggle legibility
    private static const FONT_SIZE_STAGE_LABEL as Number = 34;
    private static const FONT_SIZE_OPEN_DIST as Number = 112;
    private static const FONT_SIZE_OPEN_DIST_UNIT as Number = 44;
    private static const FONT_SIZE_OPEN_LAPS as Number = 78;
    private static const FONT_SIZE_OPEN_LAPS_UNIT as Number = 34;
    private static const FONT_SIZE_OPEN_TIME as Number = 68;

    private static const FONT_SIZE_COUNTDOWN as Number = 132;
    private static const FONT_SIZE_COUNTDOWN_OVERTIME as Number = 118;
    private static const FONT_SIZE_HR as Number = 84;
    private static const FONT_SIZE_HR_UNIT as Number = 36;
    private static const FONT_SIZE_HINT as Number = 28;

    private var _app as HIITSwimApp;

    private var _fontStageLabel as Graphics.FontType;
    private var _fontOpenDist as Graphics.FontType;
    private var _fontOpenDistUnit as Graphics.FontType;
    private var _fontOpenLaps as Graphics.FontType;
    private var _fontOpenLapsUnit as Graphics.FontType;
    private var _fontOpenTime as Graphics.FontType;
    private var _fontCountdown as Graphics.FontType;
    private var _fontCountdownOvertime as Graphics.FontType;
    private var _fontHr as Graphics.FontType;
    private var _fontHrUnit as Graphics.FontType;
    private var _fontHint as Graphics.FontType;
    private var _usingVectorFonts as Boolean;

    public function initialize(app as HIITSwimApp) {
        View.initialize();
        _app = app;

        _fontStageLabel = Graphics.FONT_SMALL;
        _fontOpenDist = Graphics.FONT_NUMBER_THAI_HOT;
        _fontOpenDistUnit = Graphics.FONT_MEDIUM;
        _fontOpenLaps = Graphics.FONT_NUMBER_HOT;
        _fontOpenLapsUnit = Graphics.FONT_SMALL;
        _fontOpenTime = Graphics.FONT_NUMBER_MEDIUM;
        _fontCountdown = Graphics.FONT_NUMBER_THAI_HOT;
        _fontCountdownOvertime = Graphics.FONT_NUMBER_HOT;
        _fontHr = Graphics.FONT_NUMBER_HOT;
        _fontHrUnit = Graphics.FONT_SMALL;
        _fontHint = Graphics.FONT_XTINY;
        _usingVectorFonts = false;

        loadDisplayFonts();
    }

    private function loadDisplayFonts() as Void {
        var numFaces = ["YantramanavRegular", "RobotoRegular"] as Array<String>;
        var textFaces = ["RobotoRegular"] as Array<String>;

        var vLabel = loadVectorFont(textFaces, FONT_SIZE_STAGE_LABEL);
        var vOpenDist = loadVectorFont(numFaces, FONT_SIZE_OPEN_DIST);
        var vOpenDistUnit = loadVectorFont(textFaces, FONT_SIZE_OPEN_DIST_UNIT);
        var vOpenLaps = loadVectorFont(numFaces, FONT_SIZE_OPEN_LAPS);
        var vOpenLapsUnit = loadVectorFont(textFaces, FONT_SIZE_OPEN_LAPS_UNIT);
        var vOpenTime = loadVectorFont(numFaces, FONT_SIZE_OPEN_TIME);
        var vCountdown = loadVectorFont(numFaces, FONT_SIZE_COUNTDOWN);
        var vCountdownOver = loadVectorFont(numFaces, FONT_SIZE_COUNTDOWN_OVERTIME);
        var vHr = loadVectorFont(numFaces, FONT_SIZE_HR);
        var vHrUnit = loadVectorFont(textFaces, FONT_SIZE_HR_UNIT);
        var vHint = loadVectorFont(textFaces, FONT_SIZE_HINT);

        if (vLabel != null && vOpenDist != null && vOpenDistUnit != null &&
            vOpenLaps != null && vOpenLapsUnit != null && vOpenTime != null &&
            vCountdown != null && vCountdownOver != null &&
            vHr != null && vHrUnit != null && vHint != null) {
            _fontStageLabel = vLabel;
            _fontOpenDist = vOpenDist;
            _fontOpenDistUnit = vOpenDistUnit;
            _fontOpenLaps = vOpenLaps;
            _fontOpenLapsUnit = vOpenLapsUnit;
            _fontOpenTime = vOpenTime;
            _fontCountdown = vCountdown;
            _fontCountdownOvertime = vCountdownOver;
            _fontHr = vHr;
            _fontHrUnit = vHrUnit;
            _fontHint = vHint;
            _usingVectorFonts = true;
        }
    }

    private function loadVectorFont(faces as Array<String>, sizePx as Number) as Graphics.VectorFont? {
        var opts = {
            :face => faces,
            :size => sizePx
        } as Graphics.VectorFontOptions;
        return Graphics.getVectorFont(opts);
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;

        // Pure black AMOLED background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setAntiAlias(true);

        var engine = _app.getEngine();
        var stage = engine.getStage();

        // Orange bezel ring whenever not actively swimming (Ready, Stationary Rest, Complete)
        if (engine.shouldShowOrangeRing()) {
            drawStatusRing(dc, centerX, height / 2, COLOR_STOPPED_RING, 8);
        }

        // Small stage label at top across every stage
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            (height * 14) / 100,
            _fontStageLabel,
            engine.getStageLabel(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        if (stage == HIITWorkoutEngine.STAGE_FAST || stage == HIITWorkoutEngine.STAGE_REST) {
            drawIntervalScreen(dc, width, height, centerX, engine, stage);
        } else if (stage == HIITWorkoutEngine.STAGE_COMPLETE) {
            drawCompleteScreen(dc, width, height, centerX, engine);
        } else {
            drawOpenSwimScreen(dc, width, height, centerX, engine, stage);
        }
    }

    //! Renders Warm-up / Cool-down (and initial Ready) screen: Distance, Laps, Elapsed Time.
    private function drawOpenSwimScreen(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        centerX as Number,
        engine as HIITWorkoutEngine,
        stage as Number
    ) as Void {
        var divMargin = (width * 22) / 100;
        dc.setColor(COLOR_DIVIDER, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(divMargin, (height * 22) / 100, width - divMargin, (height * 22) / 100);
        dc.drawLine(divMargin, (height * 71) / 100, width - divMargin, (height * 71) / 100);

        var stageLaps = 0;
        var stageSec = 0.0;
        if (stage == HIITWorkoutEngine.STAGE_WARMUP) {
            stageLaps = engine.getWarmupLaps();
            stageSec = engine.getWarmupElapsedSeconds();
        } else if (stage == HIITWorkoutEngine.STAGE_COOLDOWN) {
            stageLaps = engine.getCooldownLaps();
            stageSec = engine.getCooldownElapsedSeconds();
        }

        var stageDist = stageLaps * engine.getPoolLengthMeters();
        var distStr = HIITSwimView.formatDistanceNumber(stageDist, _usingVectorFonts);
        drawValueWithUnit(
            dc,
            centerX,
            (height * 37) / 100,
            distStr,
            _fontOpenDist,
            " m",
            _fontOpenDistUnit
        );

        var lapUnit = (stageLaps == 1) ? " LAP" : " LAPS";
        drawValueWithUnit(
            dc,
            centerX,
            (height * 60) / 100,
            stageLaps.format("%d"),
            _fontOpenLaps,
            lapUnit,
            _fontOpenLapsUnit
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            (height * 81) / 100,
            _fontOpenTime,
            HIITSwimView.formatElapsedTime(stageSec),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Renders Fast (4-lap, 3:00 reference countdown) and Stationary Rest (1:1 equal countdown) screen:
    //! Huge Countdown Time Left + Live Heart Rate.
    private function drawIntervalScreen(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        centerX as Number,
        engine as HIITWorkoutEngine,
        stage as Number
    ) as Void {
        var divMargin = (width * 18) / 100;
        dc.setColor(COLOR_DIVIDER, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(divMargin, (height * 24) / 100, width - divMargin, (height * 24) / 100);
        dc.drawLine(divMargin, (height * 68) / 100, width - divMargin, (height * 68) / 100);

        var countdownSec = (stage == HIITWorkoutEngine.STAGE_FAST)
            ? engine.getFastCountdownSeconds()
            : engine.getRestRemainingSeconds();

        var countdownStr = HIITSwimView.formatCountdown(countdownSec);
        var countdownFont = (countdownSec < 0.0) ? _fontCountdownOvertime : _fontCountdown;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            (height * 47) / 100,
            countdownFont,
            countdownStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var hr = _app.getCurrentHeartRate();
        var hrText = (hr != null) ? hr.format("%d") : "--";
        drawValueWithUnit(
            dc,
            centerX,
            (height * 79) / 100,
            hrText,
            _fontHr,
            " bpm",
            _fontHrUnit
        );
    }

    //! Renders completion summary if the user dismisses the Save / Discard menu.
    private function drawCompleteScreen(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        centerX as Number,
        engine as HIITWorkoutEngine
    ) as Void {
        var divMargin = (width * 20) / 100;
        dc.setColor(COLOR_DIVIDER, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(divMargin, (height * 23) / 100, width - divMargin, (height * 23) / 100);
        dc.drawLine(divMargin, (height * 72) / 100, width - divMargin, (height * 72) / 100);

        var totalDist = engine.getTotalValidDistanceMeters();
        var distStr = HIITSwimView.formatDistanceNumber(totalDist, _usingVectorFonts);
        drawValueWithUnit(
            dc,
            centerX,
            (height * 39) / 100,
            distStr,
            _fontOpenDist,
            " m",
            _fontOpenDistUnit
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            (height * 61) / 100,
            _fontOpenTime,
            HIITSwimView.formatElapsedTime(engine.getTotalElapsedSeconds()),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.drawText(
            centerX,
            (height * 81) / 100,
            _fontHint,
            "TOP: SAVE / DISCARD",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawValueWithUnit(
        dc as Graphics.Dc,
        centerX as Number,
        centerY as Number,
        valueText as String,
        valueFont as Graphics.FontType,
        unitText as String,
        unitFont as Graphics.FontType
    ) as Void {
        var valDim = dc.getTextDimensions(valueText, valueFont);
        var unitDim = dc.getTextDimensions(unitText, unitFont);

        var valWidth = valDim[0];
        var valHeight = valDim[1];
        var unitWidth = unitDim[0];
        var unitHeight = unitDim[1];

        var totalWidth = valWidth + unitWidth;
        var startX = centerX - (totalWidth / 2);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            startX,
            centerY,
            valueFont,
            valueText,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var unitOffsetY = (valHeight - unitHeight) / 4;
        dc.drawText(
            startX + valWidth,
            centerY + unitOffsetY,
            unitFont,
            unitText,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawStatusRing(
        dc as Graphics.Dc,
        centerX as Number,
        centerY as Number,
        color as Number,
        penWidth as Number
    ) as Void {
        var radius = centerX - (penWidth / 2) - 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(penWidth);
        dc.drawCircle(centerX, centerY, radius);
    }

    // -------------------------------------------------------------------------
    // Pure, Unit-Testable Formatting Helpers
    // -------------------------------------------------------------------------

    public static function formatDistanceNumber(meters as Number, includeComma as Boolean) as String {
        if (meters < 0) {
            meters = 0;
        }
        if (!includeComma || meters < 1000) {
            return meters.format("%d");
        }
        var thousands = meters / 1000;
        var remainder = meters % 1000;
        return thousands.format("%d") + "," + remainder.format("%03d");
    }

    public static function formatElapsedTime(totalSeconds as Float) as String {
        var wholeSec = Math.floor(totalSeconds).toNumber();
        if (wholeSec < 0) {
            wholeSec = 0;
        }
        var hours = wholeSec / 3600;
        var minutes = (wholeSec % 3600) / 60;
        var seconds = wholeSec % 60;
        if (hours > 0) {
            return hours.format("%02d") + ":" + minutes.format("%02d") + ":" + seconds.format("%02d");
        }
        return minutes.format("%02d") + ":" + seconds.format("%02d");
    }

    //! Formats countdown seconds as "MM:SS" (>= 0.0) or "+MM:SS" when overtime (< 0.0).
    public static function formatCountdown(remainingSeconds as Float) as String {
        if (remainingSeconds < 0.0) {
            var overSec = Math.floor(-remainingSeconds).toNumber();
            var overMin = overSec / 60;
            var overRem = overSec % 60;
            return "+" + overMin.format("%02d") + ":" + overRem.format("%02d");
        }
        var ceilSec = Math.ceil(remainingSeconds).toNumber();
        if (ceilSec < 0) {
            ceilSec = 0;
        }
        var minutes = ceilSec / 60;
        var seconds = ceilSec % 60;
        return minutes.format("%02d") + ":" + seconds.format("%02d");
    }
}
