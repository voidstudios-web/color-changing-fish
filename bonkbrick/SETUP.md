# BonkBrick setup checklist (phone friendly, no CLI)

You need 4 free accounts: **Supabase**, **Netlify** (or Vercel), **Stripe**, and **SellAuth**. Do the steps in order. Plan on 30 to 45 minutes.

Files in this folder:

| File | What it is | Where it goes |
|---|---|---|
| `index.html` | The whole app | Netlify or Vercel |
| `bonkbrick_migration.sql` | Database, security rules, RPC functions, seed data | Supabase SQL Editor |
| `supabase/functions/bb_stripe/index.ts` | Stripe Edge Function | Supabase Edge Functions editor |

---

## 1. Supabase database (10 min)

1. Open [supabase.com/dashboard](https://supabase.com/dashboard). Create a project, or open the one you already have. Everything is prefixed `bb_`, so it won't touch your other tables.
2. Go to **SQL Editor** → **New query**.
3. Open `bonkbrick_migration.sql` on GitHub, tap **Raw**, select all, copy, paste it into the editor, and tap **Run**. You should see "Success". You can safely run it again later.
4. Go to **Project Settings** → **API** (or **API Keys**). Copy the **Project URL** and the **anon / publishable** key. Never use the `service_role` or secret key in the HTML.
5. Go to **Authentication** → **URL Configuration**:
   - **Site URL**: your live site URL from step 3 (come back and fill this in after you deploy).
   - **Redirect URLs**: add the same URL.
6. Optional: under **Authentication** → **Providers** → **Email**, turn off **Confirm email** if you want people to log in right away. If it stays on, referral rewards only pay out after the email is confirmed (that's on purpose, it stops fake signups).

## 2. Edit the constants in index.html (3 min)

At the very top of the `<script>` in `index.html`, replace:

```js
const SUPABASE_URL = 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-SUPABASE-ANON-KEY';
const SELLAUTH_SHOP_URL = 'https://YOUR-SHOP.sellauth.com';
const STRIPE_PUBLISHABLE_KEY = 'pk_test_...';
const PLUS_PRICE_LABEL = '$4.99 / month';
const PLATFORM_FEE_PERCENT = 10;
```

On a phone, the easiest way is editing on GitHub: open `bonkbrick/index.html`, tap the pencil icon, change the lines, and commit.

Until you fill these in, the site runs in **guest mode**: all 11 games are playable, and a banner explains what's missing.

## 3. Deploy the site (5 min)

**Option A: Netlify from GitHub (best on a phone)**
1. [app.netlify.com](https://app.netlify.com) → **Add new site** → **Import an existing project** → **GitHub** → pick this repo.
2. Branch: the branch with BonkBrick. **Base directory**: `bonkbrick`. **Build command**: leave empty. **Publish directory**: `bonkbrick`.
3. Deploy. Every commit you make on GitHub now redeploys automatically.

**Option B: Netlify Drop**
1. Download `index.html`. On iPhone, long-press it in the Files app → **Compress** to make a zip. On Android, use your file manager's zip option.
2. Open [app.netlify.com/drop](https://app.netlify.com/drop) and upload the zip.

**Option C: Vercel**
[vercel.com/new](https://vercel.com/new) → import the GitHub repo → **Root Directory** `bonkbrick` → Framework **Other** → no build command → Deploy.

Then go back to **Supabase → Authentication → URL Configuration** and paste your live URL.

## 4. Make yourself admin (1 min)

1. Open your site and sign up.
2. In Supabase **SQL Editor**, run this with your username:

```sql
update public.bb_profiles set role = 'admin', verified = true where username = 'YOUR_USERNAME';
```

3. Reload the site. **Admin** now shows in the sidebar and in your avatar menu.

## 5. Stripe: marketplace payouts and Plus (15 min)

### 5a. In Stripe
1. [dashboard.stripe.com](https://dashboard.stripe.com). Stay in **Test mode** until everything works.
2. **Connect** → **Get started** → choose **Platform or marketplace**, and pick **Express** accounts for your sellers.
3. **Product catalog** → **Add product** → name it `BonkBrick Plus` → **Recurring**, monthly, e.g. $4.99 → save. Open the price and copy its **Price ID** (`price_...`).
4. **Settings** → **Billing** → **Customer portal** → **Activate** (this powers "Manage subscription").
5. **Developers** → **API keys**: copy the **Publishable key** (goes in `index.html`) and the **Secret key** (goes in Supabase only, step 5b).

### 5b. Create the Edge Function in Supabase (no CLI)
1. Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**.
2. Name it exactly **`bb_stripe`**. If the dashboard rejects the underscore, use `bb-stripe` and change `STRIPE_FUNCTION_NAME` at the top of `index.html` to match.
3. Delete the sample code, paste all of `supabase/functions/bb_stripe/index.ts`, and tap **Deploy function**.
4. Open the function → **Details** (or **Settings**) → turn **OFF** "Enforce JWT verification" / "Verify JWT", then save. Stripe's webhook has no Supabase login token. The function checks each user's login itself.
5. **Edge Functions** → **Secrets** → add:

| Name | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_test_...` |
| `STRIPE_PLUS_PRICE_ID` | `price_...` |
| `STRIPE_WEBHOOK_SECRET` | from step 5c |
| `PLATFORM_FEE_PERCENT` | `10` (match `index.html`) |
| `SITE_URL` | your live URL, e.g. `https://bonkbrick.netlify.app/` (optional, locks redirects to your site) |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically, so don't add them.

### 5c. Stripe webhook
1. Stripe → **Developers** → **Webhooks** → **Add endpoint**.
2. URL: `https://YOUR-PROJECT-REF.supabase.co/functions/v1/bb_stripe`
3. Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `invoice.paid`, `customer.subscription.updated`, `customer.subscription.deleted`.
4. Save, reveal the **Signing secret** (`whsec_...`), and add it as `STRIPE_WEBHOOK_SECRET` in Supabase.

### 5d. Test it
- **Plus**: open `/#/plus` → Subscribe → pay with card `4242 4242 4242 4242`, any future date, any CVC. Within seconds you get the Plus badge and 500 Bonks.
- **Marketplace**: log in as a second account → `/#/sell` → **Connect Stripe** → finish the test onboarding → create a listing → approve it as admin under **Admin → Listings** → buy it from your first account.

When it all works, switch Stripe to **Live mode**, redo 5a, 5b secrets and 5c with live keys, and put the live publishable key in `index.html`.

Optional fallback: if you'd rather use a Stripe **Payment Link** for Plus, paste it into `STRIPE_PLUS_PAYMENT_LINK`. The webhook links the payment to the user through `client_reference_id`.

## 6. Sell Bonks gift cards with SellAuth (5 min)

1. In BonkBrick, go to **Admin → Gift codes**. Enter Bonks per code (e.g. `1000`), how many (e.g. `50`), and a note, then tap **Generate**.
2. Tap **Copy all** or **Download .txt**. The codes are shown **once**. The database only stores a SHA-256 hash, so a leaked database can't reveal them.
3. In [SellAuth](https://sellauth.com): create a product like "1,000 Bonks", set the delivery type to **serials / deliverables**, and paste the codes as stock (one per line).
4. Put your shop URL in `SELLAUTH_SHOP_URL`. Buyers get a code by email and redeem it at **Get Bonks** (`/#/redeem`). Each code works once, and wrong guesses are rate-limited to 8 per hour.

## 7. Keep the free tier awake

Free Supabase projects pause after about a week with no activity.

- The migration already tries to schedule a **pg_cron** job (`bb_keepalive`, every 6 hours) that calls `bb_ping()`. Check under **Database → Cron Jobs** (or **Integrations → Cron**). If you see a notice that pg_cron isn't available, enable it under **Database → Extensions → pg_cron** and run the migration again.
- pg_cron runs inside the database and may not count as "activity". So also add a free outside ping:
  1. Sign up at [cron-job.org](https://cron-job.org) → **Create cronjob**.
  2. URL: `https://YOUR-PROJECT-REF.supabase.co/rest/v1/rpc/bb_ping`
  3. Schedule: every 12 hours.
  4. **Advanced**: method **POST**, body `{}`, headers:
     - `apikey: YOUR_ANON_KEY`
     - `Authorization: Bearer YOUR_ANON_KEY`
     - `Content-Type: application/json`
  5. Save. A `200` response with a timestamp means it works.

The site also pings once on every visit.

## 8. Final check

- [ ] Sign up works, you get 100 welcome Bonks and the daily reward popup.
- [ ] Play a game for 30+ seconds, exit, and see "+N Bonks".
- [ ] Buy a hat in the Shop and equip it under **Avatar**.
- [ ] Create a level under **Create**, test it, then publish it.
- [ ] Send a DM between two accounts. It shows up live.
- [ ] Post in the Forum, pin or lock it as admin.
- [ ] Generate a gift code and redeem it.
- [ ] Referral: open `yoursite/?ref=YOUR_USERNAME` in a private tab, sign up, play 60+ seconds. Both accounts get 100 Bonks.

## How the economy stays safe

- The browser **only reads** tables. Every write goes through a `SECURITY DEFINER` Postgres function with checks inside it.
- Game Bonks are based on **server-measured time** (1 per 20 seconds, max 35 per session), with one live session per user and a daily cap of 250 (500 with Plus). Community games pay half, and your own games pay nothing.
- Referral rewards pay once, need a confirmed email and a 60-second first game, and each referrer is capped at 10 rewards a day.
- The Stripe secret key lives only in Supabase secrets. Webhooks are signature-checked and deduped by event id.
- Auth follows the safe pattern: `onAuthStateChange` only stores state, and all database work runs in a separate `setTimeout(0)` tick, which avoids the supabase-js auth deadlock.
