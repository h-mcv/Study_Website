// Called by the website (while the student is already signed in normally,
// in a browser) to mint a short-lived pairing code. The student then types
// that code into the Garmin watch app's settings in Garmin Connect Mobile;
// see watch-exchange, which trades the code for a durable watch token.
//
// This exists because Connect IQ apps have no browser/webview, so a normal
// OAuth redirect flow isn't available on-device -- the code is the entire
// login step, and it only has to be typed once per watch.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const CODE_TTL_MS = 10 * 60 * 1000; // 10 minutes -- long enough to switch apps on the phone, short enough to keep guessing infeasible (see rate limiting note in watch-exchange)
const CODE_LENGTH = 6;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const authClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await authClient.auth.getUser();
    if (!user) return jsonResponse({ error: "Sign in to pair a watch." }, 401);

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Clear out this user's old codes first -- only one live code per user
    // at a time, so an old, possibly-shared code can't linger as valid.
    await db.from("watch_pairing_codes").delete().eq("user_id", user.id);

    const expiresAt = new Date(Date.now() + CODE_TTL_MS).toISOString();
    let code = "";
    for (let attempt = 0; attempt < 5; attempt++) {
      code = generateCode();
      const { error } = await db.from("watch_pairing_codes").insert({ code, user_id: user.id, expires_at: expiresAt });
      if (!error) return jsonResponse({ code, expiresAt }, 200);
      // A unique-constraint collision on `code` (astronomically rare at 6
      // digits, but cheap to guard) just tries again with a fresh code.
      if (error.code !== "23505") return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Could not generate a pairing code, try again." }, 500);
  } catch (err) {
    return jsonResponse({ error: err instanceof Error ? err.message : "Unknown error" }, 500);
  }
});

function generateCode(): string {
  const digits = new Uint32Array(CODE_LENGTH);
  crypto.getRandomValues(digits);
  return Array.from(digits, (d) => d % 10).join("");
}

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
