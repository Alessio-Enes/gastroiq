# ============================================================
# GastroIQ – Master Deploy Script
# Ausführen: .\gastroiq-deploy.ps1
# Voraussetzungen: git, supabase CLI (Scoop), Node installiert
# Arbeitsverzeichnis: C:\Users\alessio.steinike\Documents\gastroiq
# ============================================================

Set-Location "C:\Users\alessio.steinike\Documents\gastroiq"
$ErrorActionPreference = "Stop"

function Write-Step { param($n, $text) Write-Host "`n[$n] $text" -ForegroundColor Cyan }
function Write-OK   { param($text) Write-Host "    OK: $text" -ForegroundColor Green }
function Write-Warn { param($text) Write-Host "    WARN: $text" -ForegroundColor Yellow }

Write-Host "`n================================================" -ForegroundColor Magenta
Write-Host "  GastroIQ Deploy Script" -ForegroundColor Magenta
Write-Host "================================================`n" -ForegroundColor Magenta

# ============================================================
# SCHRITT 1: vercel.json
# ============================================================
Write-Step "1/7" "vercel.json – Security Headers schreiben"

@'
{
  "cleanUrls": true,
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains; preload" },
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "X-Frame-Options", "value": "SAMEORIGIN" },
        { "key": "X-XSS-Protection", "value": "1; mode=block" },
        { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
        { "key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=(), interest-cohort=()" },
        { "key": "Content-Security-Policy", "value": "default-src 'self'; script-src 'self' 'unsafe-inline' https://js.stripe.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self' https://*.supabase.co https://api.stripe.com https://vitals.vercel-insights.com; frame-src https://js.stripe.com https://hooks.stripe.com; object-src 'none'; base-uri 'self'; form-action 'self'" }
      ]
    }
  ],
  "redirects": [
    {
      "source": "/(.*)",
      "has": [{ "type": "header", "key": "x-forwarded-proto", "value": "http" }],
      "destination": "https://gastroiq.de/$1",
      "permanent": true
    }
  ]
}
'@ | Set-Content -Path "vercel.json" -Encoding UTF8
Write-OK "vercel.json erstellt"

# ============================================================
# SCHRITT 2: SQL-Migration Datei
# ============================================================
Write-Step "2/7" "RLS-Fix SQL-Datei schreiben"

New-Item -ItemType Directory -Force -Path "supabase\migrations" | Out-Null

@'
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own subscription" ON subscriptions;
DROP POLICY IF EXISTS "Service role can manage subscriptions" ON subscriptions;
DROP POLICY IF EXISTS "service_role_all" ON subscriptions;
DROP POLICY IF EXISTS "Enable all for service_role" ON subscriptions;
DROP POLICY IF EXISTS "service_role_full_access" ON subscriptions;
DROP POLICY IF EXISTS "user_read_own_subscription" ON subscriptions;

CREATE POLICY "service_role_full_access"
  ON subscriptions FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "user_read_own_subscription"
  ON subscriptions FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

ALTER TABLE subscriptions
  ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
  ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'trialing',
  ADD COLUMN IF NOT EXISTS plan TEXT DEFAULT 'bronze',
  ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS current_period_end TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_customer_id ON subscriptions (stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON subscriptions (user_id);
'@ | Set-Content -Path "supabase\migrations\001_rls_fix.sql" -Encoding UTF8
Write-OK "Migration-Datei geschrieben"

# ============================================================
# SCHRITT 3: SQL via Supabase CLI ausführen
# ============================================================
Write-Step "3/7" "RLS-Fix in Supabase ausführen"

try {
    $sqlContent = Get-Content "supabase\migrations\001_rls_fix.sql" -Raw
    $sqlContent | supabase db execute --project-ref vrksgszggavczivojqvr
    Write-OK "RLS-Policies gesetzt, Spalten ergaenzt, Indexes erstellt"
} catch {
    Write-Warn "SQL-Ausfuehrung fehlgeschlagen: $_"
    Write-Warn "Fuehre die Datei supabase\migrations\001_rls_fix.sql manuell im Supabase SQL Editor aus!"
}

# ============================================================
# SCHRITT 4: Edge Functions
# ============================================================
Write-Step "4/7" "Edge Functions schreiben"

# stripe-webhook
New-Item -ItemType Directory -Force -Path "supabase\functions\stripe-webhook" | Out-Null
@'
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
);

serve(async (req: Request) => {
  const signature = req.headers.get("stripe-signature");
  if (!signature) return new Response("Missing signature", { status: 400 });

  let event: Stripe.Event;
  try {
    const body = await req.text();
    event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret);
    console.log(`[webhook] ${event.type} | ${event.id}`);
  } catch (err) {
    console.error("[webhook] Signature error:", err.message);
    return new Response(`Webhook error: ${err.message}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const userId = session.metadata?.user_id;
        if (!userId) { console.error("[webhook] No user_id in metadata"); break; }

        const payload = {
          user_id: userId,
          stripe_customer_id: session.customer as string,
          stripe_subscription_id: session.subscription as string,
          status: "active",
          plan: session.metadata?.plan ?? "bronze",
          updated_at: new Date().toISOString(),
        };
        console.log("[webhook] Upserting:", JSON.stringify(payload));

        const { data, error } = await supabase
          .from("subscriptions")
          .upsert(payload, { onConflict: "user_id" })
          .select();

        if (error) { console.error("[webhook] UPSERT FAILED:", JSON.stringify(error)); return new Response(`DB error: ${error.message}`, { status: 500 }); }
        console.log("[webhook] UPSERT SUCCESS:", JSON.stringify(data));
        break;
      }
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        await supabase.from("subscriptions").update({
          status: sub.status,
          stripe_subscription_id: sub.id,
          current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
          updated_at: new Date().toISOString(),
        }).eq("stripe_customer_id", sub.customer as string);
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
      default:
        console.log(`[webhook] Unhandled: ${event.type}`);
    }
  } catch (err) {
    console.error("[webhook] Handler error:", err.message);
    return new Response(`Handler error: ${err.message}`, { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { status: 200, headers: { "Content-Type": "application/json" } });
});
'@ | Set-Content -Path "supabase\functions\stripe-webhook\index.ts" -Encoding UTF8

# delete-user-data
New-Item -ItemType Directory -Force -Path "supabase\functions\delete-user-data" | Out-Null
@'
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
);
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient(),
});
const cors = {
  "Access-Control-Allow-Origin": "https://gastroiq.de",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: cors });

  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) return new Response("Unauthorized", { status: 401, headers: cors });

  const { data: { user }, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !user) return new Response("Unauthorized", { status: 401, headers: cors });

  const userId = user.id;
  console.log(`[delete-user] Deleting user: ${userId}`);

  try {
    const { data: sub } = await supabaseAdmin.from("subscriptions").select("stripe_subscription_id").eq("user_id", userId).single();
    if (sub?.stripe_subscription_id) {
      try { await stripe.subscriptions.cancel(sub.stripe_subscription_id); } catch(e) { console.warn("[delete-user] Stripe cancel failed:", e.message); }
    }

    for (const table of ["revenue_entries","cost_entries","staff_entries","product_sales","inventory_entries","reports","subscriptions"]) {
      await supabaseAdmin.from(table).delete().eq("user_id", userId);
    }

    const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(userId);
    if (delErr) return new Response(JSON.stringify({ error: delErr.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });

    return new Response(JSON.stringify({ success: true, deleted_at: new Date().toISOString() }), { status: 200, headers: { ...cors, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
'@ | Set-Content -Path "supabase\functions\delete-user-data\index.ts" -Encoding UTF8

Write-OK "Edge Function Dateien geschrieben"

# ============================================================
# SCHRITT 5: Edge Functions deployen
# ============================================================
Write-Step "5/7" "Edge Functions deployen"

try {
    Write-Host "    Deploying stripe-webhook..." -ForegroundColor Gray
    supabase functions deploy stripe-webhook --no-verify-jwt --project-ref vrksgszggavczivojqvr
    Write-OK "stripe-webhook deployed"
} catch {
    Write-Warn "stripe-webhook deploy fehlgeschlagen: $_"
}

try {
    Write-Host "    Deploying delete-user-data..." -ForegroundColor Gray
    supabase functions deploy delete-user-data --project-ref vrksgszggavczivojqvr
    Write-OK "delete-user-data deployed"
} catch {
    Write-Warn "delete-user-data deploy fehlgeschlagen: $_"
}

# ============================================================
# SCHRITT 6: Rechtsseiten + Cookie-Banner + 404
# ============================================================
Write-Step "6/7" "HTML-Seiten schreiben (Impressum, Datenschutz, AGB, 404, Cookie-Banner)"

# --- Cookie-Consent-Patch ---
@'
<!-- GastroIQ Cookie-Consent – vor </body> einfuegen -->
<style>
#gastroiq-cookie-banner{position:fixed;bottom:0;left:0;right:0;z-index:99999;background:#1a1533;border-top:1px solid rgba(99,102,241,.3);padding:1rem 1.5rem;display:flex;align-items:center;gap:1rem;flex-wrap:wrap;font-family:'Inter',sans-serif;font-size:13px;color:rgba(255,255,255,.8);box-shadow:0 -4px 24px rgba(0,0,0,.4)}
#gastroiq-cookie-banner.hidden{display:none}
.cb-text{flex:1;min-width:200px;line-height:1.5}
.cb-text a{color:#a78bfa;text-decoration:none}
.cb-actions{display:flex;gap:.5rem;flex-shrink:0;flex-wrap:wrap}
.cb-btn{padding:.45rem 1rem;border-radius:6px;font-size:13px;font-weight:500;cursor:pointer;border:none;font-family:'Inter',sans-serif;transition:opacity .15s}
.cb-btn:hover{opacity:.85}
.cb-btn-accept{background:#6366f1;color:#fff}
.cb-btn-essential{background:transparent;color:rgba(255,255,255,.6);border:1px solid rgba(255,255,255,.2)}
#gastroiq-cookie-modal{display:none;position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,.6);align-items:center;justify-content:center}
#gastroiq-cookie-modal.open{display:flex}
.cb-modal-box{background:#1a1533;border:1px solid rgba(99,102,241,.3);border-radius:12px;padding:1.5rem;max-width:480px;width:90%;font-family:'Inter',sans-serif;color:rgba(255,255,255,.85)}
.cb-modal-box h3{font-size:16px;font-weight:600;margin-bottom:1rem;color:#fff}
.cb-toggle-row{display:flex;justify-content:space-between;align-items:center;padding:.75rem 0;border-bottom:1px solid rgba(255,255,255,.08);font-size:13px}
.cb-toggle-row:last-of-type{border-bottom:none}
.cb-toggle-label{font-weight:500;color:#fff;font-size:13px}
.cb-toggle-desc{font-size:11px;color:rgba(255,255,255,.45);margin-top:2px}
.cb-toggle{position:relative;width:36px;height:20px;flex-shrink:0}
.cb-toggle input{opacity:0;width:0;height:0}
.cb-slider{position:absolute;cursor:pointer;inset:0;background:rgba(255,255,255,.15);border-radius:20px;transition:background .2s}
.cb-toggle input:checked+.cb-slider{background:#6366f1}
.cb-slider:before{position:absolute;content:'';height:14px;width:14px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:transform .2s}
.cb-toggle input:checked+.cb-slider:before{transform:translateX(16px)}
.cb-modal-actions{display:flex;gap:.5rem;margin-top:1.25rem;justify-content:flex-end}
</style>
<div id="gastroiq-cookie-banner" class="hidden">
  <div class="cb-text">Wir verwenden Cookies. Notwendige sind immer aktiv. <a href="/datenschutz">Datenschutz</a></div>
  <div class="cb-actions">
    <button class="cb-btn cb-btn-essential" onclick="GastroCookies.acceptEssential()">Nur notwendige</button>
    <button class="cb-btn cb-btn-accept" onclick="GastroCookies.acceptAll()">Alle akzeptieren</button>
    <button style="background:none;border:none;color:rgba(255,255,255,.4);font-size:12px;text-decoration:underline;cursor:pointer" onclick="GastroCookies.openSettings()">Einstellungen</button>
  </div>
</div>
<div id="gastroiq-cookie-modal">
  <div class="cb-modal-box">
    <h3>Cookie-Einstellungen</h3>
    <div class="cb-toggle-row"><div><div class="cb-toggle-label">Notwendige</div><div class="cb-toggle-desc">Login, Session – immer aktiv</div></div><label class="cb-toggle"><input type="checkbox" checked disabled><span class="cb-slider"></span></label></div>
    <div class="cb-toggle-row"><div><div class="cb-toggle-label">Analyse</div><div class="cb-toggle-desc">Anonyme Nutzungsstatistiken</div></div><label class="cb-toggle"><input type="checkbox" id="cb-analytics"><span class="cb-slider"></span></label></div>
    <div class="cb-modal-actions"><button class="cb-btn cb-btn-essential" onclick="GastroCookies.saveSettings()">Speichern</button><button class="cb-btn cb-btn-accept" onclick="GastroCookies.acceptAll()">Alle akzeptieren</button></div>
  </div>
</div>
<script>
(function(){
var K='gastroiq_cookie_consent',b=document.getElementById('gastroiq-cookie-banner'),m=document.getElementById('gastroiq-cookie-modal');
window.GastroCookies={
  init:function(){var c=localStorage.getItem(K);if(!c)b.classList.remove('hidden');else this._apply(JSON.parse(c));},
  acceptAll:function(){var p={essential:true,analytics:true,ts:Date.now()};localStorage.setItem(K,JSON.stringify(p));b.classList.add('hidden');m.classList.remove('open');this._apply(p);},
  acceptEssential:function(){var p={essential:true,analytics:false,ts:Date.now()};localStorage.setItem(K,JSON.stringify(p));b.classList.add('hidden');m.classList.remove('open');},
  openSettings:function(){var c=localStorage.getItem(K);if(c){var p=JSON.parse(c);document.getElementById('cb-analytics').checked=!!p.analytics;}m.classList.add('open');},
  saveSettings:function(){var p={essential:true,analytics:document.getElementById('cb-analytics').checked,ts:Date.now()};localStorage.setItem(K,JSON.stringify(p));b.classList.add('hidden');m.classList.remove('open');this._apply(p);},
  reset:function(){localStorage.removeItem(K);b.classList.remove('hidden');},
  _apply:function(p){if(p.analytics&&typeof window.va==='undefined'){var s=document.createElement('script');s.src='/_vercel/insights/script.js';s.defer=true;document.head.appendChild(s);}}
};
document.readyState==='loading'?document.addEventListener('DOMContentLoaded',function(){GastroCookies.init();}):GastroCookies.init();
})();
</script>
'@ | Set-Content -Path "patches\cookie-consent-banner.html" -Encoding UTF8

# --- 404.html ---
New-Item -ItemType Directory -Force -Path "patches" | Out-Null
@'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nicht gefunden – GastroIQ</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Inter',sans-serif;background:#0e0c1f;color:rgba(255,255,255,.85);min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:2rem}.logo{font-size:22px;font-weight:600;color:#a78bfa;margin-bottom:3rem}.logo span{color:#6366f1}.code{font-size:96px;font-weight:600;color:#2e1f5e;line-height:1;margin-bottom:1rem}h1{font-size:24px;font-weight:500;margin-bottom:.75rem}p{font-size:15px;color:rgba(255,255,255,.45);max-width:380px;line-height:1.6;margin-bottom:2rem}.btn{display:inline-block;background:#6366f1;color:#fff;text-decoration:none;padding:.65rem 1.5rem;border-radius:8px;font-size:14px;font-weight:500}.links{margin-top:2rem;display:flex;gap:1.5rem;font-size:13px}.links a{color:rgba(255,255,255,.35);text-decoration:none}</style>
</head>
<body>
<div class="logo">Gastro<span>IQ</span></div>
<div class="code">404</div>
<h1>Seite nicht gefunden</h1>
<p>Diese Seite existiert nicht oder wurde verschoben.</p>
<a href="/" class="btn">Zur Startseite</a>
<div class="links"><a href="/impressum">Impressum</a><a href="/datenschutz">Datenschutz</a><a href="mailto:support@gastroiq.de">Support</a></div>
</body></html>
'@ | Set-Content -Path "404.html" -Encoding UTF8

# --- Impressum ---
@'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Impressum – GastroIQ</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Inter',sans-serif;background:#0e0c1f;color:rgba(255,255,255,.85)}.nav{padding:1rem 2rem;border-bottom:1px solid rgba(255,255,255,.08);display:flex;align-items:center}.nav a{text-decoration:none}.logo{font-size:18px;font-weight:600;color:#a78bfa}.logo span{color:#6366f1}.back{font-size:13px;color:rgba(255,255,255,.4);margin-left:auto}.content{max-width:720px;margin:0 auto;padding:3rem 2rem}h1{font-size:28px;font-weight:600;margin-bottom:.5rem}.sub{font-size:13px;color:rgba(255,255,255,.35);margin-bottom:2.5rem}h2{font-size:16px;font-weight:500;color:#a78bfa;margin:2rem 0 .75rem}p{font-size:14px;line-height:1.75;color:rgba(255,255,255,.65);margin-bottom:.5rem}a{color:#6366f1}.ph{background:rgba(99,102,241,.1);border:1px dashed rgba(99,102,241,.4);border-radius:6px;padding:.25rem .5rem;font-size:13px;color:#a78bfa}.footer{border-top:1px solid rgba(255,255,255,.08);padding:1.5rem 2rem;display:flex;gap:1.5rem;font-size:13px;max-width:720px;margin:0 auto}.footer a{color:rgba(255,255,255,.35);text-decoration:none}</style>
</head>
<body>
<nav class="nav"><a href="/" class="logo">Gastro<span>IQ</span></a><a href="/" class="back">← Zurück</a></nav>
<div class="content">
<h1>Impressum</h1><p class="sub">Angaben gemäß § 5 TMG</p>
<h2>Anbieter</h2>
<p><span class="ph">[ EUER FIRMENNAME ]</span><br><span class="ph">[ STRASSE HAUSNR. ]</span><br><span class="ph">[ PLZ ORT ]</span><br>Deutschland</p>
<h2>Kontakt</h2>
<p>E-Mail: <span class="ph">[ hello@gastroiq.de ]</span></p>
<h2>Handelsregister</h2>
<p>Registergericht: <span class="ph">[ Amtsgericht ... ]</span><br>HRB: <span class="ph">[ ... ]</span></p>
<h2>Umsatzsteuer-ID</h2>
<p>USt-ID gemäß § 27a UStG: <span class="ph">[ DE... ]</span></p>
<h2>Geschäftsführung</h2>
<p><span class="ph">[ Alessio ... und Enes ... ]</span></p>
<h2>Verantwortlich für den Inhalt (§ 55 Abs. 2 RStV)</h2>
<p><span class="ph">[ Name, Adresse wie oben ]</span></p>
<h2>Streitschlichtung</h2>
<p>EU-Plattform zur Online-Streitbeilegung: <a href="https://ec.europa.eu/consumers/odr/" target="_blank">ec.europa.eu/consumers/odr</a><br>Wir nehmen nicht an Streitbeilegungsverfahren vor einer Verbraucherschlichtungsstelle teil.</p>
</div>
<div class="footer"><a href="/impressum">Impressum</a><a href="/datenschutz">Datenschutz</a><a href="/agb">AGB</a></div>
</body></html>
'@ | Set-Content -Path "impressum.html" -Encoding UTF8

# --- Datenschutz ---
@'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Datenschutz – GastroIQ</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Inter',sans-serif;background:#0e0c1f;color:rgba(255,255,255,.85)}.nav{padding:1rem 2rem;border-bottom:1px solid rgba(255,255,255,.08);display:flex;align-items:center}.nav a{text-decoration:none}.logo{font-size:18px;font-weight:600;color:#a78bfa}.logo span{color:#6366f1}.back{font-size:13px;color:rgba(255,255,255,.4);margin-left:auto}.content{max-width:720px;margin:0 auto;padding:3rem 2rem}h1{font-size:28px;font-weight:600;margin-bottom:.5rem}.sub{font-size:13px;color:rgba(255,255,255,.35);margin-bottom:2.5rem}h2{font-size:16px;font-weight:500;color:#a78bfa;margin:2rem 0 .75rem;border-top:1px solid rgba(255,255,255,.06);padding-top:1.5rem}h2:first-of-type{border-top:none;padding-top:0}h3{font-size:14px;font-weight:500;margin:1.25rem 0 .5rem;color:rgba(255,255,255,.9)}p,li{font-size:14px;line-height:1.75;color:rgba(255,255,255,.65);margin-bottom:.5rem}ul{padding-left:1.25rem;margin-bottom:.75rem}a{color:#6366f1}strong{font-weight:500;color:rgba(255,255,255,.85)}.ph{background:rgba(99,102,241,.1);border:1px dashed rgba(99,102,241,.4);border-radius:6px;padding:.25rem .5rem;font-size:13px;color:#a78bfa}.warn{background:rgba(99,102,241,.08);border-left:3px solid #6366f1;padding:.75rem 1rem;border-radius:0 6px 6px 0;margin:1rem 0;font-size:13px;color:rgba(255,255,255,.5)}table{width:100%;border-collapse:collapse;margin:1rem 0;font-size:13px}th{text-align:left;padding:.5rem .75rem;background:rgba(255,255,255,.05);color:rgba(255,255,255,.5);font-weight:500}td{padding:.5rem .75rem;border-top:1px solid rgba(255,255,255,.06);color:rgba(255,255,255,.65);vertical-align:top}.footer{border-top:1px solid rgba(255,255,255,.08);padding:1.5rem 2rem;display:flex;gap:1.5rem;font-size:13px;max-width:720px;margin:0 auto}.footer a{color:rgba(255,255,255,.35);text-decoration:none}</style>
</head>
<body>
<nav class="nav"><a href="/" class="logo">Gastro<span>IQ</span></a><a href="/" class="back">← Zurück</a></nav>
<div class="content">
<h1>Datenschutzerklärung</h1><p class="sub">Stand: <span class="ph">[ DATUM ]</span></p>
<div class="warn">⚠️ Entwurf – bitte durch Datenschutzanwalt prüfen lassen vor Launch.</div>

<h2>1. Verantwortlicher</h2>
<p><span class="ph">[ Firmenname, Adresse, E-Mail ]</span></p>

<h2>2. Erhobene Daten</h2>
<h3>2.1 Nutzerkonto</h3>
<p>E-Mail, Passwort (bcrypt-gehasht), Registrierungszeitpunkt.<br><strong>Rechtsgrundlage:</strong> Art. 6 Abs. 1 lit. b DSGVO</p>
<h3>2.2 Zahlungsdaten</h3>
<p>Abwicklung über Stripe. Wir speichern nur Stripe-Customer-ID und Subscription-Status.<br><strong>Rechtsgrundlage:</strong> Art. 6 Abs. 1 lit. b DSGVO</p>
<h3>2.3 Betriebsdaten (Gastronomiebetrieb)</h3>
<p>Eure eingegebenen Daten (Umsätze, Kosten etc.) werden ausschließlich für euch gespeichert und nicht für eigene Zwecke genutzt.<br><strong>Rechtsgrundlage:</strong> Art. 6 Abs. 1 lit. b DSGVO</p>
<h3>2.4 Analyse (nur mit Einwilligung)</h3>
<p>Vercel Analytics (anonym) – nur bei Einwilligung über Cookie-Banner.<br><strong>Rechtsgrundlage:</strong> Art. 6 Abs. 1 lit. a DSGVO</p>

<h2>3. Sub-Prozessoren (Art. 28 DSGVO)</h2>
<table><tr><th>Anbieter</th><th>Zweck</th><th>Serverstandort</th></tr>
<tr><td>Supabase, Inc.</td><td>Datenbank, Auth</td><td>EU (Frankfurt)</td></tr>
<tr><td>Stripe, Inc.</td><td>Zahlungen</td><td>EU</td></tr>
<tr><td>Vercel, Inc.</td><td>Hosting</td><td>EU</td></tr></table>

<h2>4. Speicherdauer</h2>
<ul><li>Kontodaten: bis Account-Löschung</li><li>Rechnungsdaten: 10 Jahre (§ 147 AO)</li><li>Server-Logs: max. 30 Tage</li></ul>

<h2>5. Eure Rechte (Art. 15–22 DSGVO)</h2>
<ul><li><strong>Auskunft</strong> (Art. 15), <strong>Berichtigung</strong> (Art. 16), <strong>Löschung</strong> (Art. 17 – im Account-Bereich verfügbar)</li>
<li><strong>Datenübertragbarkeit</strong> (Art. 20), <strong>Widerspruch</strong> (Art. 21)</li></ul>
<p>Anfragen an: <span class="ph">[ datenschutz@gastroiq.de ]</span> – Antwort innerhalb 30 Tagen.</p>

<h2>6. Datensicherheit</h2>
<ul><li>HTTPS/TLS 1.2+, Passwörter bcrypt-gehasht, Row Level Security in der Datenbank, EU-Server</li></ul>

<h2>7. Beschwerderecht</h2>
<p>Zuständige Aufsichtsbehörde: <a href="https://www.bfdi.bund.de" target="_blank">BfDI</a></p>
</div>
<div class="footer"><a href="/impressum">Impressum</a><a href="/datenschutz">Datenschutz</a><a href="/agb">AGB</a></div>
</body></html>
'@ | Set-Content -Path "datenschutz.html" -Encoding UTF8

# --- AGB ---
@'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AGB – GastroIQ</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Inter',sans-serif;background:#0e0c1f;color:rgba(255,255,255,.85)}.nav{padding:1rem 2rem;border-bottom:1px solid rgba(255,255,255,.08);display:flex;align-items:center}.nav a{text-decoration:none}.logo{font-size:18px;font-weight:600;color:#a78bfa}.logo span{color:#6366f1}.back{font-size:13px;color:rgba(255,255,255,.4);margin-left:auto}.content{max-width:720px;margin:0 auto;padding:3rem 2rem}h1{font-size:28px;font-weight:600;margin-bottom:.5rem}.sub{font-size:13px;color:rgba(255,255,255,.35);margin-bottom:2.5rem}h2{font-size:16px;font-weight:500;color:#a78bfa;margin:2rem 0 .75rem;border-top:1px solid rgba(255,255,255,.06);padding-top:1.5rem}h2:first-of-type{border-top:none;padding-top:0}p,li{font-size:14px;line-height:1.75;color:rgba(255,255,255,.65);margin-bottom:.5rem}ul{padding-left:1.25rem;margin-bottom:.75rem}a{color:#6366f1}strong{font-weight:500;color:rgba(255,255,255,.85)}.ph{background:rgba(99,102,241,.1);border:1px dashed rgba(99,102,241,.4);border-radius:6px;padding:.25rem .5rem;font-size:13px;color:#a78bfa}.warn{background:rgba(99,102,241,.08);border-left:3px solid #6366f1;padding:.75rem 1rem;border-radius:0 6px 6px 0;margin:1rem 0;font-size:13px;color:rgba(255,255,255,.5)}table{width:100%;border-collapse:collapse;margin:1rem 0;font-size:13px}th{text-align:left;padding:.5rem .75rem;background:rgba(255,255,255,.05);color:rgba(255,255,255,.5);font-weight:500}td{padding:.5rem .75rem;border-top:1px solid rgba(255,255,255,.06);color:rgba(255,255,255,.65)}.footer{border-top:1px solid rgba(255,255,255,.08);padding:1.5rem 2rem;display:flex;gap:1.5rem;font-size:13px;max-width:720px;margin:0 auto}.footer a{color:rgba(255,255,255,.35);text-decoration:none}</style>
</head>
<body>
<nav class="nav"><a href="/" class="logo">Gastro<span>IQ</span></a><a href="/" class="back">← Zurück</a></nav>
<div class="content">
<h1>Allgemeine Geschäftsbedingungen</h1><p class="sub">Stand: <span class="ph">[ DATUM ]</span></p>
<div class="warn">⚠️ Entwurf – anwaltliche Prüfung vor Launch empfohlen.</div>

<h2>§ 1 Geltungsbereich</h2>
<p>Diese AGB gelten für alle Verträge zwischen <span class="ph">[ Firmenname, Adresse ]</span> („GastroIQ") und gewerblichen Kunden über die Nutzung der SaaS-Plattform GastroIQ. <strong>GastroIQ richtet sich ausschließlich an Unternehmer (§ 14 BGB).</strong> Verbraucher sind ausgeschlossen.</p>

<h2>§ 2 Vertragsgegenstand</h2>
<p>GastroIQ stellt eine webbasierte SaaS-Lösung zur Gastronomie-Analyse bereit. Der Umfang richtet sich nach dem gebuchten Tarif. Der Kunde erhält kein Recht auf den Quellcode.</p>

<h2>§ 3 Testphase</h2>
<p>Neukunden erhalten 14 Tage kostenlosen Test-Zugang. Nach Ablauf ist ein kostenpflichtiger Tarif erforderlich. Die Karte wird erst nach Ablauf der Testphase belastet.</p>

<h2>§ 4 Tarife und Preise</h2>
<table><tr><th>Tarif</th><th>Netto</th><th>Brutto (19% MwSt)</th><th>Abrechnung</th></tr>
<tr><td>Bronze</td><td>24,37 €/Mo</td><td>29,00 €/Mo</td><td>monatlich</td></tr>
<tr><td>Silber</td><td>49,58 €/Mo</td><td>59,00 €/Mo</td><td>monatlich</td></tr>
<tr><td>Gold</td><td>83,19 €/Mo</td><td>99,00 €/Mo</td><td>monatlich</td></tr></table>
<p>Preisänderungen werden 30 Tage vorab per E-Mail angekündigt. Der Kunde hat dann ein Sonderkündigungsrecht.</p>

<h2>§ 5 Zahlung</h2>
<p>Zahlung monatlich im Voraus per Kreditkarte oder SEPA über Stripe. Rechnung automatisch per E-Mail. Bei Verzug: Mahnung, dann Zugangssperre.</p>

<h2>§ 6 Laufzeit und Kündigung</h2>
<p>Vertrag auf unbestimmte Zeit. Kündigung: <strong>30 Tage zum Monatsende</strong> per E-Mail an <span class="ph">[ kuendigung@gastroiq.de ]</span> oder im Account-Bereich.</p>

<h2>§ 7 Pflichten des Kunden</h2>
<ul><li>Zugangsdaten geheim halten</li><li>Keine rechtswidrige Nutzung</li><li>Kein Scraping oder automatisierte Abfragen</li><li>Zugangsdaten nicht weitergeben</li></ul>

<h2>§ 8 Verfügbarkeit</h2>
<p>GastroIQ strebt 99% Verfügbarkeit/Monat an. Wartungsfenster: 22–06 Uhr MEZ, 24h Vorankündigung.</p>

<h2>§ 9 Haftung</h2>
<p>Unbeschränkte Haftung bei Vorsatz, grober Fahrlässigkeit und Personenschäden. Bei einfacher Fahrlässigkeit nur bei Kardinalpflichten, begrenzt auf 12 Monatsbeiträge. Keine Haftung für fehlerhafte Kundendaten.</p>

<h2>§ 10 Geistiges Eigentum</h2>
<p>Alle Rechte an GastroIQ verbleiben bei GastroIQ. Kundendaten bleiben Eigentum des Kunden.</p>

<h2>§ 11 Änderungen der AGB</h2>
<p>Änderungen werden 30 Tage vorab per E-Mail mitgeteilt. Kein Widerspruch binnen 30 Tagen = Zustimmung (auf Widerspruchsrecht wird hingewiesen).</p>

<h2>§ 12 Schlussbestimmungen</h2>
<p>Deutsches Recht, Ausschluss UN-Kaufrecht. Gerichtsstand: <span class="ph">[ Sitz der Gesellschaft ]</span>.</p>
</div>
<div class="footer"><a href="/impressum">Impressum</a><a href="/datenschutz">Datenschutz</a><a href="/agb">AGB</a></div>
</body></html>
'@ | Set-Content -Path "agb.html" -Encoding UTF8

Write-OK "Alle HTML-Seiten geschrieben"

# ============================================================
# SCHRITT 7: Git commit und push
# ============================================================
Write-Step "7/7" "Git commit und push"

git add -A
git commit -m "feat: security headers, RLS fix, edge functions, legal pages, cookie consent, 404"
git push

Write-Host "`n================================================" -ForegroundColor Green
Write-Host "  DEPLOY ABGESCHLOSSEN" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Naechste manuelle Schritte:" -ForegroundColor Yellow
Write-Host "  1. Platzhalter [ ... ] in impressum.html, datenschutz.html, agb.html ausfuellen" -ForegroundColor White
Write-Host "  2. Stripe Tax aktivieren: dashboard.stripe.com -> Tax" -ForegroundColor White
Write-Host "  3. Stripe Live-Keys hinterlegen (nach Verifizierung)" -ForegroundColor White
Write-Host "  4. supabase/functions/stripe-webhook/index.ts: echte Price-IDs eintragen" -ForegroundColor White
Write-Host "  5. Cookie-Consent-Banner in gastroiq.html vor </body> einfuegen:" -ForegroundColor White
Write-Host "     Inhalt von patches\cookie-consent-banner.html kopieren" -ForegroundColor Gray
Write-Host "  6. Anwalt: AGB + Datenschutz pruefen lassen" -ForegroundColor White
Write-Host ""
Write-Host "Testen:" -ForegroundColor Yellow
Write-Host "  securityheaders.com mit gastroiq.de (Ziel: A+)" -ForegroundColor White
Write-Host "  gastroiq.de/impressum, /datenschutz, /agb, /irgendwas-gibts-nicht (404)" -ForegroundColor White
Write-Host ""
