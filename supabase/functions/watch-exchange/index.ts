// Called directly by the Garmin watch (no Supabase JWT available on-device,
// hence verify_jwt = false in config.toml -- this function does its own
// auth). Trades a short-lived pairing code, minted by watch-pair and typed
// in by the student via Garmin Connect Mobile's app settings, for a durable
// opaque token the watch stores and sends as a Bearer token on every
// watch-schedule request from then on.
//
// The code is deleted the moment it's looked up, valid or not, so it can
// never be reused even if this request fails after that point on the
// watch's side -- the student would just generate a fresh code.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const code = typeof body.code === "string" ? body.code.trim() : "";
    if (!/^\d{6}$/.test(code)) return jsonResponse({ error: "Invalid or expired code." }, 401);

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: row } = await db.from("watch_pairing_codes").select("user_id, expires_at").eq("code", code)
      .maybeSingle();
    // Consume it unconditionally (single-use), whether or not it turns out valid.
    await db.from("watch_pairing_codes").delete().eq("code", code);

    if (!row || new Date(row.expires_at).getTime() < Date.now()) {
      return jsonResponse({ error: "Invalid or expired code." }, 401);
    }

    const token = generateToken();
    const tokenHash = await sha256Hex(token);
    const { error } = await db.from("watch_tokens").insert({ token_hash: tokenHash, user_id: row.user_id });
    if (error) return jsonResponse({ error: error.message }, 500);

    return jsonResponse({ token }, 200);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "Unknown error" }, 500);
  }
});

function generateToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
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
