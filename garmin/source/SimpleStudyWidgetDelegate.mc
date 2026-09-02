import Toybox.WatchUi;
import Toybox.Lang;

class SimpleStudyWidgetDelegate extends WatchUi.InputDelegate {

    private var _view as SimpleStudyWidgetView;

    function initialize(view as SimpleStudyWidgetView) {
        WatchUi.InputDelegate.initialize();
        _view = view;
    }

    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        var dir = swipeEvent.getDirection();
        if (dir == WatchUi.SWIPE_UP) {
            _view.scrollBy(1);
            return true;
        } else if (dir == WatchUi.SWIPE_DOWN) {
            _view.scrollBy(-1);
            return true;
        }
        return false;
    }

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        ScheduleStore.requestRefresh();
        return true;
    }
}
