import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! Ultra-clean, high-contrast Venu 3 (454x454 AMOLED) swim display.
//!
//! Renders strictly three vertically stacked metrics in pure white on a pure
//! black background for maximum underwater glanceability through swim goggles:
//!   1. Total Distance (top, largest font, e.g. "1,500 m")
//!   2. Total Elapsed Time (middle, large font, "MM:SS" or "HH:MM:SS")
//!   3. Average Pace (bottom, large font, "MM:SS /100m")
//!
//! An outer amber bezel ring appears whenever recording is not running
//! (initial Ready state and Paused state) and disappears while actively swimming.
class SwimView extends WatchUi.View {

    // High-contrast monochrome AMOLED palette (amber ring used strictly for PAUSED cue)
    private static const COLOR_PAUSED_RING as Number = 0xFFAA00;
    private static const COLOR_DIVIDER as Number = 0x262626;

    // Large Venu 3 (454x454) scalable font sizes tuned for maximum goggle legibility
    private static const FONT_SIZE_DISTANCE as Number = 124;
    private static const FONT_SIZE_DISTANCE_LONG as Number = 104;
    private static const FONT_SIZE_DISTANCE_UNIT as Number = 46;
    private static const FONT_SIZE_TIME_SHORT as Number = 126;
    private static const FONT_SIZE_TIME_LONG as Number = 92;
    private static const FONT_SIZE_PACE as Number = 96;
    private static const FONT_SIZE_PACE_UNIT as Number = 38;

    private var _app as SwimApp;

    private var _fontDistance as Graphics.FontType;
    private var _fontDistanceLong as Graphics.FontType;
    private var _fontDistanceUnit as Graphics.FontType;
    private var _fontTimeShort as Graphics.FontType;
    private var _fontTimeLong as Graphics.FontType;
    private var _fontPace as Graphics.FontType;
    private var _fontPaceUnit as Graphics.FontType;
    private var _usingVectorFonts as Boolean;

    public function initialize(app as SwimApp) {
        View.initialize();
        _app = app;

        _fontDistance = Graphics.FONT_NUMBER_THAI_HOT;
        _fontDistanceLong = Graphics.FONT_NUMBER_HOT;
        _fontDistanceUnit = Graphics.FONT_MEDIUM;
        _fontTimeShort = Graphics.FONT_NUMBER_THAI_HOT;
        _fontTimeLong = Graphics.FONT_NUMBER_HOT;
        _fontPace = Graphics.FONT_NUMBER_HOT;
        _fontPaceUnit = Graphics.FONT_SMALL;
        _usingVectorFonts = false;

        loadDisplayFonts();
    }

    //! Loads Venu 3 native scalable vector fonts (YantramanavRegular for tall, crisp
    //! sport numerals; RobotoRegular for unit suffixes), falling back cleanly to
    //! built-in system fonts if unavailable.
    private function loadDisplayFonts() as Void {
        var numFaces = ["YantramanavRegular", "RobotoRegular"] as Array<String>;
        var unitFaces = ["RobotoRegular"] as Array<String>;

        var vDist = loadVectorFont(numFaces, FONT_SIZE_DISTANCE);
        var vDistLong = loadVectorFont(numFaces, FONT_SIZE_DISTANCE_LONG);
        var vDistUnit = loadVectorFont(unitFaces, FONT_SIZE_DISTANCE_UNIT);
        var vTimeShort = loadVectorFont(numFaces, FONT_SIZE_TIME_SHORT);
        var vTimeLong = loadVectorFont(numFaces, FONT_SIZE_TIME_LONG);
        var vPace = loadVectorFont(numFaces, FONT_SIZE_PACE);
        var vPaceUnit = loadVectorFont(unitFaces, FONT_SIZE_PACE_UNIT);

        if (vDist != null && vDistLong != null && vDistUnit != null &&
            vTimeShort != null && vTimeLong != null &&
            vPace != null && vPaceUnit != null) {
            _fontDistance = vDist;
            _fontDistanceLong = vDistLong;
            _fontDistanceUnit = vDistUnit;
            _fontTimeShort = vTimeShort;
            _fontTimeLong = vTimeLong;
            _fontPace = vPace;
            _fontPaceUnit = vPaceUnit;
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

        // 1. Pure black AMOLED background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setAntiAlias(true);

        // Outer amber ring whenever recording is stopped (Ready on launch or Paused);
        // disappears completely while actively swimming.
        if (_app.getSessionState() != SwimApp.SESSION_ACTIVE) {
            drawStatusRing(dc, centerX, height / 2, COLOR_PAUSED_RING, 8);
        }

        // Subtle horizontal dividers separating the 3 metric bands
        var divMargin = (width * 18) / 100;
        dc.setColor(COLOR_DIVIDER, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(divMargin, (height * 37) / 100, width - divMargin, (height * 37) / 100);
        dc.drawLine(divMargin, (height * 64) / 100, width - divMargin, (height * 64) / 100);

        // ---------------------------------------------------------------------
        // Metric 1 (Top): Total Distance (validLaps * POOL_LENGTH_METERS)
        // ---------------------------------------------------------------------
        var distMeters = _app.getValidDistanceMeters();
        var distDigits = SwimView.formatDistanceNumber(distMeters, _usingVectorFonts);
        var distFont = (distMeters >= 10000) ? _fontDistanceLong : _fontDistance;
        var distY = (height * 24) / 100;
        drawValueWithUnit(
            dc,
            centerX,
            distY,
            distDigits,
            distFont,
            " m",
            _fontDistanceUnit
        );

        // ---------------------------------------------------------------------
        // Metric 2 (Middle): Total Elapsed Time (MM:SS or HH:MM:SS)
        // ---------------------------------------------------------------------
        var elapsedSec = _app.getActiveElapsedSeconds();
        var timeStr = SwimView.formatElapsedTime(elapsedSec);
        var timeFont = (elapsedSec >= 3600.0) ? _fontTimeLong : _fontTimeShort;
        var timeY = (height * 51) / 100;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            timeY,
            timeFont,
            timeStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ---------------------------------------------------------------------
        // Metric 3 (Bottom): Average Pace (MM:SS /100m)
        // ---------------------------------------------------------------------
        var paceSecPer100m = _app.getAveragePaceSecPer100m();
        var paceDigits = SwimView.formatPaceTime(paceSecPer100m);
        var paceY = (height * 76) / 100;
        drawValueWithUnit(
            dc,
            centerX,
            paceY,
            paceDigits,
            _fontPace,
            " /100m",
            _fontPaceUnit
        );
    }

    //! Draws a large primary numeric value paired with a smaller right-hand unit suffix,
    //! both in pure white and horizontally centered as a single visual block.
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

        // Align unit slightly lower so it sits cleanly near the numeric baseline
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

    //! Formats integer meters with optional thousands separator (e.g. "1,500" or "1500").
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

    //! Formats active swim time as "MM:SS" (< 1 hour) or "HH:MM:SS" (>= 1 hour).
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

    //! Formats average pace (seconds per 100m) as "MM:SS", or "--:--" when distance is 0.
    public static function formatPaceTime(paceSecPer100m as Float) as String {
        if (paceSecPer100m <= 0.0) {
            return "--:--";
        }
        var roundedSec = Math.round(paceSecPer100m).toNumber();
        if (roundedSec <= 0) {
            return "--:--";
        }
        // Cap displayable pace at 99:59 to keep layout tidy if paused/drifting excessively
        if (roundedSec > 5999) {
            roundedSec = 5999;
        }
        var minutes = roundedSec / 60;
        var seconds = roundedSec % 60;
        return minutes.format("%02d") + ":" + seconds.format("%02d");
    }
}
