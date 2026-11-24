import Toybox.Lang;
import Toybox.Math;
import Toybox.Test;

//! Connect IQ unit tests for SwimSanityFilter and SwimView formatting helpers.
//! Compile and run with:
//!   monkeyc -t -d venu3 -f monkey.jungle -o bin/CleanSwim-test.prg -y developer_key -l 3 -w
//!   monkeydo bin/CleanSwim-test.prg venu3 -t
(:test)
class SwimSanityFilterTest {

    private static function degToRad(deg as Float) as Float {
        return (deg * Math.PI.toFloat()) / 180.0;
    }

    private static function assertFloatNear(
        actual as Float?,
        expected as Float,
        epsilon as Float,
        message as String
    ) as Void {
        Test.assertMessage(actual != null, message + " (was null)");
        if (actual != null) {
            var diff = actual - expected;
            if (diff < 0.0) {
                diff = -diff;
            }
            Test.assertMessage(
                diff <= epsilon,
                message + " (expected=" + expected.toString() + ", actual=" + actual.toString() + ")"
            );
        }
    }

    (:test)
    public static function testHeadingMathAndReversalGates(logger as Test.Logger) as Boolean {
        logger.debug("Testing radians-to-degrees normalization and angular delta gates");

        assertFloatNear(SwimSanityFilter.radiansToDegrees(0.0), 0.0, 0.01, "0 rad -> 0 deg");
        assertFloatNear(SwimSanityFilter.radiansToDegrees(Math.PI.toFloat()), 180.0, 0.05, "PI rad -> 180 deg");
        assertFloatNear(SwimSanityFilter.radiansToDegrees(-Math.PI.toFloat() / 2.0), 270.0, 0.05, "-PI/2 rad -> 270 deg");

        // Wrap-around shortest angular difference
        assertFloatNear(SwimSanityFilter.computeDeltaHeading(10.0, 350.0), 20.0, 0.01, "10 vs 350 -> 20 deg");
        assertFloatNear(SwimSanityFilter.computeDeltaHeading(10.0, 190.0), 180.0, 0.01, "10 vs 190 -> 180 deg");
        assertFloatNear(SwimSanityFilter.computeDeltaHeading(350.0, 160.0), 170.0, 0.01, "350 vs 160 -> 170 deg");

        Test.assert(SwimSanityFilter.isHeadingReversal(135.0));
        Test.assert(SwimSanityFilter.isHeadingReversal(180.0));
        Test.assert(SwimSanityFilter.isHeadingReversal(225.0));
        Test.assert(!SwimSanityFilter.isHeadingReversal(134.9));
        Test.assert(!SwimSanityFilter.isHeadingReversal(20.0));

        Test.assert(SwimSanityFilter.isSameDirection(0.0));
        Test.assert(SwimSanityFilter.isSameDirection(89.9));
        Test.assert(!SwimSanityFilter.isSameDirection(90.0));

        return true;
    }

    (:test)
    public static function testRollingMedianWindow(logger as Test.Logger) as Boolean {
        logger.debug("Testing median helper and 4-lap sliding baseline window");

        Test.assert(SwimSanityFilter.computeMedian([] as Array<Float>) == null);
        assertFloatNear(SwimSanityFilter.computeMedian([50.0] as Array<Float>), 50.0, 0.01, "1-element median");
        assertFloatNear(SwimSanityFilter.computeMedian([50.0, 54.0] as Array<Float>), 52.0, 0.01, "2-element median");
        assertFloatNear(SwimSanityFilter.computeMedian([54.0, 48.0, 50.0] as Array<Float>), 50.0, 0.01, "3-element median");
        assertFloatNear(SwimSanityFilter.computeMedian([54.0, 48.0, 52.0, 50.0] as Array<Float>), 51.0, 0.01, "4-element median");

        // Verify rolling window drops the oldest entry once > 4 valid laps are recorded
        var filter = new SwimSanityFilter(50);
        filter.setLapStartHeadingDegrees(0.0);

        var durations = [40.0, 50.0, 52.0, 54.0, 56.0] as Array<Float>;
        var headings = [180.0, 0.0, 180.0, 0.0, 180.0] as Array<Float>;
        for (var i = 0; i < durations.size(); i++) {
            filter.recordHeartRateSample(140);
            var res = filter.onNativeLapEvent(durations[i], degToRad(headings[i]));
            Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, res);
        }

        // Window should now hold [50, 52, 54, 56] -> median 53.0 (40.0 evicted)
        assertFloatNear(filter.getRollingMedianSeconds(), 53.0, 0.01, "5th lap evicts 1st lap from rolling median");
        Test.assertEqual(5, filter.getValidLaps());
        Test.assertEqual(250, filter.getValidDistanceMeters());

        return true;
    }

    (:test)
    public static function testHardFloor50mAnd25mPools(logger as Test.Logger) as Boolean {
        logger.debug("Testing hard minimum lap duration floor for 50m (28s) and 25m (14s) pools");

        var filter50 = new SwimSanityFilter(50);
        assertFloatNear(filter50.getMinValidLapSeconds(), 28.0, 0.01, "50m min floor is 28s");
        filter50.setLapStartHeadingDegrees(0.0);
        var r50Fail = filter50.onNativeLapEvent(27.9, degToRad(180.0));
        Test.assertEqual(SwimSanityFilter.RESULT_PENDING_MERGE, r50Fail);
        Test.assertEqual(0, filter50.getValidLaps());

        var filter25 = new SwimSanityFilter(25);
        assertFloatNear(filter25.getMinValidLapSeconds(), 14.0, 0.01, "25m min floor is 14s");
        filter25.setLapStartHeadingDegrees(0.0);
        var r25Fail = filter25.onNativeLapEvent(13.9, degToRad(180.0));
        Test.assertEqual(SwimSanityFilter.RESULT_PENDING_MERGE, r25Fail);
        Test.assertEqual(0, filter25.getValidLaps());

        var filter25Ok = new SwimSanityFilter(25);
        filter25Ok.setLapStartHeadingDegrees(0.0);
        var r25Ok = filter25Ok.onNativeLapEvent(14.0, degToRad(180.0));
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, r25Ok);
        Test.assertEqual(1, filter25Ok.getValidLaps());
        Test.assertEqual(25, filter25Ok.getValidDistanceMeters());

        return true;
    }

    (:test)
    public static function testMidLaneSplitMergeAndAbsorb(logger as Test.Logger) as Boolean {
        logger.debug("Testing STATE_PENDING_MERGE mid-lane split absorption into 1 single valid lap");

        var filter = new SwimSanityFilter(50);
        filter.setLapStartHeadingDegrees(0.0);

        // Lap 1: Normal 50s lap @ 135 bpm, clean 180 deg wall reversal (0 -> 180)
        filter.recordHeartRateSample(135);
        filter.recordHeartRateSample(135);
        var res1 = filter.onNativeLapEvent(50.0, degToRad(180.0));
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, res1);
        Test.assertEqual(1, filter.getValidLaps());
        assertFloatNear(filter.getLapStartHeadingDegrees(), 180.0, 0.1, "Lap 2 start heading anchored at 180 deg");

        // Mid-lane false split at 30s dodging a lane-mate: still moving ~185 deg (delta 5 deg < 90), flat HR 136
        filter.recordHeartRateSample(136);
        var resSplit = filter.onNativeLapEvent(30.0, degToRad(185.0));
        Test.assertEqual(SwimSanityFilter.RESULT_PENDING_MERGE, resSplit);
        Test.assertEqual(SwimSanityFilter.STATE_PENDING_MERGE, filter.getState());
        Test.assertEqual(1, filter.getValidLaps());
        assertFloatNear(filter.getPendingDurationSeconds(), 30.0, 0.01, "Pending duration holds 30s");
        assertFloatNear(filter.getLapStartHeadingDegrees(), 180.0, 0.1, "lapStartHeading preserved during pending merge");

        // Actual wall turn 20s later: heading reverses to 2 deg (delta 178 deg vs original 180 deg)
        // Total merged duration = 30s + 20s = 50s -> commit 1 single valid lap
        filter.recordHeartRateSample(137);
        var resMerge = filter.onNativeLapEvent(20.0, degToRad(2.0));
        Test.assertEqual(SwimSanityFilter.RESULT_MERGED_ACCEPTED, resMerge);
        Test.assertEqual(SwimSanityFilter.STATE_SWIMMING, filter.getState());
        Test.assertEqual(2, filter.getValidLaps());
        Test.assertEqual(100, filter.getValidDistanceMeters());
        assertFloatNear(filter.getPendingDurationSeconds(), 0.0, 0.01, "Pending duration reset after commit");
        assertFloatNear(filter.getLapStartHeadingDegrees(), 2.0, 0.1, "New start heading anchored after merge");

        return true;
    }

    (:test)
    public static function testHeartRateDeltaSprintConfirmation(logger as Test.Logger) as Boolean {
        logger.debug("Testing HR delta confirmation: flat HR phantom rejected, +8 bpm sprint accepted");

        var filter = new SwimSanityFilter(50);
        filter.setLapStartHeadingDegrees(0.0);

        // Lap 1 baseline: 55s @ 135 bpm (0.70 * 55 = 38.5s threshold)
        filter.recordHeartRateSample(135);
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, filter.onNativeLapEvent(55.0, degToRad(180.0)));

        // Fast 34s lap with flat HR (136 bpm < 135 + 8 = 143) even with valid reversal -> phantom!
        filter.recordHeartRateSample(136);
        var resFlat = filter.onNativeLapEvent(34.0, degToRad(0.0));
        Test.assertEqual(SwimSanityFilter.RESULT_PENDING_MERGE, resFlat);
        Test.assertEqual(1, filter.getValidLaps());

        // Fresh filter: same 34s lap, valid reversal, BUT peak HR spikes to 144 (>= 135 + 8 = 143) -> sprint accepted!
        var sprintFilter = new SwimSanityFilter(50);
        sprintFilter.setLapStartHeadingDegrees(0.0);
        sprintFilter.recordHeartRateSample(135);
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, sprintFilter.onNativeLapEvent(55.0, degToRad(180.0)));

        sprintFilter.recordHeartRateSample(140);
        sprintFilter.recordHeartRateSample(144);
        var resSprint = sprintFilter.onNativeLapEvent(34.0, degToRad(0.0));
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, resSprint);
        Test.assertEqual(2, sprintFilter.getValidLaps());

        return true;
    }

    (:test)
    public static function testPauseSuspendsAndMarksPostRestLap(logger as Test.Logger) as Boolean {
        logger.debug("Testing pause/resume suspension and post-rest fast lap acceptance");

        var filter = new SwimSanityFilter(50);
        filter.setLapStartHeadingDegrees(0.0);

        // Lap 1 baseline: 55s @ 135 bpm
        filter.recordHeartRateSample(135);
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, filter.onNativeLapEvent(55.0, degToRad(180.0)));

        // Pause: native events while paused must be ignored
        filter.onPause();
        Test.assert(filter.isPaused());
        Test.assert(filter.isPostRestLap());
        Test.assertEqual(SwimSanityFilter.RESULT_IGNORED_PAUSED, filter.onNativeLapEvent(50.0, degToRad(0.0)));
        Test.assertEqual(1, filter.getValidLaps());

        // Resume at 0 deg heading: first lap after rest at 34s (< 0.70 * 55s) with flat HR 135 -> ACCEPTED
        filter.onResume(degToRad(0.0));
        Test.assert(!filter.isPaused());
        filter.recordHeartRateSample(135);
        var resPostRest = filter.onNativeLapEvent(34.0, degToRad(180.0));
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, resPostRest);
        Test.assertEqual(2, filter.getValidLaps());
        Test.assert(!filter.isPostRestLap());

        return true;
    }

    (:test)
    public static function testWallDoubleTapGlitchDiscarded(logger as Test.Logger) as Boolean {
        logger.debug("Testing < 10s wall double-tap glitch discard");

        var filter = new SwimSanityFilter(50);
        filter.setLapStartHeadingDegrees(0.0);

        // Commit Lap 1 (50s)
        filter.recordHeartRateSample(138);
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, filter.onNativeLapEvent(50.0, degToRad(180.0)));
        Test.assertEqual(1, filter.getValidLaps());

        // Wall double-tap glitch 4s immediately after commit -> discarded completely
        var resGlitch = filter.onNativeLapEvent(4.0, degToRad(180.0));
        Test.assertEqual(SwimSanityFilter.RESULT_DISCARDED_DOUBLE_TAP, resGlitch);
        Test.assertEqual(SwimSanityFilter.STATE_SWIMMING, filter.getState());
        Test.assertEqual(1, filter.getValidLaps());
        assertFloatNear(filter.getPendingDurationSeconds(), 0.0, 0.01, "Double-tap does not pollute pendingDuration");

        // Subsequent normal Lap 2 (46s) reversing back to 0 deg -> accepted
        filter.recordHeartRateSample(139);
        var resLap2 = filter.onNativeLapEvent(46.0, degToRad(0.0));
        Test.assertEqual(SwimSanityFilter.RESULT_ACCEPTED, resLap2);
        Test.assertEqual(2, filter.getValidLaps());
        Test.assertEqual(100, filter.getValidDistanceMeters());

        return true;
    }

    (:test)
    public static function testManualOverridesAndFormatters(logger as Test.Logger) as Boolean {
        logger.debug("Testing manual +1/-1 lap overrides, pace math, and SwimView formatters");

        var filter = new SwimSanityFilter(50);
        Test.assertEqual(0, filter.removeManualLap()); // Clamped at 0
        Test.assertEqual(1, filter.addManualLap());
        Test.assertEqual(50, filter.getValidDistanceMeters());
        Test.assertEqual(2, filter.addManualLap());
        Test.assertEqual(100, filter.getValidDistanceMeters());
        Test.assertEqual(1, filter.removeManualLap());
        Test.assertEqual(50, filter.getValidDistanceMeters());

        // Pace math: 900s / 500m * 100 = 180s / 100m (03:00 /100m)
        assertFloatNear(SwimSanityFilter.computePaceSecPer100m(900.0, 500), 180.0, 0.01, "Pace 900s/500m = 180s/100m");
        assertFloatNear(SwimSanityFilter.computePaceSecPer100m(120.0, 0), 0.0, 0.01, "Pace at 0m = 0.0");

        // View formatting checks
        Test.assert(SwimView.formatDistanceNumber(0, true).equals("0"));
        Test.assert(SwimView.formatDistanceNumber(950, true).equals("950"));
        Test.assert(SwimView.formatDistanceNumber(1500, true).equals("1,500"));
        Test.assert(SwimView.formatDistanceNumber(1500, false).equals("1500"));

        Test.assert(SwimView.formatElapsedTime(0.0).equals("00:00"));
        Test.assert(SwimView.formatElapsedTime(125.0).equals("02:05"));
        Test.assert(SwimView.formatElapsedTime(3665.0).equals("01:01:05"));

        Test.assert(SwimView.formatPaceTime(0.0).equals("--:--"));
        Test.assert(SwimView.formatPaceTime(105.0).equals("01:45"));

        return true;
    }
}
