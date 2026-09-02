# Simple Study — Garmin watch app

A Connect IQ Widget (with a Glance view) for the Garmin Venu 3S showing
today's schedule: current event highlighted, everything else still to come
below it, scrollable. Pulls live from the same `study_state` your account
already syncs on the website.

**Status: written but not yet compiled or run.** This environment has no
Connect IQ SDK installed, so none of the Monkey C in `source/` has been
built or tested in the simulator — treat it as a solid first draft, not a
working binary. Expect to fix a handful of compiler errors (wrong enum
name, a missing import, an annotation Monkey C wants on a symbol used from
`(:background)` code) the first time you open this in VS Code. The logic
and architecture are sound; syntax polish is the remaining work.

## How it fits together

- **Website** (`index.html`, Settings → "Garmin Watch"): generates a
  6-digit pairing code, shown for 10 minutes.
- **Watch app**: has no browser, so instead of the usual OAuth redirect,
  you type that code into the app's own Settings screen in Garmin Connect
  Mobile. The watch trades it for a long-lived token and stores that —
  from then on it's paired for good, no repeat login.
- **3 new Supabase Edge Functions** (`supabase/functions/watch-*`) do the
  work: `watch-pair` mints the code (called by the website while you're
  signed in normally), `watch-exchange` trades a code for a token (called
  by the watch), `watch-schedule` returns a compact JSON list of the day's
  events for a given date (called by the watch, repeatedly).
- `watch-schedule` re-implements `segmentsForDate()` and its helpers from
  `index.html` in Deno/TypeScript, against the exact same `study_state`
  blob — it's not a separate data model, just the same timetable logic
  ported server-side. If you ever change how events/exams resolve to a
  day's timetable on the website, mirror the change in
  `supabase/functions/watch-schedule/index.ts` (its file header names the
  exact functions to keep in sync).

**Networking reality on this device:** the Venu 3S has no independent
internet connection. Every request from the watch goes over Bluetooth
through the Garmin Connect Mobile app on your phone. That means the watch
needs your phone nearby with Connect Mobile running to fetch anything —
normal for Connect IQ apps, not a bug.

**Reminders:** Monkey C has no OS-level notification API for third-party
apps. "Reminders" here means the widget vibrates when a background refresh
notices something starting soon — accurate to within the refresh interval
(15 min, floored at 5 min by Garmin regardless of what's requested), not to
the minute. If you want tighter timing, that only happens while the widget
is open on screen (it polls every 45s there).

## What you need to do

### 1. Ship the backend

This environment can't push git or touch your Supabase project directly —
you'll need to:

- `git push` this branch (`worktree-garmin-watch-app`) and merge it, same
  as any other change here.
- Paste `supabase/migrations/0005_watch_tokens.sql` into the Supabase SQL
  editor for project `rlwfxvnwekkyfslxltus` and run it.
- Deploy the three new functions (from a machine with the Supabase CLI
  logged in): `supabase functions deploy watch-pair watch-exchange
  watch-schedule`. No new secrets are needed — they only use
  `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY`, which
  Supabase already injects into every Edge Function automatically.

### 2. Set up Garmin's tooling (all free)

1. Create a Garmin Connect IQ developer account:
   `garmin.com/en-US/forms/ciq-registration/`.
2. Install VS Code's **Monkey C** extension
   (`marketplace.visualstudio.com/items?itemName=garmin.monkey-c`) — it
   bundles the SDK Manager.
3. In the SDK Manager, install the current Connect IQ SDK and the
   **venu3s** device profile.
4. Generate a developer signing key: in VS Code, Command Palette →
   "Monkey C: Generate Developer Key" (or `openssl genrsa -out
   developer_key.pem 4096` yourself). Keep this file safe — if you ever
   publish to the store and later lose it, you can never update that
   listing again.
5. Open the `garmin/` folder as the project root in VS Code (it should
   pick up `manifest.xml/monkey.jungle` automatically).

### 3. Build, fix, and test

1. Command Palette → "Monkey C: Build Current Project", targeting
   `venu3s`. Fix whatever the compiler flags — see the "Status" note
   above.
2. Run in the simulator first (Command Palette → "Monkey C: Run" ). You
   won't be able to test real pairing there (no real Garmin Connect Mobile
   app settings screen in the simulator) — for that you need step 4.
3. Once it builds clean, sideload to your actual Venu 3S: connect it over
   USB (it mounts as a drive), and either use VS Code's device-push
   command or copy the built `.prg` into `GARMIN/APPS/` on the watch
   directly.
4. On your phone, open Garmin Connect Mobile → your watch → "Simple
   Study" in the installed Connect IQ apps → App Settings → paste in a
   pairing code generated from the website's Settings page. Give it a
   minute to sync over Bluetooth, then open the widget on the watch.

### 4. Before any public Connect IQ Store submission

The app is written with store review in mind (see the privacy policy
section already added to the website, and the "under 13" note below), but
don't submit until:

- You've filled in the real contact email — the privacy page still has a
  `[contact email]` placeholder (pre-existing, not new to this feature —
  see other pending items).
- You've tested pairing + a full day's schedule end-to-end on the real
  device, not just the simulator.
- You've reread Garmin's current review guidelines yourself at submission
  time (`developer.garmin.com/connect-iq/app-review-guidelines/`) — this
  was researched in 2026 and Garmin does update these.
- Given your users are Irish secondary students (some under 13), keep the
  app's own description and behavior general-audience — no
  child-specific targeting, marketing, or data collection beyond the
  schedule itself.

## Known limitations worth knowing about upfront

- Exam sittings without a recorded time show as "Time TBC" rather than
  being placed on the timeline (the data model doesn't guarantee every
  sitting has a time).
- Exam tile duration is a hardcoded 2-hour placeholder for
  display/ordering only — actual sitting length isn't tracked anywhere in
  `study_state`.
- Swipe-to-scroll moves in fixed steps rather than tracking a real drag —
  simpler and more reliable to get right without a working simulator to
  tune against, but less smooth than a native drag gesture. Worth
  revisiting once you can actually test on-device.
