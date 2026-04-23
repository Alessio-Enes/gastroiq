import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";

const supabaseAdmin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { autoRefreshToken: false, persistSession: false } });
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
const cors = { "Access-Control-Allow-Origin": "https://gastroiq.de", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "authorization, content-type" };

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: cors });
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) return new Response("Unauthorized", { status: 401, headers: cors });
  const { data: { user }, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !user) return new Response("Unauthorized", { status: 401, headers: cors });
  try {
    const { data: sub } = await supabaseAdmin.from("subscriptions").select("stripe_subscription_id").eq("user_id", user.id).single();
    if (sub?.stripe_subscription_id) { try { await stripe.subscriptions.cancel(sub.stripe_subscription_id); } catch(e) { console.warn("Stripe cancel failed:", e.message); } }
    for (const table of ["revenue_entries","cost_entries","staff_entries","product_sales","inventory_entries","reports","subscriptions"]) {
      await supabaseAdmin.from(table).delete().eq("user_id", user.id);
    }
    const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(user.id);
    if (delErr) return new Response(JSON.stringify({ error: delErr.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
    return new Response(JSON.stringify({ success: true, deleted_at: new Date().toISOString() }), { status: 200, headers: { ...cors, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});