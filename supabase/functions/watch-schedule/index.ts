// Called by the Garmin watch with `Authorization: Bearer <watch token>`
// (minted by watch-exchange) and `?date=YYYY-MM-DD` (the watch's own local
// date -- deliberately not computed here, since the server has no reliable
// notion of the student's timezone). Returns that day's schedule as a flat,
// pre-sorted list of compact tiles.
//
// The resolution logic below (mondayIndex/mins/addDays/isHoliday/dayStatus/
// visibleOn/withinSchoolWindow/sourceMatches/segmentsForDate) is a direct
// port of the same-named functions in index.html (search those names there
// before changing anything here -- they must stay in sync, since this is
// re-deriving "today's timetable" from the exact same study_state.state
// blob the website itself renders from, not a separate source of truth).

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

const TYPE_ICON: Record<string, string> = {
  class: "◫", activity: "◌", sleep: "☾", meal: "◒", study: "✦", travel: "✈", examSitting: "📝",
};
const DEFAULT_EXAM_COLOR = "#E5484D";
const DEFAULT_EXAM_DURATION_MIN = 120; // sitting duration isn't tracked in the data model -- a reasonable placeholder for display/ordering only

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "GET") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) return jsonResponse({ error: "Missing watch token." }, 401);

    const url = new URL(req.url);
    const date = url.searchParams.get("date") ?? "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return jsonResponse({ error: "Missing or invalid ?date=YYYY-MM-DD." }, 400);

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const tokenHash = await sha256Hex(token);
    const { data: tokenRow } = await db.from("watch_tokens").select("user_id").eq("token_hash", tokenHash)
      .maybeSingle();
    if (!tokenRow) return jsonResponse({ error: "Not paired. Re-pair from the Simple Study website." }, 401);
    // Best-effort -- a failure here shouldn't fail the actual schedule request.
    db.from("watch_tokens").update({ last_used_at: new Date().toISOString() }).eq("token_hash", tokenHash).then(
      () => {},
    );

    const { data: stateRow } = await db.from("study_state").select("state").eq("user_id", tokenRow.user_id)
      .maybeSingle();
    const state = stateRow?.state ?? {};

    const items = buildItemsForDate(state, date);
    return jsonResponse({ date, generatedAt: new Date().toISOString(), items }, 200);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "Unknown error" }, 500);
  }
});

// ---- Ported schedule-resolution logic (see file header) ----

const dateFrom = (s: string) => {
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d);
};
const addDays = (s: string, n: number) => {
  const d = dateFrom(s);
  d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
const mins = (time: string) => {
  const [h, m] = String(time || "00:00").split(":").map(Number);
  return h * 60 + m;
};
const mondayIndex = (date: string) => {
  const js = dateFrom(date).getDay();
  return js === 0 ? 6 : js - 1;
};

function isHoliday(state: any, date: string) {
  return (state.holidays || []).find((h: any) => date >= h.start && date <= h.end);
}
function dayStatus(state: any, date: string) {
  const h = isHoliday(state, date);
  if (h) return h.kind;
  return mondayIndex(date) >= 5 ? "weekend" : "normal";
}
function visibleOn(state: any, eventObj: any, sourceDate: string) {
  const status = dayStatus(state, sourceDate);
  if (eventObj.type === "sleep" || eventObj.type === "meal") return true;
  if (status === "holiday") return false;
  if ((status === "dayoff" || status === "weekend") && (eventObj.type === "class" || eventObj.inSchool)) return false;
  return true;
}
function latestExamDateAfter(state: any, afterDate: string) {
  let latest: string | null = null;
  (state.exams || []).forEach((exam: any) => {
    (exam.sittings || []).forEach((s: any) => {
      if (s.date && s.date > afterDate && (!latest || s.date > latest)) latest = s.date;
    });
    if (exam.end && exam.end > afterDate && (!latest || exam.end > latest)) latest = exam.end;
  });
  return latest;
}
function withinSchoolWindow(state: any, eventObj: any, date: string) {
  if (eventObj.examPeriodId) {
    const ex = (state.exams || []).find((x: any) => x.id === eventObj.examPeriodId);
    return ex ? (date >= ex.start && date <= ex.end) : false;
  }
  const { termStart, termEnd } = state.settings || {};
  if (!termStart || !termEnd) return true;
  if (date < termStart) return false;
  if (date <= termEnd) return true;
  if (eventObj.type !== "study") return false;
  const examTail = latestExamDateAfter(state, termEnd);
  return examTail ? date <= examTail : false;
}
function sourceMatches(state: any, eventObj: any, sourceDate: string, slot: any) {
  if ((eventObj.skipDates || []).includes(sourceDate)) return false;
  if (eventObj.date) return eventObj.date === sourceDate;
  return (slot.days || []).includes(mondayIndex(sourceDate)) && withinSchoolWindow(state, eventObj, sourceDate);
}
function segmentsForDate(state: any, date: string) {
  const answer: any[] = [];
  const previous = addDays(date, -1);
  (state.events || []).forEach((e: any) => {
    if (e.examPeriodId) return;
    (e.slots || []).forEach((slot: any) => {
      const start = mins(slot.start), end = mins(slot.end), overnight = end <= start;
      if (sourceMatches(state, e, date, slot) && visibleOn(state, e, date)) {
        answer.push({ event: e, start, end: overnight ? 1440 : end });
      }
      if (overnight && sourceMatches(state, e, previous, slot) && visibleOn(state, e, previous)) {
        answer.push({ event: e, start: 0, end });
      }
    });
  });
  return answer.sort((a, b) => a.start - b.start || a.end - b.end);
}

function buildItemsForDate(state: any, date: string) {
  const items = segmentsForDate(state, date).map((seg) => ({
    start: seg.start,
    end: seg.end,
    name: seg.event.name || "Untitled",
    type: seg.event.type,
    icon: TYPE_ICON[seg.event.type] || "◫",
    color: seg.event.color || "#5B5BD6",
  }));

  (state.exams || []).forEach((exam: any) => {
    (exam.sittings || []).forEach((sitting: any) => {
      if (sitting.date !== date) return;
      const subject = (state.subjects || []).find((s: any) => s.id === sitting.subjectId);
      const start = sitting.time ? mins(sitting.time) : -1; // -1 = time not set, sorts first, watch shows "time TBC"
      items.push({
        start,
        end: start < 0 ? -1 : start + DEFAULT_EXAM_DURATION_MIN,
        name: subject?.name ? `${subject.name} exam` : (exam.name || "Exam"),
        type: "examSitting",
        icon: TYPE_ICON.examSitting,
        color: subject?.color || DEFAULT_EXAM_COLOR,
      });
    });
  });

  return items.sort((a, b) => a.start - b.start || a.end - b.end);
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
