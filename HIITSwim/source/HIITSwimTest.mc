import Toybox.Lang;
import Toybox.Test;

//! Connect IQ (:test) unit tests for HIITWorkoutEngine and HIITSwimView formatters.
(:test)
class HIITSwimTest {

    private static function assertFloatNear(
        actual as Float,
        expected as Float,
        epsilon as Float,
        message as String
    ) as Void {
        var diff = actual - expected;
        if (diff < 0.0) {
            diff = -diff;
        }
        Test.assertMessage(
            diff <= epsilon,
            message + " (expected=" + expected.toString() + ", actual=" + actual.toString() + ")"
        );
    }

    (:test)
    public static function testFullHIITWorkflowAndEqualRest(logger as Test.Logger) as Boolean {
        logger.debug("Testing Warm-up -> 4x(4-lap Fast + 1:1 Rest) -> Cool-down -> Complete");

        var engine = new HIITWorkoutEngine(50);

        // Initial READY state shows orange ring
        Test.assertEqual(HIITWorkoutEngine.STAGE_READY, engine.getStage());
        Test.assert(engine.shouldShowOrangeRing());

        // Top-Right -> WARM-UP (no ring)
        Test.assertEqual(HIITWorkoutEngine.STAGE_WARMUP, engine.advanceStage());
        Test.assert(!engine.shouldShowOrangeRing());
        engine.tick(120000); // 2:00 warm-up
        engine.setActiveOpenStageLaps(3); // 3 laps = 150m
        Test.assertEqual(150, engine.getTotalValidDistanceMeters());

        // Top-Right -> FAST 1/4 (3:00 reference countdown, does NOT auto-end at 0:00)
        Test.assertEqual(HIITWorkoutEngine.STAGE_FAST, engine.advanceStage());
        Test.assertEqual(1, engine.getCycleIndex());
        Test.assert(engine.getStageLabel().equals("FAST 1/4"));
        Test.assert(!engine.shouldShowOrangeRing());

        // Reach 3:00 mark -> fires subtle alert once, stays in FAST 1/4
        Test.assertEqual(HIITWorkoutEngine.TICK_FAST_TARGET_REACHED, engine.tick(180000));
        Test.assertEqual(HIITWorkoutEngine.STAGE_FAST, engine.getStage());

        // Swim 30s overtime -> total 3:30 (210s), countdown shows -30.0 (+00:30)
        Test.assertEqual(HIITWorkoutEngine.TICK_NONE, engine.tick(30000));
        assertFloatNear(engine.getFastCountdownSeconds(), -30.0, 0.01, "3:30 fast = -30s overtime");

        // Top-Right completes FAST 1/4 -> commits 4 laps (200m) & starts REST 1/4 for 3:30 (210s)
        Test.assertEqual(HIITWorkoutEngine.STAGE_REST, engine.advanceStage());
        Test.assert(engine.getStageLabel().equals("REST 1/4"));
        Test.assert(engine.shouldShowOrangeRing());
        Test.assertEqual(4, engine.getLastCompletedStageLaps());
        Test.assertEqual(200, engine.getLastCompletedStageDistanceMeters());
        Test.assertEqual(210000, engine.getCurrentRestTargetMs());
        assertFloatNear(engine.getRestRemainingSeconds(), 210.0, 0.01, "Rest 1 equals exact 3:30 fast time");

        // Rest 1 counts down 207s -> 3s left fires countdown pulse -> 3s later auto-advances to FAST 2/4
        Test.assertEqual(HIITWorkoutEngine.TICK_REST_COUNTDOWN_PULSE, engine.tick(207000));
        Test.assertEqual(HIITWorkoutEngine.TICK_REST_FINISHED_NEXT_FAST, engine.tick(3000));
        Test.assertEqual(HIITWorkoutEngine.STAGE_FAST, engine.getStage());
        Test.assertEqual(2, engine.getCycleIndex());

        // Complete Cycles 2, 3, 4 quickly (each 185s fast -> 185s rest)
        for (var c = 2; c <= 4; c++) {
            Test.assertEqual(c, engine.getCycleIndex());
            engine.tick(185000);
            Test.assertEqual(HIITWorkoutEngine.STAGE_REST, engine.advanceStage());
            Test.assertEqual(185000, engine.getCurrentRestTargetMs());
            if (c < 4) {
                // Auto-advance Rest 2 & 3 at 0:00
                Test.assertEqual(HIITWorkoutEngine.TICK_REST_FINISHED_NEXT_FAST, engine.tick(185000));
            }
        }

        // Now in final REST 4/4: Top-Right stops stationary rest early and enters COOL-DOWN
        Test.assertEqual(HIITWorkoutEngine.STAGE_REST, engine.getStage());
        Test.assertEqual(4, engine.getCycleIndex());
        engine.tick(60000);
        Test.assertEqual(HIITWorkoutEngine.STAGE_COOLDOWN, engine.advanceStage());
        Test.assert(engine.getStageLabel().equals("COOL-DOWN"));
        Test.assert(!engine.shouldShowOrangeRing());

        // Cool-down: 2 laps (100m) in 2:00
        engine.tick(120000);
        engine.setActiveOpenStageLaps(2);

        // Top-Right completes workout -> STAGE_COMPLETE (orange ring)
        Test.assertEqual(HIITWorkoutEngine.STAGE_COMPLETE, engine.advanceStage());
        Test.assert(engine.shouldShowOrangeRing());

        // Total distance = 3 warmup + (4 * 4) fast + 2 cooldown = 21 laps = 1,050m
        Test.assertEqual(21, engine.getTotalValidLaps());
        Test.assertEqual(1050, engine.getTotalValidDistanceMeters());

        return true;
    }

    (:test)
    public static function testCountdownAndDistanceFormatters(logger as Test.Logger) as Boolean {
        logger.debug("Testing HIITSwimView countdown, overtime, and distance formatters");

        Test.assert(HIITSwimView.formatCountdown(180.0).equals("03:00"));
        Test.assert(HIITSwimView.formatCountdown(59.1).equals("01:00"));
        Test.assert(HIITSwimView.formatCountdown(0.0).equals("00:00"));
        Test.assert(HIITSwimView.formatCountdown(-1.0).equals("+00:01"));
        Test.assert(HIITSwimView.formatCountdown(-30.0).equals("+00:30"));
        Test.assert(HIITSwimView.formatCountdown(-95.5).equals("+01:35"));

        Test.assert(HIITSwimView.formatDistanceNumber(0, true).equals("0"));
        Test.assert(HIITSwimView.formatDistanceNumber(200, true).equals("200"));
        Test.assert(HIITSwimView.formatDistanceNumber(1050, true).equals("1,050"));

        return true;
    }
}
