import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;

// Full-screen scrollable list: today's current event plus everything still
// to come, styled to echo the website's timetable tiles (a colored block
// per event, its own icon/name/time range, current event outlined). Swipe
// up/down to scroll (SimpleStudyWidgetDelegate); tap to force a refresh.
class SimpleStudyWidgetView extends WatchUi.View {

    private const TILE_HEIGHT = 64;
    private const TILE_GAP = 6;
    private const SWIPE_STEP = 90;

    private var _scrollOffset as Number = 0;
    private var _refreshTimer as Timer.Timer?;

    function initialize() {
        View.initialize();
    }

    // While the widget is actually on screen we poll on a short interval --
    // this is the "live" part; off-screen freshness is the background
    // service's job (ScheduleServiceDelegate, floored at 5 min by the OS).
    function onShow() as Void {
        ScheduleStore.requestRefresh();
        _refreshTimer = new Timer.Timer();
        _refreshTimer.start(method(:onRefreshTick), 45000, true);
    }

    function onHide() as Void {
        if (_refreshTimer != null) {
            _refreshTimer.stop();
            _refreshTimer = null;
        }
    }

    function onRefreshTick() as Void {
        ScheduleStore.requestRefresh();
    }

    function scrollBy(direction as Number) as Void {
        _scrollOffset += direction * SWIPE_STEP;
        if (_scrollOffset < 0) {
            _scrollOffset = 0;
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        if (!ScheduleStore.hasToken()) {
            drawMessage(dc, "Not paired\n\nOpen Garmin Connect > this app's Settings and enter a pairing code from the Simple Study website.");
            return;
        }

        var items = ScheduleStore.cachedItems();
        if (items == null) {
            drawMessage(dc, "Loading schedule...");
            return;
        }
        if (items.size() == 0) {
            drawMessage(dc, "Nothing scheduled\nfor today.");
            return;
        }

        var nowMin = ScheduleStore.nowMinutes();
        var width = dc.getWidth();
        var height = dc.getHeight();
        // Clamp scroll so it can't run past the last tile.
        var maxOffset = ((items.size()) * (TILE_HEIGHT + TILE_GAP)) - height + TILE_GAP;
        if (maxOffset < 0) {
            maxOffset = 0;
        }
        if (_scrollOffset > maxOffset) {
            _scrollOffset = maxOffset;
        }

        var y = -_scrollOffset;
        for (var i = 0; i < items.size(); i += 1) {
            if (y + TILE_HEIGHT >= 0 && y <= height) {
                drawTile(dc, items[i] as Dictionary, y, width, nowMin);
            }
            y += TILE_HEIGHT + TILE_GAP;
        }
    }

    private function drawTile(dc as Graphics.Dc, item as Dictionary, y as Number, width as Number, nowMin as Number) as Void {
        var color = parseColor(item.get("color") as String?);
        var start = item.get("start") as Number;
        var end = item.get("end") as Number;
        var isCurrent = start >= 0 && start <= nowMin && nowMin < end;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(4, y, width - 8, TILE_HEIGHT, 10);

        if (isCurrent) {
            dc.setPenWidth(3);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(4, y, width - 8, TILE_HEIGHT, 10);
            dc.setPenWidth(1);
        }

        var textColor = contrastColor(color);
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        var timeLabel = start < 0 ? "Time TBC" : (formatTime(start) + " - " + formatTime(end));
        dc.drawText(16, y + 8, Graphics.FONT_XTINY, timeLabel, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(16, y + 27, Graphics.FONT_TINY, item.get("icon") + "  " + item.get("name"), Graphics.TEXT_JUSTIFY_LEFT);
    }

    private function drawMessage(dc as Graphics.Dc, text as String) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function formatTime(mins as Number) as String {
        var h = (mins / 60) % 24;
        var m = mins % 60;
        return h.format("%02d") + ":" + m.format("%02d");
    }

    private function parseColor(hex as String?) as Number {
        if (hex == null || hex.length() < 7) {
            return Graphics.COLOR_DK_GRAY;
        }
        var r = hex.substring(1, 3).toNumberWithBase(16);
        var g = hex.substring(3, 5).toNumberWithBase(16);
        var b = hex.substring(5, 7).toNumberWithBase(16);
        return (r << 16) | (g << 8) | b;
    }

    private function contrastColor(color as Number) as Number {
        var r = (color >> 16) & 0xFF;
        var g = (color >> 8) & 0xFF;
        var b = color & 0xFF;
        var luminance = (0.299 * r) + (0.587 * g) + (0.114 * b);
        return luminance > 140 ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
    }
}
