// Blockhub Stripe webhook (Supabase Edge Function)
// Deploy: supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, and optionally
// STRIPE_CONNECT_WEBHOOK_SECRET if you add a separate "connected accounts" endpoint.
import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  httpClient: Stripe.createFetchHttpClient(),
});
const crypto = Stripe.createSubtleCryptoProvider();
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);
const secrets = [Deno.env.get("STRIPE_WEBHOOK_SECRET"), Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET")]
  .filter(Boolean) as string[];

async function rpc(fn: string, args: Record<string, unknown>) {
  const { error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
}

// Newer Stripe API versions moved current_period_end onto subscription items.
function periodEnd(sub: Stripe.Subscription): string {
  // deno-lint-ignore no-explicit-any
  const s = sub as any;
  const ts = s.items?.data?.[0]?.current_period_end ?? s.current_period_end;
  return new Date(ts * 1000).toISOString();
}

async function syncSubscription(sub: Stripe.Subscription) {
  const active = sub.status === "active" || sub.status === "trialing" || sub.status === "past_due";
  const until = active ? periodEnd(sub) : new Date().toISOString();
  const customer = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  await rpc("svc_set_plus_by_customer", { p_customer: customer, p_until: until });
}

async function verify(body: string, sig: string): Promise<Stripe.Event> {
  let last: unknown;
  for (const s of secrets) {
    try {
      return await stripe.webhooks.constructEventAsync(body, sig, s, undefined, crypto);
    } catch (e) { last = e; }
  }
  throw last ?? new Error("No webhook secret configured");
}

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Missing signature", { status: 400 });
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await verify(body, sig);
  } catch (e) {
    return new Response(`Bad signature: ${(e as Error).message}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const s = event.data.object as Stripe.Checkout.Session;
        const kind = s.metadata?.kind;
        if (kind === "plus" && s.subscription) {
          const sub = await stripe.subscriptions.retrieve(s.subscription as string);
          await rpc("svc_set_plus", { p_user: s.metadata!.user_id, p_until: periodEnd(sub) });
        } else if (kind === "bux" && s.payment_status === "paid") {
          await rpc("svc_issue_bux_code", {
            p_user: s.metadata!.user_id, p_bux: Number(s.metadata!.bux), p_session: s.id,
          });
        } else if (kind === "market" && s.payment_status === "paid") {
          await rpc("svc_mark_order_paid", { p_session: s.id, p_payment_intent: s.payment_intent as string });
        }
        break;
      }
      case "checkout.session.expired": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.metadata?.kind === "market") await rpc("svc_expire_order", { p_session: s.id });
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await syncSubscription(event.data.object as Stripe.Subscription);
        break;
      case "account.updated": {
        const a = event.data.object as Stripe.Account;
        await rpc("svc_update_connect_status", {
          p_account: a.id, p_charges: !!a.charges_enabled, p_payouts: !!a.payouts_enabled,
        });
        break;
      }
      case "charge.refunded": {
        const c = event.data.object as Stripe.Charge;
        if (c.payment_intent) {
          await rpc("svc_mark_order_refunded", {
            p_payment_intent: typeof c.payment_intent === "string" ? c.payment_intent : c.payment_intent.id,
          });
        }
        break;
      }
    }
  } catch (e) {
    // 500 makes Stripe retry later.
    return new Response(`Handler error: ${(e as Error).message}`, { status: 500 });
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
