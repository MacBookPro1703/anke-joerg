// Supabase Edge Function "send-push" – Anke & Jörg
// Erzeugt die Push-Schlüssel (VAPID) beim ersten Aufruf selbst und speichert sie in app_keys.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    let { data: k } = await admin.from("app_keys").select("*").eq("id", "vapid").maybeSingle();
    if (!k) {
      const v = webpush.generateVAPIDKeys();
      await admin.from("app_keys").upsert({ id: "vapid", public_key: v.publicKey, private_key: v.privateKey });
      ({ data: k } = await admin.from("app_keys").select("*").eq("id", "vapid").single());
    }

    const body = await req.json().catch(() => ({}));
    if (body.action === "key") return json({ publicKey: k.public_key });

    const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: u } = await admin.auth.getUser(jwt);
    if (!u?.user) return json({ error: "auth" }, 401);

    const { data: m } = await admin.from("members").select("role")
      .eq("space_id", body.space_id).eq("user_id", u.user.id).maybeSingle();
    if (!m) return json({ error: "forbidden" }, 403);

    const target = body.self ? m.role : (m.role === "je" ? "anke" : "je");
    const { data: subs } = await admin.from("push_subs").select("*")
      .eq("space_id", body.space_id).eq("role", target);

    webpush.setVapidDetails("mailto:je@ebbing-project.de", k.public_key, k.private_key);
    const payload = JSON.stringify({
      title: String(body.title || "Anke & Jörg").slice(0, 120),
      body: String(body.body || "").slice(0, 240),
      kind: body.kind || "info", tag: body.tag || body.kind || "aj",
    });
    let sent = 0;
    for (const s of subs ?? []) {
      try {
        await webpush.sendNotification(s.sub, payload, { TTL: 3600, urgency: body.urgent ? "high" : "normal" });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await admin.from("push_subs").delete().eq("endpoint", s.endpoint);
      }
    }
    return json({ sent });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
