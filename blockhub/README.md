# Blockhub

A blocky browser game platform in one file: `index.html`. 11 built-in games, a game creator, accounts, friends, DMs, a forum, Bux currency, an item shop, Plus subscriptions and a real-money marketplace.

## Files

| File | What it does |
| --- | --- |
| `index.html` | The whole app. Drag it into Netlify Drop. |
| `supabase/schema.sql` | Every table, RLS policy, grant and function. Run once. |
| `supabase/functions/stripe-api` | Creates Stripe Checkout, billing portal and Connect onboarding links. |
| `supabase/functions/stripe-webhook` | Receives Stripe events and calls the `svc_` database functions. |
| `../.github/workflows/supabase-keepalive.yml` | Pings the database every 3 days so the free tier never pauses. |

The games run without any backend. Everything else needs Supabase.

## Sharing a project with other apps

Every Blockhub table, view, function, index and trigger starts with `bh_`. The schema only changes permissions on `bh_` objects, and the signup trigger catches its own errors, so it can live in a Supabase project that already runs other apps.

## Setup

### 1. Supabase

1. Create a project at supabase.com.
2. Open SQL Editor, paste all of `supabase/schema.sql`, and run it.
3. Sign up in the app, then make yourself admin in the SQL Editor:
   ```sql
   update public.bh_profiles set is_admin = true where username = 'YourName';
   ```
4. Under Authentication > URL Configuration, set Site URL to your Netlify URL and add it to Redirect URLs.

### 2. The HTML file

Open `index.html` and fill in the `CONFIG` block near the top of the script with your Project URL and anon key (Project Settings > API). The anon key is public by design. RLS protects the data.

On your phone you can skip this step: open the app, go to More, and paste the keys on the setup screen. They stay on that device only.

Then drag the `blockhub` folder (or just `index.html`) into https://app.netlify.com/drop.

### 3. Stripe (Plus, Bux packs, marketplace)

Stripe needs a secret key, so it runs in Supabase Edge Functions, not in the HTML.

1. In Stripe, create a Product called "Blockhub Plus" with a monthly recurring Price. Copy the price id (`price_...`).
2. Turn on Connect (Express accounts) in the Stripe dashboard.
3. Deploy the functions with the Supabase CLI:
   ```bash
   supabase link --project-ref YOUR_REF
   supabase secrets set STRIPE_SECRET_KEY=sk_test_... STRIPE_PLUS_PRICE_ID=price_... SITE_URL=https://your-site.netlify.app
   supabase functions deploy stripe-api
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
4. In Stripe > Developers > Webhooks, add an endpoint at
   `https://YOUR_REF.supabase.co/functions/v1/stripe-webhook` with these events:
   `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.expired`,
   `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `charge.refunded`.
   Copy its signing secret and run `supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...`.
5. Add a second endpoint for Connected accounts with the `account.updated` event, then
   `supabase secrets set STRIPE_CONNECT_WEBHOOK_SECRET=whsec_...`.
6. In Stripe > Settings > Billing > Customer portal, turn the portal on so Plus members can cancel.

Bux pack prices live in `stripe-api/index.ts` (`BUX_PACKS`). The marketplace fee is `MARKET_FEE` (10%).

### 4. Keepalive

Free Supabase projects pause after 7 days without API traffic. Two things stop that:

- The GitHub Action calls `bh_keepalive()` every 3 days. Add repo secrets `SUPABASE_URL` and `SUPABASE_ANON_KEY` under Settings > Secrets and variables > Actions.
- The app itself pings `bh_keepalive()` at most once per 12 hours per device.

## How the economy stays safe

- Clients cannot insert, update or delete wallets, the ledger, inventory, gift codes, orders or listings. Postgres grants are revoked and RLS has no write policies on those tables.
- Every Bux change runs through `bh_credit()`, which nobody can call directly. Public functions like `bh_submit_score`, `bh_buy_shop_item` and `bh_redeem_gift_code` are `security definer` and check the caller with `auth.uid()`.
- `bh_svc_` functions are callable only with the service role key, which only the edge functions hold.
- Play rewards need 15+ seconds of play, have a 30 second cooldown and a daily cap (300, or 600 with Plus).
- Gift code redemption locks you out for an hour after 10 failed tries.
- Referrers only earn once the invited player finishes 3 rewarded games, capped at 50 rewarded referrals.
- Listing delivery text sits in a separate table that only the seller can read. Buyers get it from `bh_get_order_delivery` after payment.

## Auth note

The `onAuthStateChange` callback never awaits database calls. It stores the user and defers the work with `setTimeout(..., 0)`, which avoids the known supabase-js deadlock. It also ignores repeat `SIGNED_IN` events for the same user, which supabase-js fires when a tab regains focus.
