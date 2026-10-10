// Supabase Edge Function: "contact"
// Prima { text } iz aplikacije i prosljeđuje poruku na Telegram.
// Bot token je TAJNA (env var), NE ide u kod javne stranice.
//
// Postavi tajne (Supabase → Edge Functions → Secrets, ili CLI):
//   supabase secrets set TELEGRAM_TOKEN=123456:ABC...   TELEGRAM_CHAT_ID=987654321
// Deploy:
//   supabase functions deploy contact
//
// Napomena: funkcija po defaultu traži prijavljenog korisnika (verify_jwt),
// a stranica je ionako iza logina — pa poruke mogu slati samo prijavljeni.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  try {
    const { text } = await req.json().catch(() => ({}));
    const clean = (text ?? "").toString().trim();
    if (!clean) return json({ error: "empty" }, 400);

    const token = Deno.env.get("TELEGRAM_TOKEN");
    const chat = Deno.env.get("TELEGRAM_CHAT_ID");
    if (!token || !chat) return json({ error: "not_configured" }, 500);

    const message =
      "📩 Obiteljsko stablo — nova poruka:\n\n" +
      clean.slice(0, 3500);

    const r = await fetch(
      `https://api.telegram.org/bot${token}/sendMessage`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chat, text: message }),
      },
    );

    if (!r.ok) return json({ error: await r.text() }, 502);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
