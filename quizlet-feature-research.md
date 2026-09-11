# Quizlet Feature Research — for Simple Study

Research done 2026-09-10, comparing Quizlet's full feature set (free + Plus) against
what Simple Study already has, to figure out what's realistic to add.

## 1. Quizlet's full feature set (2026)

**Free tier:** flashcard creation (text + limited images), flip-through study mode,
capped Learn mode, capped Test mode (MC/T-F/matching/written), Match game,
Gravity/Blast typing game, Quizlet Live (teacher-hosted team game), search/browse
millions of public sets, import from Word/Excel/Docs/CSV, Folders & Classes,
audio/TTS pronunciation, Diagrams (image-labeling cards), star "know/still learning",
per-set progress stats, Long-Term Learning (spaced-repetition reminders), mobile apps,
browser extension, dark mode, ads, collaborative set editing, bidirectional language
cards.

**Plus (paid):** ad-free, uncapped Learn/Test, offline mode, unlimited image uploads,
Q-Chat (AI tutor: Teach Me / Quiz Me / Apply Knowledge), Magic Notes (notes/PDF →
flashcards + test + outline), Quick Summary, Brain Beats (flashcards → song), Memory
Score, Expert/Textbook Solutions, Focus mode, advanced dashboards, priority support.

## 2. Current Simple Study feature inventory (for reference)

- Flashcards with flip mode, "Smart Test" (AI-graded free-response recall), and
  AI-generated MCQ test.
- Topic-level spaced repetition (Anki-style date fuzzing, exam-proximity tightening,
  cross-subject interleaving) — schedules *when* to study a topic.
- Tests & Exams tracking + CAO points calculator + exam-day scheduling.
- AI photo-to-flashcard extraction; AI chat widget ("Sparky", photo-capable);
  multi-provider AI proxy (Gemini → Groq → OpenRouter fallback).
- Language tools: vocab word bank, verb/tense tracker, essay marking, translation
  (Irish-language focused).
- Static Formula Book (paged reference images + AI/local search).
- Group chat rooms, including auto-membership rooms by school + graduation year.
- Google sign-in, admin panel, no billing/paywall — free for all users.
- Supabase backend (Postgres + RLS + edge functions), PostHog analytics.
- Garmin Connect IQ watch app (schedule widget, glance view, background sync).
- No LaTeX, no audio/TTS, no matching/gravity games, no flashcard-set sharing or
  public search, no native mobile app (web app + Garmin widget only).

## 3. Removed as infeasible (or not worth doing)

- **Millions of public user-generated sets** — a 15-year content moat, can't be
  replicated. (A smaller version is kept in section 4.)
- **Expert/Textbook Solutions** — requires a licensed textbook-answer database;
  a content-licensing problem, not an engineering one.
- **Native iOS/Android apps with offline mode** — you have a web app + Garmin widget,
  not app-store infra. (PWA offline caching kept in section 4 as the realistic
  substitute.)
- **Ads on free tier** — this is Quizlet's monetization lever, not a study feature,
  and it fights the "free tool for your own school" positioning of this app.
- **Ad-free / priority support / unlimited-vs-capped tiers** — all moot; there's no
  billing system and no reason to artificially cap anything.
- **Brain Beats (song generator)** — needs a paid AI music-generation API for a
  gimmick; cost/complexity way out of proportion to value.
- **Browser extension** — doable, but a whole separate packaging/maintenance surface
  for low payoff versus building the feature directly into the site. Skip for now.

## 4. Feasible — could actually build these

Already have, fully or partially: flashcards, MCQ test, AI-graded free-response
("Smart Test"), topic-level spaced repetition, AI photo→flashcard generation, dark
mode.

Realistic additions, roughly in effort order:

- **Match game** and **Gravity/Blast-style typing game** — pure client-side, no
  backend needed, easy engagement win.
- **Import via pasted term/definition text or CSV** — classic Quizlet paste-import,
  small effort.
- **Star / "still learning" vs "know" marking** on cards — trivial, pairs with the
  existing SRS.
- **True/False and Matching question types** added to the existing test generator.
- **Audio pronunciation via the browser's built-in TTS** (Web Speech API — free, no
  backend) — strong fit given the Irish-language tools already in the app.
- **Diagram/image-labeling mode** — reuses the existing photo/Formula Book
  infrastructure.
- **Per-card spaced repetition** (not just per-topic) — extends what's already built.
- **Folders and shareable sets within your own userbase** — reuse the school/grad-year
  grouping instead of a public marketplace.
- **Collaborative set editing** — feasible via Supabase realtime, similar to the chat
  infra.
- **Q-Chat equivalent** — Sparky + the multi-provider AI proxy already exist; scoping
  it to "quiz/teach me on this specific set" is a natural extension, not a new system.
- **Magic Notes equivalent** — extend the existing photo-to-flashcard AI pipeline to
  accept pasted notes/PDF text and output flashcards + a practice test + an outline.
- **Quick Summary** — trivial reuse of the AI proxy already in place.
- **Memory Score** — review history for SRS is already stored; deriving a 0–100
  mastery score per card/set is just added analytics.
- **Focus mode** — small UI feature (hide chrome, add a timer).
- **PWA offline caching** — realistic substitute for "offline mode," using a service
  worker instead of a native app.
- **Quizlet Live equivalent** — feasible via Supabase Realtime, but the biggest lift
  on this list; worth doing later, and cheaper if built on top of the existing
  chat-room infra rather than from scratch.

## 5. Additions beyond Quizlet — improvements given what's already built

- **Cloze/fill-in-the-blank mode** auto-generated from a card's definition — another
  way to test from the same flashcards besides flip/MCQ/written.
- **Listening mode**: TTS reads the term, you type or speak the definition — leans on
  the audio feature above and the existing language tools.
- **Exam-simulation mode**: turn a deck into a timed mock exam (mixed question types,
  countdown matching real exam length), wired into the existing Tests & Exams /
  CAO-points tracking — Quizlet has nothing like this.
- **True per-card SM-2 spaced repetition** — a proper Anki-grade algorithm would beat
  Quizlet's own Long-Term Learning, and the scheduling groundwork already exists.
- **AI weak-topic detector**: since Smart Test already AI-grades free responses, have
  it flag consistently-missed cards/topics and auto-pull them forward in the review
  schedule — tighter integration than Quizlet has between grading and scheduling.
- **"Ask Sparky why" on wrong answers** — one tap after a missed MCQ/Smart Test
  question to get an explanation grounded in that flashcard, instead of a generic
  open-ended AI-tutor chat. Cheaper to build than a full Q-Chat and more useful.
- **Garmin watch micro-review**: push a "flashcard of the day" or 1-question quiz to
  the watch for glanceable review between classes — no competitor, including Quizlet,
  has this, and the watch-pairing infra already exists.
- **Study streaks/leaderboards inside the existing school/grad-year rooms** —
  gamifies review using social infrastructure already built, cheaper than a full
  Quizlet Live clone.
