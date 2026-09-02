import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;

// The always-visible swipe-glance row (Venu 3S "Widget Glances"): shows
// just the current or next event so it's readable without opening the full
// list. Reads from the same cached items the full widget/background
// service write to -- it never fetches on its own.
class SimpleStudyGlanceView extends WatchUi.GlanceView {

    function initialize() {
        WatchUi.GlanceView.initialize();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var label = "Simple Study";
        if (!ScheduleStore.hasToken()) {
            label = "Not paired – tap to set up";
        } else {
            var items = ScheduleStore.cachedItems();
            if (items == null) {
                label = "Loading schedule...";
            } else {
                var next = findCurrentOrNext(items, ScheduleStore.nowMinutes());
                label = next != null ? (next.get("icon") + "  " + next.get("name")) : "Nothing scheduled today";
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            0, dc.getHeight() / 2, Graphics.FONT_GLANCE, label,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // First item that hasn't ended yet -- already running (start <= now) or
    // the next one to start. `items` is pre-sorted by start (watch-schedule).
    private function findCurrentOrNext(items as Array, nowMin as Number) as Dictionary? {
        for (var i = 0; i < items.size(); i += 1) {
            var item = items[i] as Dictionary;
            var end = item.get("end") as Number;
            if (end >= 0 && end > nowMin) {
                return item;
            }
        }
        return null;
    }
}
