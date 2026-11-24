import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! Physical-button-only BehaviorDelegate for Garmin Venu 3 pool swimming.
//!
//! Touchscreen splash immunity:
//!   On Venu 3, BehaviorDelegate maps screen taps to onSelect() and right-swipes
//!   to onBack() BEFORE invoking raw onTap()/onSwipe(). Therefore onSelect(),
//!   onBack(), onNextPage(), onPreviousPage(), and onMenu() intentionally return
//!   false so that:
//!     - Touchscreen splashes fall through to onTap/onSwipe/onHold/onDrag/onRelease
//!       and are completely swallowed (return true).
//!     - Physical hardware buttons fall through to onKey() / onKeyPressed() /
//!       onKeyReleased(), giving exclusive hardware-button control underwater:
//!         * Top-Right (KEY_ENTER): Start -> Pause -> Open Pause Menu (Resume / Save / Discard / -1 Lap)
//!         * Bottom-Right (KEY_ESC): Exit when Ready; Short press = +1 valid lap;
//!           Long press (>= 700ms) = -1 valid lap.
class SwimDelegate extends WatchUi.BehaviorDelegate {

    private static const LONG_PRESS_THRESHOLD_MS as Number = 700;

    private var _app as SwimApp;
    private var _escHoldTimer as Timer.Timer?;
    private var _escPressedActive as Boolean;
    private var _escLongPressTriggered as Boolean;

    public function initialize(app as SwimApp) {
        BehaviorDelegate.initialize();
        _app = app;
        _escHoldTimer = null;
        _escPressedActive = false;
        _escLongPressTriggered = false;
    }

    // -------------------------------------------------------------------------
    // Behavior Overrides: Yield to raw InputDelegate handlers so touch gestures
    // and physical hardware keys can be strictly separated.
    // -------------------------------------------------------------------------

    public function onSelect() as Boolean {
        return false;
    }

    public function onBack() as Boolean {
        // Block accidental swipe-right back gestures during an active/paused swim
        // while allowing genuine physical KEY_ESC presses to fall through to onKey().
        if (!_escPressedActive && _app.getSessionState() != SwimApp.SESSION_READY) {
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
    // Touchscreen Splash Suppression (All Touch Gestures Ignored)
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
            if (_app.getSessionState() != SwimApp.SESSION_READY) {
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

        // Top-Right physical button (KEY_ENTER)
        if (key == WatchUi.KEY_ENTER) {
            handleEnterButton();
            return true;
        }

        // Bottom-Right physical button (KEY_ESC)
        if (key == WatchUi.KEY_ESC) {
            if (_app.getSessionState() == SwimApp.SESSION_READY) {
                // Allow normal app exit before a swim session has started
                return false;
            }

            cancelEscHoldTimer();

            if (_escLongPressTriggered) {
                // Long press already executed -1 lap; swallow release click
                return true;
            }

            // Short press -> manually add +1 valid lap
            _app.manualAddLap();
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

    //! Triggered when Bottom-Right (KEY_ESC) is held >= 700ms during an active or paused session.
    public function onEscLongPress() as Void {
        _escHoldTimer = null;
        _escLongPressTriggered = true;
        _app.manualRemoveLap();
    }

    // -------------------------------------------------------------------------
    // Internal Actions
    // -------------------------------------------------------------------------

    private function handleEnterButton() as Void {
        var state = _app.getSessionState();
        if (state == SwimApp.SESSION_READY) {
            _app.startSession();
        } else if (state == SwimApp.SESSION_ACTIVE) {
            _app.pauseSession();
        } else if (state == SwimApp.SESSION_PAUSED) {
            pushPauseMenu();
        }
    }

    private function pushPauseMenu() as Void {
        var title = WatchUi.loadResource(Rez.Strings.MenuTitle) as String;
        var resumeLabel = WatchUi.loadResource(Rez.Strings.MenuResume) as String;
        var saveLabel = WatchUi.loadResource(Rez.Strings.MenuSave) as String;
        var discardLabel = WatchUi.loadResource(Rez.Strings.MenuDiscard) as String;
        var removeLapLabel = WatchUi.loadResource(Rez.Strings.MenuRemoveLap) as String;

        var menu = new WatchUi.Menu2({ :title => title });
        menu.addItem(new WatchUi.MenuItem(resumeLabel, null, :resume, null));
        menu.addItem(new WatchUi.MenuItem(saveLabel, null, :save, null));
        menu.addItem(new WatchUi.MenuItem(discardLabel, null, :discard, null));
        menu.addItem(new WatchUi.MenuItem(removeLapLabel, null, :remove_lap, null));

        WatchUi.pushView(menu, new SwimPauseMenuDelegate(_app), WatchUi.SLIDE_UP);
    }

    private function cancelEscHoldTimer() as Void {
        var holdTimer = _escHoldTimer;
        if (holdTimer != null) {
            holdTimer.stop();
            _escHoldTimer = null;
        }
    }
}

//! Menu2InputDelegate for the paused session menu (Resume / Save / Discard / Undo Lap -1).
class SwimPauseMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as SwimApp;

    public function initialize(app as SwimApp) {
        Menu2InputDelegate.initialize();
        _app = app;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :resume) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _app.resumeSession();
        } else if (id == :save) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _app.saveAndExit();
        } else if (id == :discard) {
            var prompt = WatchUi.loadResource(Rez.Strings.ConfirmDiscardPrompt) as String;
            var dialog = new WatchUi.Confirmation(prompt);
            WatchUi.pushView(dialog, new SwimDiscardConfirmDelegate(_app), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :remove_lap) {
            _app.manualRemoveLap();
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

//! Secondary confirmation dialog ("Are you sure?") before discarding a recorded swim.
class SwimDiscardConfirmDelegate extends WatchUi.ConfirmationDelegate {

    private var _app as SwimApp;

    public function initialize(app as SwimApp) {
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
