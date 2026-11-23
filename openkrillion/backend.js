// In-browser replacement for the original Cloudflare Worker + D1 backend (github.com/VulcanEon/openkrillion.com-service, MIT).
// Same request/response contract the game client already speaks, but everything lives in localStorage:
// puzzles come from bank.js, the round clock + scoring run here, and there are no shared leaderboards.
import { TIERS, matchAnswer, etDate, resetAt, ROUND_MS, PREVIEW_MS } from './rules.js';
import { BANK } from './bank.js';

const STORE = 'ok:local-runs', FEEDBACK = 'ok:local-feedback', MAX_RUNS = 60;
const memory = {};
const load = key => { try { return JSON.parse(localStorage.getItem(key)) ?? null; } catch { return memory[key] ?? null; } };
const save = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { memory[key] = value; } };
const runs = () => load(STORE) || {};
const putRun = run => { const all = runs(); all[run.id] = run; const ids = Object.keys(all); if (ids.length > MAX_RUNS) ids.sort((a, b) => all[a].created - all[b].created).slice(0, ids.length - MAX_RUNS).forEach(id => delete all[id]); save(STORE, all); return run; };
const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'r' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10));

function hash(str) { let h = 2166136261; for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
function rng(seed) { let s = seed >>> 0; return () => { s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
function pick(rand) { const idx = BANK.map((_, i) => i); for (let i = idx.length - 1; i > 0; i--) { const j = Math.floor(rand() * (i + 1)); [idx[i], idx[j]] = [idx[j], idx[i]]; } return idx.slice(0, 7); }
const dayNumber = date => Math.floor((Date.parse(date) - Date.parse('2026-07-16')) / 86400000) + 1;
const fail = (message, status = 400) => { const e = new Error(message); e.status = status; return e; };
const promptsOf = run => run.prompts.map(i => BANK[i]);

function dto(run) {
  return { date: run.date, dayNumber: dayNumber(run.date), sample: false, source: 'Built-in question bank', resetsAt: resetAt(run.date), prompts: promptsOf(run).map(({ id, text }) => ({ id, text })) };
}
function state(run) {
  const results = run.answers.map(a => ({ round: a.round, rawAnswer: a.rawAnswer, answer: a.answer, tier: a.tier, score: a.score, quip: a.quip || null }));
  return { ...dto(run), runId: run.id, mode: run.mode, round: run.next_round, roundStart: run.round_start, pausedAt: run.paused_at || null, serverNow: Date.now(), completed: !!run.completed, results, score: results.reduce((s, r) => s + r.score, 0) };
}
const own = id => { const r = runs()[id]; if (!r) throw fail('Dive not found on this browser.', 404); return r; };
const dailyRun = date => Object.values(runs()).find(r => r.mode === 'daily' && r.date === date);
function newRun(mode, date) {
  const prompts = pick(mode === 'daily' ? rng(hash('openkrillion:' + date)) : Math.random);
  return putRun({ id: uuid(), date, mode, prompts, round_start: Date.now() + PREVIEW_MS, next_round: 0, completed: false, paused_at: null, answers: [], created: Date.now() });
}

export async function api(path, data) {
  const [name, query = ''] = path.split('?'), params = new URLSearchParams(query), date = etDate();
  if (data === undefined) {
    if (name === 'today') return dto({ date, prompts: pick(rng(hash('openkrillion:' + date))) });
    if (name === 'state') return state(own(params.get('run')));
    if (name === 'review') {
      const run = own(params.get('run'));
      if (!run.completed) throw fail('Finish your dive before opening the answer sheet.', 403);
      return { prompts: promptsOf(run).map(p => ({ ...p, answers: p.answers.map(a => ({ ...a, score: TIERS[a.tier].score })).sort((a, b) => b.score - a.score || a.answer.localeCompare(b.answer)) })), population: 0, betterThan: null, dist: Array.from({ length: 71 }, () => 0) };
    }
    throw fail('Unknown endpoint.', 404);
  }
  if (name === 'start') {
    const practice = data.practice === true;
    const run = (!practice && dailyRun(date)) || newRun(practice ? 'practice' : 'daily', date);
    return state(run);
  }
  if (name === 'pause') {
    const run = own(data.runId);
    if (data.paused === true && !run.completed && run.round_start !== null && !run.paused_at && Date.now() <= run.round_start + ROUND_MS) run.paused_at = Date.now();
    else if (data.paused === false && run.paused_at) { run.round_start += Date.now() - run.paused_at; run.paused_at = null; }
    return state(putRun(run));
  }
  if (name === 'next') {
    const run = own(data.runId);
    if (run.paused_at) throw fail('Close the menu to resume your dive.', 409);
    if (!run.completed && run.round_start === null) run.round_start = Date.now() + PREVIEW_MS;
    return state(putRun(run));
  }
  if (name === 'answer') {
    const run = own(data.runId);
    if (run.paused_at) throw fail('Close the menu to resume your dive.', 409);
    if (run.completed || run.round_start === null || data.round !== run.next_round) return { state: state(run), alreadyScored: true };
    if (Date.now() < run.round_start) throw fail('The answer window has not opened yet.', 409);
    const prompt = promptsOf(run)[run.next_round];
    const raw = typeof data.answer === 'string' ? data.answer.trim().slice(0, 256) : '';
    const late = Date.now() > run.round_start + ROUND_MS;
    const timely = !late || (data.timeout === true && Date.now() <= run.round_start + ROUND_MS + 1500);
    const match = raw && timely ? matchAnswer(raw, prompt.answers) : null;
    if (!match && raw && !late && !data.timeout) return { rejected: true, message: `“${raw}”: no echo. try again` };
    if (match?.correction && data.confirm !== true && !late && !data.timeout && data.previewCorrection !== false) return { correction: match.answer, original: raw };
    const result = { round: run.next_round, rawAnswer: raw || null, answer: match?.answer || null, tier: match?.tier || null, score: match ? TIERS[match.tier].score : 0, quip: match?.quip || null, promptText: prompt.text };
    run.answers.push({ round: result.round, rawAnswer: result.rawAnswer, answer: result.answer, tier: result.tier, score: result.score, quip: result.quip });
    run.next_round = result.round + 1; run.round_start = null; run.completed = result.round === 6;
    putRun(run);
    return { result: { ...result }, state: state(run) };
  }
  if (name === 'feedback') {
    const text = String(data.text || '').trim().slice(0, 1000);
    if (!text) throw fail('Please enter a message.');
    const list = load(FEEDBACK) || []; list.push({ date, kind: data.kind, text }); save(FEEDBACK, list.slice(-50));
    return { ok: true };
  }
  throw fail('Unknown endpoint.', 404);
}
