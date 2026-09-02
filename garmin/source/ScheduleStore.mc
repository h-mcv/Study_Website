import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Time;
import Toybox.Time.Gregorian;

// All persistent watch-side state lives here: the pairing code -> token
// exchange, the cached schedule, and the small clock helpers everything
// else (foreground view, glance, background service) needs. Kept
// deliberately un-annotated (no (:background)/(:glance) tags) so the same
// code is compiled into every build variant -- see garmin/README.md's note
// on Monkey C memory-context annotations if a build ever complains a
// symbol here isn't available from the background service.
module ScheduleStore {

    const STORAGE_TOKEN = "watchToken";
    const STORAGE_LAST_CODE = "lastExchangedCode";
    const STORAGE_ITEMS = "scheduleItems";
    const STORAGE_ITEMS_DATE = "scheduleItemsDate";

    function hasToken() as Boolean {
        return Storage.getValue(STORAGE_TOKEN) != null;
    }

    // Called on app start and whenever a setting changes. A pairing code is
    // single-use server-side, so this only fires the exchange when the code
    // actually differs from the last one we successfully exchanged --
    // otherwise every onSettingsChanged() (which can fire for unrelated
    // reasons) would burn through re-pairing for no reason.
    function exchangePairingCodeIfNeeded() as Void {
        var code = Properties.getValue("pairingCode");
        if (code == null || code.equals("")) {
            return;
        }
        var last = Storage.getValue(STORAGE_LAST_CODE);
        if (last != null && last.equals(code)) {
            return;
        }
        ApiClient.exchangeCode(code, method(:onExchangeResponse));
    }

    function onExchangeResponse(responseCode as Number, data as Dictionary?) as Void {
        if (responseCode == 200 && data != null && data.get("token") != null) {
            Storage.setValue(STORAGE_TOKEN, data.get("token"));
            Storage.setValue(STORAGE_LAST_CODE, Properties.getValue("pairingCode"));
            requestRefresh();
        } else {
            System.println("Simple Study: pairing failed, HTTP " + responseCode);
        }
        WatchUi.requestUpdate();
    }

    function requestRefresh() as Void {
        var token = Storage.getValue(STORAGE_TOKEN);
        if (token == null) {
            return;
        }
        ApiClient.fetchSchedule(token, todayString(), method(:onScheduleResponse));
    }

    function onScheduleResponse(responseCode as Number, data as Dictionary?) as Void {
        if (responseCode == 200 && data != null) {
            Storage.setValue(STORAGE_ITEMS, data.get("items"));
            Storage.setValue(STORAGE_ITEMS_DATE, data.get("date"));
        } else if (responseCode == 401) {
            // Token invalid/expired server-side (e.g. watch was unpaired
            // from the website) -- drop it so the UI falls back to the
            // "not paired" prompt instead of showing stale data forever.
            Storage.deleteValue(STORAGE_TOKEN);
            Storage.deleteValue(STORAGE_LAST_CODE);
        } else {
            System.println("Simple Study: schedule fetch failed, HTTP " + responseCode);
        }
        WatchUi.requestUpdate();
    }

    function cachedItems() as Array? {
        return Storage.getValue(STORAGE_ITEMS) as Array?;
    }

    function todayString() as String {
        var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return now.year.format("%04d") + "-" + now.month.format("%02d") + "-" + now.day.format("%02d");
    }

    function nowMinutes() as Number {
        var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return (now.hour * 60) + now.min;
    }
}
