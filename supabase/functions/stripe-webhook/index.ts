import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { autoRefreshToken: false, persistSession: false } });

serve(async (req: Request) => {
  const signature = req.headers.get("stripe-signature");
  if (!signature) return new Response("Missing signature", { status: 400 });
  let event: Stripe.Event;
  try {
    const body = await req.text();
    event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret);
    console.log(`[webhook] ${event.type} | ${event.id}`);
  } catch (err) {
    return new Response(`Webhook error: ${err.message}`, { status: 400 });
  }
  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const userId = session.metadata?.user_id;
        if (!userId) { console.error("[webhook] No user_id in metadata"); break; }
        const payload = { user_id: userId, stripe_customer_id: session.customer as string, stripe_subscription_id: session.subscription as string, status: "active", plan: session.metadata?.plan ?? "bronze", updated_at: new Date().toISOString() };
        console.log("[webhook] Upserting:", JSON.stringify(payload));
        const { data, error } = await supabase.from("subscriptions").upsert(payload, { onConflict: "user_id" }).select();
        if (error) { console.error("[webhook] UPSERT FAILED:", JSON.stringify(error)); return new Response(`DB error: ${error.message}`, { status: 500 }); }
        console.log("[webhook] UPSERT SUCCESS:", JSON.stringify(data));
        break;
      }
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        await supabase.from("subscriptions").update({ status: sub.status, stripe_subscription_id: sub.id, current_period_end: new Date(sub.current_period_end * 1000).toISOString(), updated_at: new Date().toISOString() }).eq("stripe_customer_id", sub.customer as string);
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        await supabase.from("subscriptions").update({ status: "canceled", updated_at: new Date().toISOString() }).eq("stripe_customer_id", sub.customer as string);
        break;
      }
      case "invoice.payment_failed": {
        const inv = event.data.object as Stripe.Invoice;
        await supabase.from("subscriptions").update({ status: "past_due", updated_at: new Date().toISOString() }).eq("stripe_customer_id", inv.customer as string);
        break;
      }
      case "invoice.payment_succeeded": {
        const inv = event.data.object as Stripe.Invoice;
        await supabase.from("subscriptions").update({ status: "active", updated_at: new Date().toISOString() }).eq("stripe_customer_id", inv.customer as string);
        break;
      }
      default: console.log(`[webhook] Unhandled: ${event.type}`);
    }
  } catch (err) {
    return new Response(`Handler error: ${err.message}`, { status: 500 });
  }
  return new Response(JSON.stringify({ received: true }), { status: 200, headers: { "Content-Type": "application/json" } });
});