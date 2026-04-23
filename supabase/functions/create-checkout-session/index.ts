import Stripe from "https://esm.sh/stripe@13.3.0";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
});

Deno.serve(async (req) => {
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  };

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { plan, user_id, email } = await req.json();

    const priceMap: Record<string, string> = {
      bronze: Deno.env.get("STRIPE_PRICE_BRONZE")!,
      silber: Deno.env.get("STRIPE_PRICE_SILBER")!,
      gold:   Deno.env.get("STRIPE_PRICE_GOLD")!,
    };

    if (!priceMap[plan]) {
      throw new Error("Ungültiger Plan: " + plan);
    }

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ["card"],
      mode: "subscription",
      customer_email: email,
      line_items: [{ price: priceMap[plan], quantity: 1 }],
      subscription_data: {
        trial_period_days: 14,
        metadata: { user_id, plan },
      },
      metadata: { user_id, plan },
      success_url: "https://gastroiq.vercel.app/gastroiq?upgrade=success",
      cancel_url:  "https://gastroiq.vercel.app/gastroiq?upgrade=canceled",
    });

    return new Response(JSON.stringify({ url: session.url }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
