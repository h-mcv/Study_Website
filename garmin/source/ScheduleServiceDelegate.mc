import Toybox.Background;
import Toybox.Application.Storage;
import Toybox.Attention;
import Toybox.Lang;
import Toybox.System;

// Runs in Garmin's separate, memory-constrained background context (64KB on
// the Venu 3S -- see garmin/README.md) on whatever interval
// SimpleStudyApp.registerBackgroundRefreshIfPossible() asked for, floored
// at 5 minutes by the platform regardless. Must call Background.exit(...)
// within 30 seconds or the OS kills it.
(:background)
class ScheduleServiceDelegate extends System.ServiceDelegate {

    function initialize() {
        System.ServiceDelegate.initialize();
    }

    function onTemporalEvent() as Void {
        var token = Storage.getValue("watchToken");
        if (token == null) {
            Background.exit(null);
            return;
        }
        ApiClient.fetchSchedule(token, ScheduleStore.todayString(), method(:onBackgroundResponse));
    }

    (:background)
    function onBackgroundResponse(responseCode as Number, data as Dictionary?) as Void {
        if (responseCode == 200 && data != null) {
            maybeVibrateForUpcoming(data.get("items") as Array?);
            Background.exit(data);
        } else {
            Background.exit(null);
        }
    }

    // Reminder mechanism: the only signal a third-party Connect IQ app can
    // give outside its own UI is vibration/tone (Monkey C has no
    // OS-notification API), and this check only runs once per background
    // wake -- i.e. accurate to within the ~15 minute refresh window, not to
    // the minute. Documented as a known limitation in garmin/README.md.
    (:background)
    function maybeVibrateForUpcoming(items as Array?) as Void {
        if (items == null) {
            return;
        }
        var nowMin = ScheduleStore.nowMinutes();
        for (var i = 0; i < items.size(); i += 1) {
            var item = items[i] as Dictionary;
            var start = item.get("start") as Number;
            if (start >= 0 && start >= nowMin && (start - nowMin) <= 5) {
                if (Attention has :vibrate) {
                    Attention.vibrate([new Attention.VibeProfile(50, 500)]);
                }
                return;
            }
        }
    }
}
