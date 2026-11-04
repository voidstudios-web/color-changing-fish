// Blockhub Stripe API (Supabase Edge Function)
// Deploy: supabase functions deploy stripe-api
// Secrets: STRIPE_SECRET_KEY, STRIPE_PLUS_PRICE_ID, SITE_URL
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  httpClient: Stripe.createFetchHttpClient(),
});
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
const PLUS_PRICE = Deno.env.get("STRIPE_PLUS_PRICE_ID")!;
const MARKET_FEE = 0.10; // platform keeps 10% of marketplace sales

// Bux packs are defined here, server side, so the client cannot change prices.
const BUX_PACKS: Record<string, { bux: number; cents: number; name: string }> = {
  small: { bux: 400, cents: 499, name: "400 Bux" },
  medium: { bux: 1000, cents: 999, name: "1,000 Bux" },
  large: { bux: 2200, cents: 1999, name: "2,200 Bux" },
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

async function getPrivate(userId: string) {
  const { data, error } = await admin.from("bh_profile_private").select("*").eq("user_id", userId).single();
  if (error) throw new Error(error.message);
  return data as { stripe_customer_id: string | null; stripe_account_id: string | null };
}

async function getCustomer(userId: string, email?: string) {
  const priv = await getPrivate(userId);
  if (priv.stripe_customer_id) return priv.stripe_customer_id;
  const c = await stripe.customers.create({ email, metadata: { user_id: userId } });
  await rpc("bh_svc_set_customer", { p_user: userId, p_customer: c.id });
  return c.id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(jwt);
    if (!user) return json({ error: "Sign in first" }, 401);
    const body = await req.json().catch(() => ({}));

    switch (body.action) {
      case "plus": {
        const customer = await getCustomer(user.id, user.email);
        const s = await stripe.checkout.sessions.create({
          mode: "subscription",
          customer,
          client_reference_id: user.id,
          line_items: [{ price: PLUS_PRICE, quantity: 1 }],
          metadata: { kind: "plus", user_id: user.id },
          subscription_data: { metadata: { user_id: user.id } },
          success_url: `${SITE}/?checkout=plus#/plus`,
          cancel_url: `${SITE}/#/plus`,
        });
        return json({ url: s.url });
      }

      case "portal": {
        const customer = await getCustomer(user.id, user.email);
        const p = await stripe.billingPortal.sessions.create({ customer, return_url: `${SITE}/#/plus` });
        return json({ url: p.url });
      }

      case "bux": {
        const pack = BUX_PACKS[body.pack];
        if (!pack) return json({ error: "Unknown pack" }, 400);
        const customer = await getCustomer(user.id, user.email);
        const s = await stripe.checkout.sessions.create({
          mode: "payment",
          customer,
          client_reference_id: user.id,
          line_items: [{
            quantity: 1,
            price_data: { currency: "usd", unit_amount: pack.cents, product_data: { name: `Blockhub ${pack.name} gift code` } },
          }],
          metadata: { kind: "bux", user_id: user.id, pack: body.pack, bux: String(pack.bux) },
          success_url: `${SITE}/?checkout=bux#/bux`,
          cancel_url: `${SITE}/#/bux`,
        });
        return json({ url: s.url });
      }

      case "market": {
        const order = await rpc<{ order_id: string; amount: number; fee: number; title: string; destination: string; image: string | null }>(
          "bh_svc_create_order", { p_listing: body.listing_id, p_buyer: user.id, p_fee_pct: MARKET_FEE },
        );
        const s = await stripe.checkout.sessions.create({
          mode: "payment",
          customer_email: user.email,
          client_reference_id: user.id,
          line_items: [{
            quantity: 1,
            price_data: {
              currency: "usd",
              unit_amount: order.amount,
              product_data: { name: order.title, ...(order.image ? { images: [order.image] } : {}) },
            },
          }],
          payment_intent_data: {
            application_fee_amount: order.fee,
            transfer_data: { destination: order.destination },
            metadata: { order_id: order.order_id },
          },
          metadata: { kind: "market", order_id: order.order_id },
          success_url: `${SITE}/?checkout=market#/orders`,
          cancel_url: `${SITE}/#/item/${body.listing_id}`,
        });
        await rpc("bh_svc_attach_session", { p_order: order.order_id, p_session: s.id });
        return json({ url: s.url });
      }

      case "connect": {
        const priv = await getPrivate(user.id);
        let account = priv.stripe_account_id;
        if (!account) {
          const a = await stripe.accounts.create({
            type: "express",
            email: user.email,
            metadata: { user_id: user.id },
            capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
          });
          account = a.id;
          await rpc("bh_svc_set_connect_account", { p_user: user.id, p_account: account });
        }
        const link = await stripe.accountLinks.create({
          account,
          type: "account_onboarding",
          refresh_url: `${SITE}/#/sell`,
          return_url: `${SITE}/?connect=done#/sell`,
        });
        return json({ url: link.url });
      }

      case "connect_refresh": {
        const priv = await getPrivate(user.id);
        if (!priv.stripe_account_id) return json({ charges_enabled: false, payouts_enabled: false });
        const a = await stripe.accounts.retrieve(priv.stripe_account_id);
        await rpc("bh_svc_update_connect_status", {
          p_account: a.id, p_charges: !!a.charges_enabled, p_payouts: !!a.payouts_enabled,
        });
        return json({ charges_enabled: a.charges_enabled, payouts_enabled: a.payouts_enabled });
      }

      case "connect_dashboard": {
        const priv = await getPrivate(user.id);
        if (!priv.stripe_account_id) return json({ error: "No seller account yet" }, 400);
        const l = await stripe.accounts.createLoginLink(priv.stripe_account_id);
        return json({ url: l.url });
      }

      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    return json({ error: (e as Error).message }, 400);
  }
});
