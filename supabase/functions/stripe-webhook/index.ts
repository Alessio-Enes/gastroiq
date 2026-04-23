import Stripe from "https://esm.sh/stripe@13.3.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2023-10-16", httpClient: Stripe.createFetchHttpClient() });
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
function safeDate(ts) { if (!ts || ts <= 0) return null; try { return new Date(ts * 1000).toISOString(); } catch { return null; } }
Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature")!;
  const body = await req.text();
  let event;
  try { const cp = Stripe.createSubtleCryptoProvider(); event = await stripe.webhooks.constructEventAsync(body, signature, Deno.env.get("STRIPE_WEBHOOK_SECRET")!, undefined, cp); } catch (err) { console.error("Sig error:", err.message); return new Response(`Webhook Error: ${err.message}`, { status: 400 }); }
  console.log("Event:", event.type);
  if (["customer.subscription.created","customer.subscription.updated","customer.subscription.deleted"].includes(event.type)) {
    const sub = event.data.object;
    const meta = sub.metadata || {};
    const user_id = meta.user_id;
    const plan = meta.plan;
    console.log("user_id:", user_id, "plan:", plan, "customer:", sub.customer, "sub_id:", sub.id);
    if (!user_id) { console.error("Kein user_id!"); return new Response("Kein user_id in metadata", { status: 400 }); }
    if (event.type === "customer.subscription.deleted") {
      const { error } = await supabase.from("subscriptions").update({ status: "canceled", plan: "trial" }).eq("user_id", user_id);
      console.log("Delete:", error ? error.message : "ok");
    } else {
      const row = { user_id, plan: plan ?? "bronze", status: sub.status, stripe_customer_id: sub.customer, stripe_subscription_id: sub.id, current_period_start: safeDate(sub.current_period_start), current_period_end: safeDate(sub.current_period_end) };
      console.log("Upsert row:", JSON.stringify(row));
      const { data, error } = await supabase.from("subscriptions").upsert(row, { onConflict: "user_id" }).select();
      console.log("Upsert data:", JSON.stringify(data), "error:", error ? JSON.stringify(error) : "none");
    }
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
