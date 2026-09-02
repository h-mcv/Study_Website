import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

class SimpleStudyApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        ScheduleStore.exchangePairingCodeIfNeeded();
        registerBackgroundRefreshIfPossible();
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as Array<Views or InputDelegates>? {
        var view = new SimpleStudyWidgetView();
        return [ view, new SimpleStudyWidgetDelegate(view) ];
    }

    function getGlanceView() as Array<GlanceView or GlanceViewDelegate>? {
        return [ new SimpleStudyGlanceView() ];
    }

    // Fires when the student saves a new pairing code on the phone (Garmin
    // Connect Mobile -> this app -> App Settings), synced to the watch over
    // Bluetooth. This is the entire "login" step -- see ScheduleStore.mc.
    function onSettingsChanged() as Void {
        ScheduleStore.exchangePairingCodeIfNeeded();
        registerBackgroundRefreshIfPossible();
        WatchUi.requestUpdate();
    }

    function getServiceDelegate() as Array<System.ServiceDelegate> {
        return [ new ScheduleServiceDelegate() ];
    }

    // Delivers data a completed background refresh fetched (see
    // ScheduleServiceDelegate.onBackgroundResponse's Background.exit(...))
    // into the same Storage keys the foreground view/glance read from, so
    // whichever one is on screen next just shows what the background
    // service already fetched instead of waiting on its own request.
    function onBackgroundData(data as Dictionary?) as Void {
        if (data != null && data.get("items") != null) {
            Storage.setValue("scheduleItems", data.get("items"));
            Storage.setValue("scheduleItemsDate", data.get("date"));
        }
        WatchUi.requestUpdate();
    }

    private function registerBackgroundRefreshIfPossible() as Void {
        if (!ScheduleStore.hasToken()) {
            return;
        }
        if (Background has :registerForTemporalEvent) {
            // Garmin enforces a 5-minute floor regardless of what's asked
            // for; 15 minutes keeps the glance/reminders reasonably fresh
            // without calling more often than the platform allows anyway.
            Background.registerForTemporalEvent(new Time.Duration(15 * 60));
        }
    }
}

function getApp() as SimpleStudyApp {
    return Application.getApp() as SimpleStudyApp;
}
