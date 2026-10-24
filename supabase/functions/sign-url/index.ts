// Returns short-lived download links for songs and covers stored in Cloudflare R2.
// The bucket stays private: only signed-in app users can get a link.
//
// Secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { AwsClient } from "npm:aws4fetch@1.0.20";

const LINK_LIFETIME_SECONDS = 6 * 60 * 60;
const MAX_KEYS = 200;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const r2 = new AwsClient({
  accessKeyId: Deno.env.get("R2_ACCESS_KEY_ID")!,
  secretAccessKey: Deno.env.get("R2_SECRET_ACCESS_KEY")!,
  service: "s3",
  region: "auto",
});
const endpoint = `https://${Deno.env.get("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com/${Deno.env.get("R2_BUCKET")}`;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Only real signed-in users, not just anyone holding the public app key.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ error: "sign in required" }, 401);

  let keys: unknown;
  try {
    ({ keys } = await req.json());
  } catch {
    return json({ error: "body must be JSON: {\"keys\": [...]}" }, 400);
  }
  if (!Array.isArray(keys) || keys.length === 0 || keys.length > MAX_KEYS) {
    return json({ error: `keys must be a list of 1-${MAX_KEYS} object keys` }, 400);
  }

  const urls: Record<string, string> = {};
  for (const key of keys) {
    if (typeof key !== "string" || !/^(audio|covers)\/[A-Za-z0-9._-]+$/.test(key)) continue;
    const url = new URL(`${endpoint}/${key}`);
    url.searchParams.set("X-Amz-Expires", String(LINK_LIFETIME_SECONDS));
    const signed = await r2.sign(new Request(url, { method: "GET" }), { aws: { signQuery: true } });
    urls[key] = signed.url;
  }
  return json({ urls, expires_in: LINK_LIFETIME_SECONDS });
});
