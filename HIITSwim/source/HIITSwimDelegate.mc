import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! Physical-button-only BehaviorDelegate for Venu 3 HIIT Swim.
//!
//! All touchscreen taps/swipes/holds/drags are ignored so water splashes never
//! interfere with the workout:
//!   - Top-Right (KEY_ENTER): Linearly advances through every stage
//!     (Ready -> Warm-up -> Fast 1..4 -> Rest 1..4 -> Cool-down -> Save/Discard menu).
//!   - Bottom-Right (KEY_ESC): Exits cleanly when Ready; during Warm-up & Cool-down
//!     short press = +1 lap, long press (>= 700ms) = -1 lap; ignored during Fast/Rest.
class HIITSwimDelegate extends WatchUi.BehaviorDelegate {

    private static const LONG_PRESS_THRESHOLD_MS as Number = 700;

    private var _app as HIITSwimApp;
    private var _escHoldTimer as Timer.Timer?;
    private var _escPressedActive as Boolean;
    private var _escLongPressTriggered as Boolean;

    public function initialize(app as HIITSwimApp) {
        BehaviorDelegate.initialize();
        _app = app;
        _escHoldTimer = null;
        _escPressedActive = false;
        _escLongPressTriggered = false;
    }

    // -------------------------------------------------------------------------
    // Behavior Overrides (Separate Physical Buttons from Touch Gestures)
    // -------------------------------------------------------------------------

    public function onSelect() as Boolean {
        return false;
    }

    public function onBack() as Boolean {
        if (!_escPressedActive && _app.getEngine().getStage() != HIITWorkoutEngine.STAGE_READY) {
            return true;
        }
        return false;
    }

    public function onNextPage() as Boolean {
        return false;
    }

    public function onPreviousPage() as Boolean {
        return false;
    }

    public function onMenu() as Boolean {
        return false;
    }

    // -------------------------------------------------------------------------
    // Touchscreen Splash Suppression
    // -------------------------------------------------------------------------

    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    public function onHold(clickEvent as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    public function onRelease(clickEvent as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    public function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return true;
    }

    public function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        return true;
    }

    // -------------------------------------------------------------------------
    // Physical Hardware Button Handling (Venu 3 Top-Right & Bottom-Right)
    // -------------------------------------------------------------------------

    public function onKeyPressed(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        if (key == WatchUi.KEY_ESC) {
            _escPressedActive = true;
            if (_app.getEngine().isOpenSwimStage()) {
                cancelEscHoldTimer();
                _escLongPressTriggered = false;

                var holdTimer = new Timer.Timer();
                holdTimer.start(method(:onEscLongPress), LONG_PRESS_THRESHOLD_MS, false);
                _escHoldTimer = holdTimer;
                return true;
            }
        }
        return false;
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        // Top-Right physical button: advance cleanly through stages -> Save/Discard at end
        if (key == WatchUi.KEY_ENTER) {
            var newStage = _app.advanceWorkoutStage();
            if (newStage == HIITWorkoutEngine.STAGE_COMPLETE) {
                pushCompleteMenu();
            }
            return true;
        }

        // Bottom-Right physical button
        if (key == WatchUi.KEY_ESC) {
            var stage = _app.getEngine().getStage();
            if (stage == HIITWorkoutEngine.STAGE_READY) {
                return false;
            }

            cancelEscHoldTimer();

            if (!_app.getEngine().isOpenSwimStage()) {
                // Ignore during Fast/Rest/Complete so fixed intervals can't be disrupted
                return true;
            }

            if (_escLongPressTriggered) {
                return true;
            }

            _app.manualAddOpenLap();
            return true;
        }

        return false;
    }

    public function onKeyReleased(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        if (key == WatchUi.KEY_ESC) {
            cancelEscHoldTimer();
            _escPressedActive = false;
            _escLongPressTriggered = false;
            return true;
        }
        return false;
    }

    public function onEscLongPress() as Void {
        _escHoldTimer = null;
        _escLongPressTriggered = true;
        _app.manualRemoveOpenLap();
    }

    // -------------------------------------------------------------------------
    // Completion Save / Discard Menu
    // -------------------------------------------------------------------------

    private function pushCompleteMenu() as Void {
        var title = WatchUi.loadResource(Rez.Strings.MenuCompleteTitle) as String;
        var saveLabel = WatchUi.loadResource(Rez.Strings.MenuSave) as String;
        var discardLabel = WatchUi.loadResource(Rez.Strings.MenuDiscard) as String;
        var moreCooldownLabel = WatchUi.loadResource(Rez.Strings.MenuResumeCooldown) as String;

        var menu = new WatchUi.Menu2({ :title => title });
        menu.addItem(new WatchUi.MenuItem(saveLabel, null, :save, null));
        menu.addItem(new WatchUi.MenuItem(discardLabel, null, :discard, null));
        menu.addItem(new WatchUi.MenuItem(moreCooldownLabel, null, :resume_cooldown, null));

        WatchUi.pushView(menu, new HIITCompleteMenuDelegate(_app), WatchUi.SLIDE_UP);
    }

    private function cancelEscHoldTimer() as Void {
        var holdTimer = _escHoldTimer;
        if (holdTimer != null) {
            holdTimer.stop();
            _escHoldTimer = null;
        }
    }
}

//! Save / Discard menu shown once all HIIT cycles and swimming Cool-down complete.
class HIITCompleteMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as HIITSwimApp;

    public function initialize(app as HIITSwimApp) {
        Menu2InputDelegate.initialize();
        _app = app;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :save) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _app.saveAndExit();
        } else if (id == :discard) {
            var prompt = WatchUi.loadResource(Rez.Strings.ConfirmDiscardPrompt) as String;
            var dialog = new WatchUi.Confirmation(prompt);
            WatchUi.pushView(dialog, new HIITDiscardConfirmDelegate(_app), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :resume_cooldown) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _app.resumeCooldown();
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

//! Secondary confirmation dialog ("Are you sure?") before discarding a HIIT Swim session.
class HIITDiscardConfirmDelegate extends WatchUi.ConfirmationDelegate {

    private var _app as HIITSwimApp;

    public function initialize(app as HIITSwimApp) {
        ConfirmationDelegate.initialize();
        _app = app;
    }

    public function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            _app.discardAndExit();
        }
        return true;
    }
}
