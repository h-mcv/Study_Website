// Single entry point for the site's admin dashboard (Search -> type "admin").
//
// Two independent gates have to both pass before ANY admin data moves, on
// EVERY request this function serves, not just the first one:
//   1. The caller's Supabase-signed JWT (from Authorization: Bearer ..., sent
//      automatically by supabaseClient.functions.invoke) decodes to a real,
//      currently-signed-in user whose email matches ADMIN_EMAIL exactly.
//   2. The request body carries a still-valid `adminToken` -- an HMAC-signed
//      token this function itself minted for that exact user id, from the
//      `unlock` action, after checking ADMIN_MODE_PASSWORD. Signing means a
//      token can't be forged or edited (e.g. to swap in a different user id)
//      without ADMIN_SESSION_SECRET, which never leaves this function.
//
// ADMIN_EMAIL / ADMIN_MODE_PASSWORD / ADMIN_SESSION_SECRET are Supabase
// function secrets (`supabase secrets set ...`) -- never in index.html, never
// in this repo. Losing this file or the repo leaks no password.
//
// Every non-"unlock" action below runs against a service-role client, which
// bypasses RLS entirely -- that's the whole point (an admin has to be able to
// see/change everyone's row, not just their own), so the two gates above are
// the ONLY thing stopping this function from being a fully open door into
// every user's account. Treat any change here as security-sensitive.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ADMIN_TOKEN_TTL_MS = 6 * 60 * 60 * 1000; // 6 hours -- re-enter the password after this

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const adminEmail = (Deno.env.get("ADMIN_EMAIL") || "").trim().toLowerCase();
    const adminPassword = Deno.env.get("ADMIN_MODE_PASSWORD") || "";
    const sessionSecret = Deno.env.get("ADMIN_SESSION_SECRET") || "";
    if (!adminEmail || !adminPassword || !sessionSecret) {
      console.error("admin-api: missing ADMIN_EMAIL / ADMIN_MODE_PASSWORD / ADMIN_SESSION_SECRET secret(s).");
      return jsonResponse({ error: "Admin mode is not configured on the server." }, 500);
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const authClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await authClient.auth.getUser();
    if (!user || (user.email || "").trim().toLowerCase() !== adminEmail) {
      // Deliberately the same generic error whether the caller is signed out,
      // signed in as someone else, or the email just doesn't match -- never
      // confirm or deny which case it is.
      return jsonResponse({ error: "Not authorized." }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const action = body.action;

    if (action === "unlock") {
      if (!timingSafeEqual(String(body.password || ""), adminPassword)) {
        // Small fixed delay on a wrong password so this can't be turned into
        // a fast online-guessing loop against a single short password.
        await new Promise((r) => setTimeout(r, 400));
        return jsonResponse({ error: "Wrong password." }, 401);
      }
      const token = await signAdminToken(user.id, sessionSecret);
      return jsonResponse({ token: token.token, expiresAt: token.expiresAt });
    }

    // Every action below this line needs a valid admin token, minted by
    // "unlock" above, for this exact caller.
    const verified = await verifyAdminToken(String(body.adminToken || ""), user.id, sessionSecret);
    if (!verified) return jsonResponse({ error: "Admin session expired -- re-enter the password." }, 401);

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    switch (action) {
      case "list-users":
        return jsonResponse(await listUsers(db));
      case "get-user":
        return jsonResponse(await getUser(db, String(body.userId || "")));
      case "create-user": {
        const email = String(body.email || "").trim();
        const pw = String(body.password || "");
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return jsonResponse({ error: "Enter a valid email address." }, 400);
        if (pw.length < 8) return jsonResponse({ error: "Password must be at least 8 characters." }, 400);
        // email_confirm: true mirrors the Supabase dashboard's manual "create user"
        // flow -- the account is usable immediately with this password, no
        // confirmation email. Same tradeoff the dashboard makes when an admin
        // (rather than the user themselves) sets the password directly.
        const { data, error } = await db.auth.admin.createUser({ email, password: pw, email_confirm: true });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true, userId: data.user?.id });
      }
      case "set-password": {
        const pw = String(body.newPassword || "");
        if (pw.length < 8) return jsonResponse({ error: "Password must be at least 8 characters." }, 400);
        const { error } = await db.auth.admin.updateUserById(body.userId, { password: pw });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "send-reset-email": {
        const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
        const { error } = await anon.auth.resetPasswordForEmail(String(body.email || ""), {
          redirectTo: String(body.redirectTo || ""),
        });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "generate-magic-link": {
        const { data, error } = await db.auth.admin.generateLink({
          type: "magiclink",
          email: String(body.email || ""),
          options: { redirectTo: String(body.redirectTo || "") },
        });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ link: data.properties?.action_link });
      }
      case "ban-user": {
        const { error } = await db.auth.admin.updateUserById(body.userId, {
          ban_duration: String(body.duration || "876000h"),
        });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "unban-user": {
        const { error } = await db.auth.admin.updateUserById(body.userId, { ban_duration: "none" });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "delete-user": {
        if (body.userId === user.id) return jsonResponse({ error: "Refusing to delete the admin account itself." }, 400);
        const { error } = await db.auth.admin.deleteUser(String(body.userId || ""));
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "patch-state": {
        const userId = String(body.userId || "");
        const patch = body.patch;
        if (!patch || typeof patch !== "object") return jsonResponse({ error: "Missing patch object." }, 400);
        const { data: row, error: readErr } = await db.from("study_state").select("state").eq("user_id", userId)
          .maybeSingle();
        if (readErr) return jsonResponse({ error: readErr.message }, 400);
        const merged = { ...(row?.state || {}), ...patch };
        const { error } = await db.from("study_state").upsert({ user_id: userId, state: merged });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true, state: merged });
      }
      case "replace-state": {
        const userId = String(body.userId || "");
        if (!body.state || typeof body.state !== "object") return jsonResponse({ error: "Missing state object." }, 400);
        const { error } = await db.from("study_state").upsert({ user_id: userId, state: body.state });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "analytics-overview":
        return jsonResponse(await analyticsOverview(db));
      case "export-csv":
        return jsonResponse({ csv: await exportCsv(db) });
      case "list-announcements": {
        const { data, error } = await db.from("announcements").select("*").order("created_at", { ascending: false });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ announcements: data });
      }
      case "create-announcement": {
        const kind = String(body.kind || "");
        const message = String(body.message || "").trim();
        if (kind !== "banner" && kind !== "popup") return jsonResponse({ error: "kind must be 'banner' or 'popup'." }, 400);
        if (!message) return jsonResponse({ error: "Message can't be empty." }, 400);
        if (message.length > 2000) return jsonResponse({ error: "Message is too long (max 2000 characters)." }, 400);
        const { error } = await db.from("announcements").insert({ kind, message });
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "set-announcement-active": {
        const { error } = await db.from("announcements").update({ active: !!body.active }).eq("id", body.id);
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      case "delete-announcement": {
        const { error } = await db.from("announcements").delete().eq("id", body.id);
        if (error) return jsonResponse({ error: error.message }, 400);
        return jsonResponse({ ok: true });
      }
      default:
        return jsonResponse({ error: `Unknown action "${action}".` }, 400);
    }
  } catch (err) {
    console.error("admin-api error:", err);
    return jsonResponse({ error: "Unexpected server error." }, 500);
  }
});

async function listUsers(db: ReturnType<typeof createClient>) {
  const users: any[] = [];
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Error(error.message);
    users.push(...data.users);
    if (data.users.length < 1000) break;
  }
  const { data: metricsRows, error: metricsErr } = await db.rpc("admin_user_metrics");
  if (metricsErr) throw new Error(metricsErr.message);
  const metricsByUser = new Map((metricsRows || []).map((r: any) => [r.user_id, r.metrics]));
  return {
    users: users.map((u) => ({
      id: u.id,
      email: u.email,
      createdAt: u.created_at,
      lastSignInAt: u.last_sign_in_at,
      emailConfirmedAt: u.email_confirmed_at,
      bannedUntil: u.banned_until || null,
      provider: u.app_metadata?.provider || "email",
      metrics: metricsByUser.get(u.id) || null,
    })),
  };
}

async function getUser(db: ReturnType<typeof createClient>, userId: string) {
  if (!userId) throw new Error("Missing userId.");
  const [{ data: authData, error: authErr }, { data: stateRow, error: stateErr }, { data: events, error: eventsErr }] =
    await Promise.all([
      db.auth.admin.getUserById(userId),
      db.from("study_state").select("state, updated_at").eq("user_id", userId).maybeSingle(),
      db.from("feature_events").select("event, meta, created_at").eq("user_id", userId).order("created_at", {
        ascending: false,
      }).limit(100),
    ]);
  if (authErr) throw new Error(authErr.message);
  if (stateErr) throw new Error(stateErr.message);
  if (eventsErr) throw new Error(eventsErr.message);
  const u = authData.user;
  return {
    authUser: u && {
      id: u.id,
      email: u.email,
      createdAt: u.created_at,
      lastSignInAt: u.last_sign_in_at,
      emailConfirmedAt: u.email_confirmed_at,
      bannedUntil: u.banned_until || null,
      provider: u.app_metadata?.provider || "email",
    },
    state: stateRow?.state || null,
    stateUpdatedAt: stateRow?.updated_at || null,
    recentEvents: events || [],
  };
}

// Pearson correlation coefficient; null when there isn't enough spread/data
// to make the number meaningful (fewer than 3 points, or one side constant).
function pearson(points: { x: number; y: number }[]): number | null {
  const n = points.length;
  if (n < 3) return null;
  const mx = points.reduce((s, p) => s + p.x, 0) / n;
  const my = points.reduce((s, p) => s + p.y, 0) / n;
  let num = 0, dx2 = 0, dy2 = 0;
  for (const p of points) {
    const dx = p.x - mx, dy = p.y - my;
    num += dx * dy;
    dx2 += dx * dx;
    dy2 += dy * dy;
  }
  if (dx2 === 0 || dy2 === 0) return null;
  return num / Math.sqrt(dx2 * dy2);
}

// Raw `feature_events.event` values are the app's internal data-action names
// (e.g. "sm-log-rate", "cao-calc-add") -- meaningful to the code, meaningless
// to a human reading the Analytics tab, and there are 200+ of them since the
// client logs essentially every click (see index.html's capture-phase
// listener). This maps that whole vocabulary down to the plain-English
// feature set a person actually cares about, many-to-one, so the tab shows
// "Used: Study Mode" once with a real count instead of a dozen near-tied
// sm-* rows. Anything not listed falls back to a humanized version of the
// raw name (see humanizeEvent below) rather than being dropped silently, so
// a newly added action still shows up -- just not renamed until it's added
// here.
const FEATURE_LABELS: Record<string, string> = {
  // Page navigation (composite "view:<id>", set client-side from data-view)
  "view:dashboard": "Viewed: Dashboard",
  "view:timetable": "Viewed: Timetable",
  "view:classes": "Viewed: Classes & Topics",
  "view:tests-exams": "Viewed: Tests & Exams",
  "view:study": "Viewed: Study page",
  "view:tasks": "Viewed: Tasks",
  "view:cao": "Viewed: CAO Planning",
  "view:closet": "Viewed: Sparky's Closet",
  "view:insights": "Viewed: Insights",
  "view:tools": "Viewed: Tools",
  "nav-cao": "Viewed: CAO Planning",
  "nav-classes": "Viewed: Classes & Topics",

  // Tools (composite "tools-open:<id>", set client-side from data-tool)
  "tools-open:formulas": "Used: Formula Book",
  "tools-open:cao": "Used: CAO Points Calculator",
  "tools-open:quadratic": "Used: Quadratic Solver",
  "tools-back": "Used: Tools",
  "quad-format": "Used: Quadratic Solver",
  "cao-calc-add": "Used: CAO Points Calculator",
  "cao-calc-find-combos": "Used: CAO Points Calculator",
  "cao-calc-hlmaths": "Used: CAO Points Calculator",
  "cao-calc-remove": "Used: CAO Points Calculator",
  "cao-calc-restart": "Used: CAO Points Calculator",
  "cao-calc-set-maths": "Used: CAO Points Calculator",
  "cao-calc-tab": "Used: CAO Points Calculator",
  "formula-page-next": "Used: Formula Book",
  "formula-page-prev": "Used: Formula Book",
  "formula-search-go": "Used: Formula Book",
  "formula-toc-collapse-toggle": "Used: Formula Book",
  "formula-toc-select": "Used: Formula Book",
  "formula-toc-toggle": "Used: Formula Book",
  "formula-search-ai": "Used AI: Formula Book search",

  // Timetable / calendar
  "add-slot": "Used: Timetable", "remove-slot": "Used: Timetable", "change-week": "Used: Timetable",
  "today": "Used: Timetable", "toggle-day": "Used: Timetable", "set-event-type": "Used: Timetable",
  "open-event-form": "Used: Timetable", "open-event-form-exam": "Used: Timetable",
  "save-event": "Used: Timetable", "delete-event": "Used: Timetable", "delete-event-slot": "Used: Timetable",
  "open-holiday-form": "Used: Timetable", "save-holiday": "Used: Timetable", "delete-holiday": "Used: Timetable",
  "picker-cal-clear": "Picked a date or time", "picker-cal-nav": "Picked a date or time",
  "picker-cal-pick": "Picked a date or time", "picker-cal-today": "Picked a date or time",
  "picker-time-set": "Picked a date or time", "open-picker": "Picked a date or time",
  "study-day": "Logged study time on the Timetable", "study-today": "Logged study time on the Timetable",
  "start-log": "Logged study time on the Timetable", "cancel-log": "Logged study time on the Timetable",
  "submit-log": "Logged study time on the Timetable",

  // Tasks
  "save-task": "Used: Tasks", "open-task": "Used: Tasks", "toggle-task": "Used: Tasks",

  // Classes & topics
  "classtopic-add": "Used: Classes & Topics", "classtopic-back-to-learning": "Used: Classes & Topics",
  "classtopic-cancel-edit": "Used: Classes & Topics", "classtopic-complete": "Used: Classes & Topics",
  "classtopic-delete": "Used: Classes & Topics", "classtopic-pause": "Used: Classes & Topics",
  "classtopic-rate": "Used: Classes & Topics", "classtopic-save-edit": "Used: Classes & Topics",
  "classtopic-start-edit": "Used: Classes & Topics", "classtopic-unpause": "Used: Classes & Topics",
  "open-topic-detail": "Used: Classes & Topics", "open-subject-detail": "Used: Classes & Topics",
  "open-subject-performance": "Used: Classes & Topics", "subject-section": "Used: Classes & Topics",

  // Tests & exams
  "edit-exam": "Used: Tests & Exams", "delete-exam": "Used: Tests & Exams",
  "clear-exam-result": "Used: Tests & Exams", "open-exam-result": "Used: Tests & Exams",
  "save-exam-result": "Used: Tests & Exams", "open-past-paper-choice": "Used: Tests & Exams",
  "open-past-paper-result": "Used: Tests & Exams", "save-past-paper-result": "Used: Tests & Exams",
  "clear-past-paper-result": "Used: Tests & Exams", "pp-result-toggle-unknown": "Used: Tests & Exams",
  "result-set-topic": "Used: Tests & Exams", "result-toggle-unknown": "Used: Tests & Exams",
  "open-exam-task-form": "Used: Tests & Exams", "save-exam-task": "Used: Tests & Exams",
  "delete-exam-task": "Used: Tests & Exams", "add-exam-task-milestone": "Used: Tests & Exams",
  "delete-exam-task-milestone": "Used: Tests & Exams", "toggle-exam-task-milestone": "Used: Tests & Exams",
  "examwizard-add-topic": "Created a test/exam", "examwizard-attach-photo": "Created a test/exam",
  "examwizard-back-to-0": "Created a test/exam", "examwizard-back-to-1": "Created a test/exam",
  "examwizard-back-to-test-datetime": "Created a test/exam", "examwizard-back-to-test-subject": "Created a test/exam",
  "examwizard-finish": "Created a test/exam", "examwizard-finish-test": "Created a test/exam",
  "examwizard-next-0": "Created a test/exam", "examwizard-next-1": "Created a test/exam",
  "examwizard-next-2": "Created a test/exam", "examwizard-next-subject": "Created a test/exam",
  "examwizard-next-test-datetime": "Created a test/exam", "examwizard-next-test-subject": "Created a test/exam",
  "examwizard-pick-kind": "Created a test/exam", "examwizard-pick-test-subject": "Created a test/exam",
  "examwizard-pick-type": "Created a test/exam", "examwizard-remove-photo": "Created a test/exam",
  // Not "Used AI" here even though this click triggers an AI call --
  // processUserPrompt() already logs ai_study_assistant_chat itself for
  // that, so labeling this one too would double-count the same click.
  "examwizard-send-photo": "Created a test/exam", "examwizard-skip-subject": "Created a test/exam",

  // Study mode
  "start-study-mode": "Used: Study Mode", "sm-choose-finish": "Used: Study Mode",
  "sm-choose-next": "Used: Study Mode", "sm-finish-now": "Used: Study Mode",
  "sm-finish-task": "Used: Study Mode", "sm-log-rate": "Used: Study Mode",
  "sm-log-toggle-task": "Used: Study Mode", "sm-log-toggle-topic": "Used: Study Mode",
  "sm-minimize": "Used: Study Mode", "sm-restore": "Used: Study Mode",
  "sm-save-log": "Used: Study Mode", "sm-start-next-task": "Used: Study Mode",
  "sm-start-open": "Used: Study Mode", "sm-start-timed": "Used: Study Mode",
  "sm-toggle-countdown": "Used: Study Mode",

  // CAO planning page (distinct from the standalone Tools calculator)
  "open-cao-course-form": "Used: CAO Planning", "save-cao-course": "Used: CAO Planning",
  "delete-cao-course": "Used: CAO Planning",

  // Sparky's Closet
  "closet-equip-color": "Used: Sparky's Closet", "closet-preview-pose": "Used: Sparky's Closet",
  "closet-unlock-color": "Used: Sparky's Closet", "closet-unlock-expression": "Used: Sparky's Closet",
  "pick-color": "Used: Sparky's Closet",

  // Vocab & verb word banks + essay marking (language tools)
  "add-verb": "Used: Vocab/Verb Word Banks", "add-vocab": "Used: Vocab/Verb Word Banks",
  "delete-verb": "Used: Vocab/Verb Word Banks", "delete-vocab": "Used: Vocab/Verb Word Banks",
  "open-add-verb": "Used: Vocab/Verb Word Banks", "open-add-vocab": "Used: Vocab/Verb Word Banks",
  "open-verb-detail": "Used: Vocab/Verb Word Banks", "open-vocab-detail": "Used: Vocab/Verb Word Banks",
  "verb-add-alt": "Used: Vocab/Verb Word Banks", "verb-alternatives": "Used: Vocab/Verb Word Banks",
  "verb-sort": "Used: Vocab/Verb Word Banks", "vocab-add-alt": "Used: Vocab/Verb Word Banks",
  "vocab-alternatives": "Used: Vocab/Verb Word Banks", "vocab-sort": "Used: Vocab/Verb Word Banks",
  "wordbank-tab": "Used: Vocab/Verb Word Banks", "toggle-tense": "Used: Vocab/Verb Word Banks",
  "toggle-tense-panel": "Used: Vocab/Verb Word Banks", "vocab-ocr-cancel": "Used: Vocab/Verb Word Banks",
  "vocab-ocr-confirm": "Used: Vocab/Verb Word Banks", "vocab-ocr-edit-english": "Used: Vocab/Verb Word Banks",
  "vocab-ocr-edit-phrase": "Used: Vocab/Verb Word Banks", "vocab-ocr-toggle": "Used: Vocab/Verb Word Banks",
  "pick-vocab-photo": "Used: Vocab/Verb Word Banks",
  "vocab-search": "Used AI: Vocab/Verb search", "verb-search": "Used AI: Vocab/Verb search",
  "vocab-search-clear": "Used: Vocab/Verb Word Banks", "verb-search-clear": "Used: Vocab/Verb Word Banks",
  "essay-mode": "Used: Essay Marking tool", "discard-essay-result": "Used: Essay Marking tool",
  "save-essay-result": "Used: Essay Marking tool", "delete-essay-history": "Used: Essay Marking tool",
  "view-essay-history": "Used: Essay Marking tool", "pick-essay-photo": "Used: Essay Marking tool",
  "toggle-essay-topic": "Used: Essay Marking tool", "mark-essay": "Used AI: Essay marking",

  // Main AI study assistant ("Sparky" chat widget) -- logged explicitly from
  // processUserPrompt() since its Send button has its own click listener
  // rather than a data-action. Total chat volume, regardless of purpose.
  "ai_study_assistant_chat": "Used AI: Study assistant chat (Sparky)",

  // What Sparky was actually asked to DO, broken out by which tool (if any)
  // the model reached for -- see AI_TOOLS in index.html for the full set and
  // executeAiTool()/the functionCalls loop in processUserPrompt() for where
  // each ai_tool:<name> event gets logged. "none" means a turn that got a
  // plain text reply with no action taken (a general question).
  "ai_tool:none": "Used AI: Asked Sparky a general question",
  "ai_tool:read_app_state": "Used AI: Asked Sparky to look something up",
  "ai_tool:add_class_topic": "Used AI: Managed class topics",
  "ai_tool:update_class_topic": "Used AI: Managed class topics",
  "ai_tool:add_event": "Used AI: Managed timetable events",
  "ai_tool:update_event": "Used AI: Managed timetable events",
  "ai_tool:delete_event": "Used AI: Managed timetable events",
  "ai_tool:skip_event_occurrence": "Used AI: Managed timetable events",
  "ai_tool:add_task": "Used AI: Managed tasks",
  "ai_tool:update_task": "Used AI: Managed tasks",
  "ai_tool:delete_task": "Used AI: Managed tasks",
  "ai_tool:toggle_task_done": "Used AI: Managed tasks",
  "ai_tool:add_holiday": "Used AI: Managed holidays/days off",
  "ai_tool:delete_holiday": "Used AI: Managed holidays/days off",
  "ai_tool:update_settings": "Used AI: Changed settings",
  "ai_tool:update_subject": "Used AI: Changed settings",
  "ai_tool:open_study_preferences_form": "Used AI: Changed settings",
  "ai_tool:find_free_slot": "Used AI: Asked Sparky to plan/schedule study",
  "ai_tool:auto_plan": "Used AI: Asked Sparky to plan/schedule study",
  "ai_tool:change_view": "Used AI: Navigated the app",
  "ai_tool:go_to_week": "Used AI: Navigated the app",
  "ai_tool:show_mascot_tour": "Used AI: Navigated the app",
  "ai_tool:add_exam": "Used AI: Managed tests/exams",
  "ai_tool:update_exam": "Used AI: Managed tests/exams",
  "ai_tool:delete_exam": "Used AI: Managed tests/exams",
  "ai_tool:record_exam_result": "Used AI: Managed tests/exams",
  "ai_tool:find_replacement_options": "Used AI: Asked for a schedule swap",
  "ai_tool:log_study_topic": "Used AI: Logged study via chat",
  "ai_tool:apply_state_patch": "Used AI: Made a custom data change",

  // Settings / account
  "save-settings": "Used: Settings", "open-settings": "Used: Settings",
  "save-study-preferences": "Used: Settings", "open-study-preferences": "Used: Settings",
  "set-sidebar-mode": "Used: Settings", "set-study-kind": "Used: Settings",
  "settings-pick-year": "Used: Settings", "studyprefs-pick": "Used: Settings",
  "dismiss-sync-banner": "Used: Settings", "reset-data": "Used: Settings", "sample-data": "Used: Settings",
  "perform-undo": "Used: Settings",
  "sign-in-google": "Signed in / account", "sign-out-google": "Signed in / account",
  "auth-submit": "Signed in / account", "auth-toggle-mode": "Signed in / account",
  "auth-forgot-password": "Signed in / account", "auth-request-reset": "Signed in / account",
  "auth-resend-confirmation": "Signed in / account", "auth-submit-new-password": "Signed in / account",
  "landing-go-auth": "Signed in / account", "landing-go-marketing": "Signed in / account",
  "landing-go-privacy": "Signed in / account", "open-privacy": "Signed in / account",
  "close-privacy-from-app": "Signed in / account",

  // Spotify
  "spotify-connect": "Used: Spotify integration", "spotify-disconnect": "Used: Spotify integration",
  "spotify-next": "Used: Spotify integration", "spotify-play-selected": "Used: Spotify integration",
  "spotify-play-track": "Used: Spotify integration", "spotify-prev": "Used: Spotify integration",
  "spotify-set-volume-bar": "Used: Spotify integration", "spotify-toggle": "Used: Spotify integration",
  "spotify-toggle-picker": "Used: Spotify integration", "spotify-toggle-queue": "Used: Spotify integration",
  "spotify-toggle-skip": "Used: Spotify integration",

  // Garmin watch
  "garmin-disconnect": "Used: Garmin Watch integration", "garmin-generate-code": "Used: Garmin Watch integration",

  // Search
  "open-search": "Used: Search",

  // Onboarding / guided tour
  "onboarding-finish": "Completed: Onboarding / setup tour", "onboarding-next-2": "Completed: Onboarding / setup tour",
  "onboarding-next-3": "Completed: Onboarding / setup tour", "onboarding-next-4": "Completed: Onboarding / setup tour",
  "onboarding-pick-year": "Completed: Onboarding / setup tour", "onboarding-skip-2": "Completed: Onboarding / setup tour",
  "rollover-pick-year": "Completed: Onboarding / setup tour", "start-guided-tour": "Completed: Onboarding / setup tour",

  // General app chrome -- low signal on its own, kept as one bucket rather
  // than dropped so the total event count still reconciles.
  "close-modal": "General app navigation", "show-info": "General app navigation",
  "dismiss-reminder": "General app navigation", "open-print-choice": "General app navigation",
};

// Fallback for any action not in FEATURE_LABELS above (a newly added feature,
// or a composite "prefix:id" this map doesn't have an entry for) -- turns
// "some-raw-action" into "Some raw action" rather than showing raw code or
// silently dropping it.
function humanizeEvent(event: string): string {
  const base = event.includes(":") ? event.split(":")[0] : event;
  const words = base.replace(/[-_]+/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function friendlyFeatureName(event: string): string {
  return FEATURE_LABELS[event] || humanizeEvent(event);
}

async function analyticsOverview(db: ReturnType<typeof createClient>) {
  const { data: metricsRows, error } = await db.rpc("admin_user_metrics");
  if (error) throw new Error(error.message);
  const rows = (metricsRows || []) as { user_id: string; metrics: any }[];

  const now = Date.now();
  const DAY = 86400000;
  let activeLast7 = 0, activeLast30 = 0, totalSessions = 0, totalMinutes = 0, totalEvents = 0;
  const eventTotals: Record<string, number> = {};
  // Sparky's ai_tool:* events get their own breakdown (see aiUsageBreakdown
  // below) rather than being mixed into the general feature list -- they
  // measure the PURPOSE of a chat message, a different granularity than
  // ai_study_assistant_chat (total chat volume), which stays in eventTotals.
  const aiToolTotals: Record<string, number> = {};
  const sessionVsResult: { x: number; y: number }[] = [];
  const minutesVsResult: { x: number; y: number }[] = [];

  for (const row of rows) {
    const m = row.metrics || {};
    totalSessions += m.sessionCount || 0;
    totalMinutes += m.totalMinutes || 0;
    totalEvents += m.eventTotal || 0;
    for (const [ev, cnt] of Object.entries(m.eventCounts || {})) {
      if (ev.startsWith("admin-")) continue; // this account's own admin-mode use, not a feature
      if (ev.startsWith("ai_tool:")) {
        const label = friendlyFeatureName(ev).replace(/^Used AI: /, "");
        aiToolTotals[label] = (aiToolTotals[label] || 0) + Number(cnt);
        continue;
      }
      const label = friendlyFeatureName(ev);
      eventTotals[label] = (eventTotals[label] || 0) + Number(cnt);
    }
    const lastActive = [m.lastEventAt, m.lastSessionDate, m.stateUpdatedAt]
      .filter(Boolean)
      .map((d: string) => new Date(d).getTime())
      .reduce((a, b) => Math.max(a, b), 0);
    if (lastActive) {
      if (now - lastActive <= 7 * DAY) activeLast7++;
      if (now - lastActive <= 30 * DAY) activeLast30++;
    }
    if (m.resultCount > 0 && typeof m.avgResultPct === "number") {
      if (m.sessionCount > 0) sessionVsResult.push({ x: m.sessionCount, y: m.avgResultPct });
      if (m.totalMinutes > 0) minutesVsResult.push({ x: m.totalMinutes, y: m.avgResultPct });
    }
  }

  // Grouped down to ~30 plain-English buckets by friendlyFeatureName() above,
  // so unlike the old raw-action version there's no need to truncate hard --
  // this cap is just a safety net against a runaway number of distinct labels.
  const topFeatures = Object.entries(eventTotals).sort((a, b) => b[1] - a[1]).slice(0, 60)
    .map(([event, count]) => ({ event, count }));
  const aiUsageBreakdown = Object.entries(aiToolTotals).sort((a, b) => b[1] - a[1])
    .map(([event, count]) => ({ event, count }));

  return {
    userCount: rows.length,
    activeLast7,
    activeLast30,
    totalSessions,
    totalMinutes,
    totalEvents,
    topFeatures,
    aiUsageBreakdown,
    correlations: {
      sessionsVsResult: { points: sessionVsResult, r: pearson(sessionVsResult) },
      minutesVsResult: { points: minutesVsResult, r: pearson(minutesVsResult) },
    },
  };
}

async function exportCsv(db: ReturnType<typeof createClient>): Promise<string> {
  const { users } = await listUsers(db);
  const cols = [
    "id", "email", "createdAt", "lastSignInAt", "sessionCount", "sessionCountLast30",
    "totalMinutes", "minutesLast30", "resultCount", "avgResultPct", "subjectCount",
    "taskCount", "examCount", "eventTotal",
  ];
  const csvEscape = (v: unknown) => {
    const s = v === null || v === undefined ? "" : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [cols.join(",")];
  for (const u of users) {
    const m = u.metrics || {};
    lines.push(cols.map((c) => csvEscape((u as any)[c] ?? m[c])).join(","));
  }
  return lines.join("\n");
}

// ---- admin session tokens --------------------------------------------------
// `${userId}.${expiresAtMs}` + a base64url HMAC-SHA256 signature over that
// exact string, keyed by ADMIN_SESSION_SECRET. Anyone can read the payload
// (it's not a secret, just a user id and a timestamp) but can't produce a
// valid signature for a different user id or a pushed-out expiry without the
// key, which only exists as a function secret on the server.

async function hmacSign(message: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return base64UrlEncode(new Uint8Array(sig));
}

async function signAdminToken(userId: string, secret: string) {
  const expiresAt = Date.now() + ADMIN_TOKEN_TTL_MS;
  const payload = `${userId}.${expiresAt}`;
  const sig = await hmacSign(payload, secret);
  return { token: `${payload}.${sig}`, expiresAt };
}

async function verifyAdminToken(token: string, expectedUserId: string, secret: string): Promise<boolean> {
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const [userId, expiresAtStr, sig] = parts;
  if (userId !== expectedUserId) return false;
  const expiresAt = Number(expiresAtStr);
  if (!Number.isFinite(expiresAt) || Date.now() > expiresAt) return false;
  const expectedSig = await hmacSign(`${userId}.${expiresAtStr}`, secret);
  return timingSafeEqual(sig, expectedSig);
}

function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a), bb = enc.encode(b);
  const len = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) diff |= (ab[i] || 0) ^ (bb[i] || 0);
  return diff === 0;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
