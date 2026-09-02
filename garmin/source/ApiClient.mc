import Toybox.Communications;
import Toybox.Lang;

// Thin wrapper around the two Simple Study endpoints this watch app talks
// to. Both are Supabase Edge Functions with verify_jwt disabled (see
// supabase/config.toml) -- watch-exchange trades a pairing code for a
// durable token, watch-schedule takes that token as a plain Bearer header
// and returns the day's schedule. No Supabase anon/publishable key is
// needed for either call.
module ApiClient {

    const API_BASE = "https://rlwfxvnwekkyfslxltus.supabase.co/functions/v1";

    function exchangeCode(code as String, callback as Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(API_BASE + "/watch-exchange", { "code" => code }, options, callback);
    }

    function fetchSchedule(token as String, dateStr as String, callback as Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + token },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(API_BASE + "/watch-schedule", { "date" => dateStr }, options, callback);
    }
}
