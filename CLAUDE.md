# GastroIQ – Projektkontext für Claude Code

## Stack
- Vanilla HTML/CSS/JS (keine Frameworks außer Chart.js)
- Supabase (Auth, Database, Edge Functions, RLS)
- Vercel (Deployment, cleanUrls: true – keine .html Extensions in Links!)
- Chart.js für Visualisierungen

## Projektstruktur
- gastroiq.html → Haupt-Dashboard (~6000 Zeilen, 15 Sub-Pages)
- gastroiq-auth.html → Login/Registration
- gastroiq-pos-integration.html → POS Integration Hub

## Design-Regeln
- Background: #0e0c1f (Dark Navy)
- Sidebar: #2e1f5e (Dark Purple)
- Primary: #6366f1 (Brand Purple)
- Accent: #a78bfa (Soft Violet)
- Headlines: Fraunces serif (900)
- Body: DM Sans / Inter
- Alle UI-Texte auf DEUTSCH
- Kein Emoji in der UI, minimalistisch, kein dekorativer Grid

## Wichtige Regeln
- Änderungen an gastroiq.html NUR als Patch-Snippets (vor </body>)
  → Datei ist zu groß für vollständige Rewrites
- JS-Funktionen können via window.functionName in Patches überschrieben werden
- Supabase Projekt ID: vrksgszggavczivojqvr
- Vercel: cleanUrls aktiviert, Links ohne .html

## Preisstufen
- Bronze: ~€49/Monat
- Silber: ~€79/Monat  
- Gold: ~€199/Monat

## Was gerade fehlt (Prioritäten)
1. Stripe Paywall + Feature Gating
2. Onboarding Flow
3. Mobile Responsiveness
4. SumUp OAuth Deployment (4 manuelle Schritte ausstehend)
