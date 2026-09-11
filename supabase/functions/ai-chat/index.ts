// Single entry point for the app's AI study assistant.
//
// The client sends the same Gemini-shaped request body it always built
// (contents / systemInstruction / tools). This function tries Gemini, then
// Groq, then OpenRouter, and always replies in Gemini's response shape
// (candidates[0].content.parts), so the client's existing tool-calling loop
// needs no changes beyond calling this function instead of Gemini directly.
//
// An optional `preferProvider: "groq"` field lets a caller ask for Groq
// first instead of Gemini, for text-only tasks where Gemini's specific
// quality isn't needed — this exists so features that call this function a
// lot (the language word-bank/essay-marking tools) can spend Groq's
// separate, larger free quota instead of Gemini's shared and much scarcer
// one. It's ignored (Gemini always goes first) whenever the request
// includes an image, since Groq/OpenRouter can't do vision at all — see
// hasImage() below. If Groq fails or isn't configured, Gemini/OpenRouter
// are still tried as fallback, same as ever.
//
// This is also the only place the AI provider keys exist — they're read
// from env (`supabase secrets set ...`), never shipped to the browser.
//
// Signing in is required: config.toml's verify_jwt rejects requests with no
// valid Supabase-signed JWT at all, but the publishable/anon key is itself a
// valid JWT (role "anon"), so we additionally call auth.getUser() below to
// make sure the caller is an actually signed-in user, not just holding the
// public anon key.
//
// A per-user daily request cap (DAILY_REQUEST_LIMIT below) backstops the size cap further down:
// the size cap alone doesn't stop a script from firing many small requests to burn through the
// shared Gemini/Groq/OpenRouter quota. The counter lives in ai_usage_daily (see migration 0018),
// touched only through the service-role client below, so a caller can't reset or inflate its own
// count -- it can only ever go up, once per request, from the server side.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Generous on purpose -- a normal study session, even a heavy one with lots of multi-step tool
// calls, comes nowhere near this. It exists to stop sustained scripted abuse, not to meter real use.
const DAILY_REQUEST_LIMIT = 500;

const GEMINI_MODEL_TEXT = "gemini-3.5-flash-lite";
const GEMINI_MODEL_TEXT_FALLBACK = "gemini-3.1-flash-lite";
const GEMINI_MODEL_VISION = "gemini-3.5-flash";
const GROQ_MODEL = "llama-3.3-70b-versatile";
// Free-model availability on OpenRouter shifts over time — this is the one
// line to edit if this model stops being free or gets deprecated.
const OPENROUTER_MODEL = "meta-llama/llama-3.3-70b-instruct:free";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const authClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await authClient.auth.getUser();
    if (!user) return jsonResponse({ error: "Sign in with Google to use the AI Study Assistant." }, 401);

    // Atomic per-user daily counter -- see DAILY_REQUEST_LIMIT above. Uses the service-role client
    // (bypasses RLS; ai_usage_daily grants no access to `authenticated`/`anon` at all, see 0018) so
    // this can never be reset or read by the caller themselves.
    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: usageCount, error: usageError } = await db.rpc("increment_ai_usage", { p_user_id: user.id });
    if (!usageError && typeof usageCount === "number" && usageCount > DAILY_REQUEST_LIMIT) {
      return jsonResponse({ error: "Daily AI usage limit reached. Try again tomorrow." }, 429);
    }

    // Cheap guard against using this signed-in-only endpoint as a free, unmetered
    // relay to burn through the shared Gemini/Groq/OpenRouter quota (or run up
    // API cost) -- any signed-in account can otherwise send an arbitrarily large
    // payload with no per-request limit. This is a size cap, not a rate limit.
    const rawBody = await req.text();
    if (rawBody.length > 200_000) return jsonResponse({ error: "Request too large." }, 413);
    const { contents, systemInstruction, tools, preferProvider } = JSON.parse(rawBody || "{}");
    if (!Array.isArray(contents) || !contents.length) {
      return jsonResponse({ error: "Missing 'contents'." }, 400);
    }

    const usesVision = hasImage(contents);
    const geminiKey = Deno.env.get("GEMINI_API_KEY");
    const groqKey = Deno.env.get("GROQ_API_KEY");
    const openrouterKey = Deno.env.get("OPENROUTER_API_KEY");

    const geminiAttempts: Array<() => Promise<unknown>> = [];
    if (geminiKey) {
      geminiAttempts.push(() =>
        callGemini(usesVision ? GEMINI_MODEL_VISION : GEMINI_MODEL_TEXT, contents, systemInstruction, tools, geminiKey));
      if (!usesVision) {
        geminiAttempts.push(() => callGemini(GEMINI_MODEL_TEXT_FALLBACK, contents, systemInstruction, tools, geminiKey));
      }
    }
    // Vision (photo) messages only go through Gemini — Groq/OpenRouter image-input translation is
    // deliberately out of scope here, so preferProvider is meaningless (and ignored) once an image is present.
    const groqAttempts: Array<() => Promise<unknown>> = [];
    if (!usesVision && groqKey) {
      groqAttempts.push(() =>
        callOpenAiCompatible("https://api.groq.com/openai/v1/chat/completions", GROQ_MODEL, contents, systemInstruction, tools, groqKey));
    }
    const openrouterAttempts: Array<() => Promise<unknown>> = [];
    if (!usesVision && openrouterKey) {
      openrouterAttempts.push(() =>
        callOpenAiCompatible("https://openrouter.ai/api/v1/chat/completions", OPENROUTER_MODEL, contents, systemInstruction, tools, openrouterKey));
    }
    const attempts = !usesVision && preferProvider === "groq"
      ? [...groqAttempts, ...geminiAttempts, ...openrouterAttempts]
      : [...geminiAttempts, ...groqAttempts, ...openrouterAttempts];

    if (!attempts.length) {
      return jsonResponse({ error: usesVision ? "No vision-capable provider configured." : "No AI provider configured." }, 500);
    }

    let lastError = "All providers failed.";
    for (const attempt of attempts) {
      try {
        const result = await attempt();
        if (result) return jsonResponse(result, 200);
      } catch (err) {
        lastError = err instanceof Error ? err.message : String(err);
      }
    }
    return jsonResponse({ error: lastError }, 502);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function hasImage(contents: any[]): boolean {
  const last = contents[contents.length - 1];
  return !!last?.parts?.some((p: any) => p.inlineData);
}

// ---- Gemini ----
async function callGemini(model: string, contents: any[], systemInstruction: any, tools: any, apiKey: string) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ contents, systemInstruction, tools }),
    },
  );
  if (res.status === 429) throw new Error("Gemini rate-limited");
  if (!res.ok) throw new Error(`Gemini request failed (${res.status}). ${await safeErrorDetail(res)}`);
  return res.json();
}

// ---- Groq / OpenRouter (OpenAI-compatible chat completions) ----
async function callOpenAiCompatible(
  url: string, model: string, contents: any[], systemInstruction: any, tools: any, apiKey: string,
) {
  const messages = toOpenAiMessages(contents, systemInstruction);
  const openAiTools = toOpenAiTools(tools);
  const body: Record<string, unknown> = { model, messages };
  if (openAiTools.length) { body.tools = openAiTools; body.tool_choice = "auto"; }

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify(body),
  });
  if (res.status === 429) throw new Error(`${url} rate-limited`);
  if (!res.ok) throw new Error(`Request to ${url} failed (${res.status}). ${await safeErrorDetail(res)}`);
  return toGeminiResponse(await res.json());
}

async function safeErrorDetail(res: Response) {
  try {
    const data = await res.json();
    return data?.error?.message || JSON.stringify(data);
  } catch {
    return "";
  }
}

// Gemini `contents` (role user/model, parts[].text | functionCall | functionResponse)
// -> OpenAI `messages` (role system/user/assistant/tool). Tool calls/responses
// are correlated by function name (Gemini has no call-id concept either), so
// this assumes at most one call per function name per turn — fine for this
// app's tool registry, which the client calls one at a time.
function toOpenAiMessages(contents: any[], systemInstruction: any): any[] {
  const messages: any[] = [];
  const sysText = systemInstruction?.parts?.map((p: any) => p.text).filter(Boolean).join("\n");
  if (sysText) messages.push({ role: "system", content: sysText });

  for (const turn of contents) {
    const parts = turn.parts || [];
    const functionCalls = parts.filter((p: any) => p.functionCall);
    const functionResponses = parts.filter((p: any) => p.functionResponse);
    const text = parts.filter((p: any) => p.text).map((p: any) => p.text).join("\n");

    if (functionResponses.length) {
      for (const fr of functionResponses) {
        messages.push({
          role: "tool",
          tool_call_id: fr.functionResponse.name,
          content: JSON.stringify(fr.functionResponse.response ?? {}),
        });
      }
      continue;
    }

    if (turn.role === "model") {
      const msg: any = { role: "assistant", content: text || null };
      if (functionCalls.length) {
        msg.tool_calls = functionCalls.map((fc: any) => ({
          id: fc.functionCall.name,
          type: "function",
          function: { name: fc.functionCall.name, arguments: JSON.stringify(fc.functionCall.args ?? {}) },
        }));
      }
      messages.push(msg);
    } else {
      messages.push({ role: "user", content: text || "(no text)" });
    }
  }
  return messages;
}

// Gemini `tools[0].functionDeclarations` -> OpenAI `tools`.
function toOpenAiTools(tools: any): any[] {
  const decls = tools?.[0]?.functionDeclarations;
  if (!Array.isArray(decls)) return [];
  return decls.map((d: any) => ({
    type: "function",
    function: { name: d.name, description: d.description, parameters: geminiSchemaToJsonSchema(d.parameters) },
  }));
}

function geminiSchemaToJsonSchema(schema: any): any {
  if (!schema || typeof schema !== "object") return schema;
  const out: any = {};
  for (const [key, value] of Object.entries(schema)) {
    if (key === "type" && typeof value === "string") out.type = value.toLowerCase();
    else if (key === "properties" && value && typeof value === "object") {
      out.properties = Object.fromEntries(
        Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, geminiSchemaToJsonSchema(v)]),
      );
    } else if (key === "items") out.items = geminiSchemaToJsonSchema(value);
    else out[key] = value;
  }
  return out;
}

// OpenAI `choices[0].message` -> Gemini `candidates[0].content.parts`.
function toGeminiResponse(data: any) {
  const message = data?.choices?.[0]?.message;
  const parts: any[] = [];
  if (message?.content) parts.push({ text: message.content });
  for (const call of message?.tool_calls || []) {
    let args = {};
    try { args = JSON.parse(call.function.arguments || "{}"); } catch { /* leave empty */ }
    parts.push({ functionCall: { name: call.function.name, args } });
  }
  return { candidates: [{ content: { role: "model", parts } }] };
}
