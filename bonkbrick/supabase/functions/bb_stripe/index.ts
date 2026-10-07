// BonkBrick Stripe Edge Function (name it: bb_stripe)
// Handles: Stripe Connect Express onboarding for sellers, marketplace checkout
// (destination charges with a platform fee), BonkBrick Plus subscriptions,
// the billing portal, and the Stripe webhook.
//
// Secrets to add in Supabase Dashboard -> Edge Functions -> Secrets:
//   STRIPE_SECRET_KEY        sk_live_... or sk_test_...
//   STRIPE_WEBHOOK_SECRET    whsec_...   (from the Stripe webhook you create)
//   STRIPE_PLUS_PRICE_ID     price_...   (monthly recurring price for Plus)
//   PLATFORM_FEE_PERCENT     10          (optional, default 10)
//   SITE_URL                 https://your-site.netlify.app/  (optional, locks redirects)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// IMPORTANT: turn OFF "Verify JWT" for this function. Stripe's webhook has no
// Supabase token. User calls are verified inside this code instead.

import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);
const FEE_PERCENT = Number(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "10");
const SITE_URL = Deno.env.get("SITE_URL") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function baseUrl(clientBase?: string) {
  const b = SITE_URL || clientBase || "";
  if (!/^https?:\/\//.test(b)) throw new Error("Missing return URL");
  return b.split("#")[0];
}

async function getUser(req: Request) {
  const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  if (!token) throw new Error("Please sign in first");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) throw new Error("Please sign in first");
  const { data: profile } = await admin.from("bb_profiles").select("*").eq("id", data.user.id).single();
  if (!profile) throw new Error("Profile missing");
  if (profile.banned) throw new Error("Your account is banned");
  const { data: priv } = await admin.from("bb_private").select("*").eq("id", data.user.id).maybeSingle();
  return { user: data.user, profile, priv: priv ?? { id: data.user.id } };
}

async function ensureCustomer(u: Awaited<ReturnType<typeof getUser>>) {
  if (u.priv.stripe_customer_id) return u.priv.stripe_customer_id as string;
  const c = await stripe.customers.create({
    email: u.user.email,
    metadata: { bb_user_id: u.user.id, bb_username: u.profile.username },
  });
  await admin.from("bb_private").upsert({ id: u.user.id, stripe_customer_id: c.id });
  return c.id;
}

function periodEnd(sub: Stripe.Subscription): string {
  // newer API versions moved current_period_end onto the subscription items
  const s = sub as unknown as { current_period_end?: number; items?: { data?: { current_period_end?: number }[] } };
  const end = s.current_period_end ?? s.items?.data?.[0]?.current_period_end ?? Math.floor(Date.now() / 1000) + 31 * 86400;
  return new Date(end * 1000).toISOString();
}

async function userForCustomer(customerId: string, fallback?: string | null) {
  if (fallback) return fallback;
  const { data } = await admin.from("bb_private").select("id").eq("stripe_customer_id", customerId).maybeSingle();
  return data?.id as string | undefined;
}

async function applySubscription(sub: Stripe.Subscription, userHint: string | null, stipend: boolean) {
  const customer = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  const userId = await userForCustomer(customer, sub.metadata?.bb_user_id || userHint);
  if (!userId) return;
  const active = ["active", "trialing", "past_due"].includes(sub.status);
  const until = active ? periodEnd(sub) : new Date().toISOString();
  const { error } = await admin.rpc("bb_set_plus", {
    p_user: userId, p_until: until, p_customer: customer, p_subscription: sub.id, p_stipend: stipend && active,
  });
  if (error) throw new Error(error.message);
}

async function markPaid(sessionId: string) {
  const { error } = await admin.rpc("bb_mark_order_paid", { p_session: sessionId });
  if (error) throw new Error(error.message);
}

async function handleWebhook(req: Request) {
  const sig = req.headers.get("stripe-signature") ?? "";
  const raw = await req.text();
  const event = await stripe.webhooks.constructEventAsync(
    raw, sig, Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "", undefined, cryptoProvider,
  );
  // idempotency: Stripe retries, we process each event once
  const { error: dupe } = await admin.from("bb_stripe_events").insert({ id: event.id });
  if (dupe) return json({ received: true, duplicate: true });

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode === "payment" && s.payment_status === "paid") {
          await markPaid(s.id);
        } else if (s.mode === "subscription" && s.subscription) {
          const sub = await stripe.subscriptions.retrieve(s.subscription as string);
          // first payment: stipend comes from invoice.paid, so no stipend here
          await applySubscription(sub, s.client_reference_id ?? s.metadata?.user_id ?? null, false);
        }
        break;
      }
      case "checkout.session.async_payment_succeeded": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode === "payment") await markPaid(s.id);
        break;
      }
      case "invoice.paid": {
        const inv = event.data.object as Stripe.Invoice & { subscription?: string; parent?: { subscription_details?: { subscription?: string } } };
        const subId = inv.subscription ?? inv.parent?.subscription_details?.subscription;
        if (subId) {
          const sub = await stripe.subscriptions.retrieve(subId);
          await applySubscription(sub, null, true);
        }
        break;
      }
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        await applySubscription(event.data.object as Stripe.Subscription, null, false);
        break;
      }
    }
  } catch (e) {
    // let Stripe retry: forget the event id
    await admin.from("bb_stripe_events").delete().eq("id", event.id);
    throw e;
  }
  return json({ received: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.headers.get("stripe-signature")) return await handleWebhook(req);
    if (req.method !== "POST") return json({ error: "POST only" }, 405);

    const body = await req.json().catch(() => ({}));
    const action = body.action as string;
    const u = await getUser(req);
    const base = baseUrl(body.return_base);

    switch (action) {
      case "connect_onboard": {
        let acct = u.priv.stripe_account_id as string | undefined;
        if (!acct) {
          const a = await stripe.accounts.create({
            type: "express",
            email: u.user.email,
            capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
            business_profile: { product_description: "Digital goods sold on BonkBrick" },
            metadata: { bb_user_id: u.user.id, bb_username: u.profile.username },
          });
          acct = a.id;
          await admin.from("bb_private").upsert({ id: u.user.id, stripe_account_id: acct });
        }
        const link = await stripe.accountLinks.create({
          account: acct,
          refresh_url: `${base}#/sell?connect=refresh`,
          return_url: `${base}#/sell?connect=done`,
          type: "account_onboarding",
        });
        return json({ url: link.url });
      }

      case "connect_status": {
        const acct = u.priv.stripe_account_id as string | undefined;
        if (!acct) return json({ connected: false });
        const a = await stripe.accounts.retrieve(acct);
        await admin.from("bb_profiles").update({ stripe_charges_enabled: !!a.charges_enabled }).eq("id", u.user.id);
        return json({ connected: true, charges_enabled: a.charges_enabled, payouts_enabled: a.payouts_enabled, details_submitted: a.details_submitted });
      }

      case "connect_dashboard": {
        const acct = u.priv.stripe_account_id as string | undefined;
        if (!acct) throw new Error("Connect Stripe first");
        const l = await stripe.accounts.createLoginLink(acct);
        return json({ url: l.url });
      }

      case "checkout_listing": {
        const { data: listing } = await admin.from("bb_mkt_listings").select("*").eq("id", body.listing_id).single();
        if (!listing || listing.status !== "approved") throw new Error("This listing is not available");
        if (listing.seller_id === u.user.id) throw new Error("You cannot buy your own listing");
        const { data: seller } = await admin.from("bb_profiles").select("banned").eq("id", listing.seller_id).single();
        const { data: sp } = await admin.from("bb_private").select("stripe_account_id").eq("id", listing.seller_id).single();
        if (!sp?.stripe_account_id || seller?.banned) throw new Error("This seller cannot accept payments yet");
        const acct = await stripe.accounts.retrieve(sp.stripe_account_id);
        if (!acct.charges_enabled) throw new Error("This seller has not finished Stripe setup");
        const fee = Math.round(listing.price_cents * FEE_PERCENT / 100);
        const session = await stripe.checkout.sessions.create({
          mode: "payment",
          customer_email: u.user.email,
          client_reference_id: u.user.id,
          line_items: [{
            quantity: 1,
            price_data: {
              currency: "usd",
              unit_amount: listing.price_cents,
              product_data: {
                name: listing.title,
                description: (listing.description || "BonkBrick marketplace item").slice(0, 300),
                images: listing.image_url ? [listing.image_url] : [],
              },
            },
          }],
          payment_intent_data: { application_fee_amount: fee, transfer_data: { destination: sp.stripe_account_id } },
          metadata: { kind: "listing", listing_id: listing.id, buyer_id: u.user.id },
          success_url: `${base}#/market/${listing.id}?paid=1`,
          cancel_url: `${base}#/market/${listing.id}`,
        });
        const { error } = await admin.from("bb_mkt_orders").insert({
          listing_id: listing.id, buyer_id: u.user.id, seller_id: listing.seller_id,
          amount_cents: listing.price_cents, fee_cents: fee, stripe_session_id: session.id,
        });
        if (error) throw new Error(error.message);
        return json({ url: session.url });
      }

      case "checkout_plus": {
        const price = Deno.env.get("STRIPE_PLUS_PRICE_ID");
        if (!price) throw new Error("Plus is not configured yet");
        const customer = await ensureCustomer(u);
        const session = await stripe.checkout.sessions.create({
          mode: "subscription",
          customer,
          client_reference_id: u.user.id,
          line_items: [{ price, quantity: 1 }],
          subscription_data: { metadata: { bb_user_id: u.user.id } },
          metadata: { kind: "plus", user_id: u.user.id },
          success_url: `${base}#/plus?welcome=1`,
          cancel_url: `${base}#/plus`,
        });
        return json({ url: session.url });
      }

      case "portal": {
        const customer = await ensureCustomer(u);
        const p = await stripe.billingPortal.sessions.create({ customer, return_url: `${base}#/plus` });
        return json({ url: p.url });
      }

      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    return json({ error: (e as Error).message ?? "Something went wrong" }, 400);
  }
});
