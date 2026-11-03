-- =====================================================================
-- BLOCKHUB  -  full Supabase schema
-- Paste this whole file into Supabase Dashboard > SQL Editor > Run.
-- It is written to run once on a fresh project.
--
-- Rules this schema follows:
--   * Every Bux / economy change goes through a SECURITY DEFINER function.
--     Clients have NO insert/update/delete rights on wallets, ledger,
--     inventory, gift codes, orders or listings.
--   * Functions prefixed svc_ can only be called with the service role key
--     (used by the Stripe edge functions).
--   * Functions prefixed _ are internal helpers nobody can call directly.
--
-- After running, make yourself admin:
--   update public.profiles set is_admin = true where username = 'YourName';
-- =====================================================================

-- ---------------------------------------------------------------------
-- PROFILES
-- ---------------------------------------------------------------------
create table public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  username        text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  display_name    text check (char_length(display_name) <= 40),
  bio             text check (char_length(bio) <= 300),
  avatar          jsonb not null default '{"head":"#ffd23f","torso":"#2d7ff9","legs":"#2b2d42"}'::jsonb
                  check (jsonb_typeof(avatar) = 'object' and pg_column_size(avatar) < 1000),
  equipped        jsonb not null default '{}'::jsonb,
  verified        boolean not null default false,
  is_admin        boolean not null default false,
  plus_until      timestamptz,
  referral_code   text not null unique,
  last_stipend_at timestamptz,
  created_at      timestamptz not null default now()
);
create unique index profiles_username_lower_idx on public.profiles (lower(username));

-- Private per-user data (Stripe ids). Only the owner can read it, nobody can write it.
create table public.profile_private (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  stripe_customer_id text unique,
  stripe_account_id  text unique,
  charges_enabled    boolean not null default false,
  payouts_enabled    boolean not null default false
);

-- ---------------------------------------------------------------------
-- WALLET + LEDGER
-- ---------------------------------------------------------------------
create table public.wallets (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  bux        bigint not null default 0 check (bux >= 0),
  updated_at timestamptz not null default now()
);

create table public.bux_ledger (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  delta      bigint not null,
  reason     text not null,
  ref        text,
  created_at timestamptz not null default now()
);
create index bux_ledger_user_idx on public.bux_ledger (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- GAMES + PLAYS
-- ---------------------------------------------------------------------
create table public.games (
  id        text primary key,
  name      text not null,
  divisor   int  not null check (divisor > 0),
  max_score int  not null default 1000000
);
insert into public.games (id, name, divisor) values
  ('obby',    'Obby Runner',  100),
  ('bricks',  'Brick Smash',  30),
  ('snake',   'Snake Blocks', 10),
  ('hopper',  'Sky Hopper',   1),
  ('stack',   'Tower Stack',  1),
  ('memory',  'Memory Match', 50),
  ('blaster', 'Space Blaster',20),
  ('bonk',    'Bonk a Block', 15),
  ('dodge',   'Color Dodge',  30),
  ('duel',    'Paddle Duel',  40),
  ('miner',   'Gem Miner',    100),
  ('community','Community Games',100);

create table public.game_plays (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  game_id    text not null references public.games(id),
  ref_id     uuid,
  score      int  not null,
  reward     int  not null default 0,
  created_at timestamptz not null default now()
);
create index game_plays_user_idx on public.game_plays (user_id, created_at desc);
create index game_plays_game_idx on public.game_plays (game_id, score desc);

-- ---------------------------------------------------------------------
-- COMMUNITY GAMES (made in the in-app creator)
-- ---------------------------------------------------------------------
create table public.community_games (
  id          uuid primary key default gen_random_uuid(),
  creator     uuid not null references public.profiles(id) on delete cascade,
  title       text not null check (char_length(title) between 3 and 40),
  description text check (char_length(description) <= 300),
  level       jsonb not null check (pg_column_size(level) < 20000),
  theme       jsonb not null default '{}'::jsonb check (pg_column_size(theme) < 1000),
  plays       int  not null default 0,
  published   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index community_games_plays_idx on public.community_games (plays desc);

create table public.community_plays (
  game_id uuid not null references public.community_games(id) on delete cascade,
  player  uuid not null references public.profiles(id) on delete cascade,
  at      timestamptz not null default now()
);
create index community_plays_idx on public.community_plays (game_id, player, at desc);

-- ---------------------------------------------------------------------
-- SOCIAL
-- ---------------------------------------------------------------------
create table public.friendships (
  requester  uuid not null references public.profiles(id) on delete cascade,
  addressee  uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);
create index friendships_addressee_idx on public.friendships (addressee);

create table public.follows (
  follower   uuid not null references public.profiles(id) on delete cascade,
  followee   uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
create index follows_followee_idx on public.follows (followee);

create table public.messages (
  id         bigint generated always as identity primary key,
  sender     uuid not null references public.profiles(id) on delete cascade,
  recipient  uuid not null references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index messages_pair_idx on public.messages (sender, recipient, created_at desc);
create index messages_recipient_idx on public.messages (recipient, created_at desc);

-- ---------------------------------------------------------------------
-- FORUM
-- ---------------------------------------------------------------------
create table public.forum_posts (
  id            bigint generated always as identity primary key,
  author        uuid not null references public.profiles(id) on delete cascade,
  category      text not null default 'general' check (category in ('general','updates','showcase','help')),
  title         text not null check (char_length(title) between 3 and 120),
  body          text not null check (char_length(body) between 1 and 5000),
  pinned        boolean not null default false,
  reply_count   int not null default 0,
  last_activity timestamptz not null default now(),
  created_at    timestamptz not null default now()
);
create index forum_posts_list_idx on public.forum_posts (pinned desc, last_activity desc);

create table public.forum_replies (
  id         bigint generated always as identity primary key,
  post_id    bigint not null references public.forum_posts(id) on delete cascade,
  author     uuid not null references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 3000),
  created_at timestamptz not null default now()
);
create index forum_replies_post_idx on public.forum_replies (post_id, created_at);

-- ---------------------------------------------------------------------
-- SHOP + INVENTORY
-- ---------------------------------------------------------------------
create table public.shop_items (
  id        text primary key,
  name      text not null,
  kind      text not null check (kind in ('hat','face','shirt')),
  price     int  not null check (price >= 0),
  plus_only boolean not null default false,
  data      jsonb not null default '{}'::jsonb,
  active    boolean not null default true
);
insert into public.shop_items (id, name, kind, price, plus_only, data) values
  ('cap_red',     'Red Cap',        'hat',   60,  false, '{"shape":"cap","color":"#ff4d4d"}'),
  ('cap_blue',    'Blue Cap',       'hat',   60,  false, '{"shape":"cap","color":"#2d7ff9"}'),
  ('tophat',      'Top Hat',        'hat',   150, false, '{"shape":"tophat","color":"#2b2d42"}'),
  ('crown',       'Gold Crown',     'hat',   600, false, '{"shape":"crown","color":"#ffc300"}'),
  ('horns',       'Block Horns',    'hat',   250, false, '{"shape":"horns","color":"#b5179e"}'),
  ('halo',        'Plus Halo',      'hat',   300, true,  '{"shape":"halo","color":"#ffe066"}'),
  ('face_cool',   'Cool Shades',    'face',  120, false, '{"style":"cool"}'),
  ('face_wink',   'Wink',           'face',  40,  false, '{"style":"wink"}'),
  ('face_grin',   'Big Grin',       'face',  40,  false, '{"style":"grin"}'),
  ('face_robot',  'Robot Visor',    'face',  220, false, '{"style":"robot"}'),
  ('shirt_stripe','Stripe Tee',     'shirt', 80,  false, '{"pattern":"stripe","color":"#ffffff"}'),
  ('shirt_star',  'Star Tee',       'shirt', 140, false, '{"pattern":"star","color":"#ffd23f"}'),
  ('shirt_plus',  'Plus Hoodie',    'shirt', 200, true,  '{"pattern":"plus","color":"#7b2ff7"}');

create table public.inventory (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  item_id     text not null references public.shop_items(id),
  source      text not null default 'shop',
  acquired_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

-- ---------------------------------------------------------------------
-- GIFT CODES
-- ---------------------------------------------------------------------
create table public.gift_codes (
  code           text primary key,
  bux            int  not null check (bux between 1 and 100000),
  created_by     uuid references public.profiles(id) on delete set null,
  purchased_by   uuid references public.profiles(id) on delete set null,
  stripe_session text unique,
  redeemed_by    uuid references public.profiles(id) on delete set null,
  redeemed_at    timestamptz,
  created_at     timestamptz not null default now()
);

create table public.redeem_attempts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  success boolean not null,
  at      timestamptz not null default now()
);
create index redeem_attempts_idx on public.redeem_attempts (user_id, at desc);

-- ---------------------------------------------------------------------
-- REFERRALS
-- ---------------------------------------------------------------------
create table public.referrals (
  referee    uuid primary key references public.profiles(id) on delete cascade,
  referrer   uuid not null references public.profiles(id) on delete cascade,
  rewarded   boolean not null default false,
  created_at timestamptz not null default now()
);
create index referrals_referrer_idx on public.referrals (referrer);

-- ---------------------------------------------------------------------
-- REAL-MONEY MARKETPLACE
-- ---------------------------------------------------------------------
create table public.market_listings (
  id            uuid primary key default gen_random_uuid(),
  seller        uuid not null references public.profiles(id) on delete cascade,
  title         text not null check (char_length(title) between 3 and 60),
  description   text not null check (char_length(description) <= 1000),
  price_cents   int  not null check (price_cents between 100 and 50000),
  image_url     text check (image_url is null or image_url ~ '^https://'),
  stock         int  not null default 1 check (stock >= 0),
  status        text not null default 'pending'
                check (status in ('pending','approved','rejected','sold_out','removed')),
  reject_reason text,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index market_listings_status_idx on public.market_listings (status, created_at desc);

-- What the buyer receives (a code, link or instructions). Hidden until paid.
create table public.market_listing_secrets (
  listing_id uuid primary key references public.market_listings(id) on delete cascade,
  delivery   text not null check (char_length(delivery) between 1 and 2000)
);

create table public.market_orders (
  id                uuid primary key default gen_random_uuid(),
  listing_id        uuid not null references public.market_listings(id) on delete cascade,
  buyer             uuid not null,
  seller            uuid not null,
  amount_cents      int  not null,
  fee_cents         int  not null,
  status            text not null default 'pending' check (status in ('pending','paid','refunded','expired')),
  stripe_session_id text unique,
  payment_intent    text,
  created_at        timestamptz not null default now(),
  paid_at           timestamptz,
  constraint market_orders_buyer_fkey  foreign key (buyer)  references public.profiles(id) on delete cascade,
  constraint market_orders_seller_fkey foreign key (seller) references public.profiles(id) on delete cascade
);
create index market_orders_buyer_idx on public.market_orders (buyer, created_at desc);
create index market_orders_seller_idx on public.market_orders (seller, created_at desc);

create table public.seller_reviews (
  order_id   uuid primary key references public.market_orders(id) on delete cascade,
  seller     uuid not null references public.profiles(id) on delete cascade,
  reviewer   uuid not null,
  rating     int  not null check (rating between 1 and 5),
  body       text check (char_length(body) <= 500),
  created_at timestamptz not null default now(),
  constraint seller_reviews_reviewer_fkey foreign key (reviewer) references public.profiles(id) on delete cascade
);
create index seller_reviews_seller_idx on public.seller_reviews (seller, created_at desc);

create view public.seller_ratings with (security_invoker = true) as
  select seller, round(avg(rating)::numeric, 2) as avg_rating, count(*)::int as reviews
  from public.seller_reviews group by seller;

-- ---------------------------------------------------------------------
-- KEEPALIVE (stops the free tier from pausing)
-- ---------------------------------------------------------------------
create table public.keepalive (
  id        int primary key default 1 check (id = 1),
  pinged_at timestamptz not null default now(),
  pings     bigint not null default 0
);
insert into public.keepalive (id) values (1);

-- =====================================================================
-- HELPERS
-- =====================================================================
create or replace function public.is_admin(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = p), false)
$$;

create or replace function public.is_plus(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select plus_until > now() from profiles where id = p), false)
$$;

create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  )
$$;

-- The ONLY place Bux balances change.
create or replace function public._credit(p_user uuid, p_delta bigint, p_reason text, p_ref text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  update wallets set bux = bux + p_delta, updated_at = now()
   where user_id = p_user and bux + p_delta >= 0
  returning bux into v;
  if not found then
    if exists (select 1 from wallets where user_id = p_user) then
      raise exception 'Not enough Bux';
    end if;
    raise exception 'Wallet not found';
  end if;
  insert into bux_ledger (user_id, delta, reason, ref) values (p_user, p_delta, p_reason, p_ref);
  return v;
end $$;

create or replace function public._require_user() returns uuid
language plpgsql stable as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  return auth.uid();
end $$;

-- =====================================================================
-- NEW USER SIGNUP
-- =====================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare base text; uname text; code text;
begin
  base := regexp_replace(coalesce(new.raw_user_meta_data->>'username', ''), '[^A-Za-z0-9_]', '', 'g');
  if char_length(base) < 3 then base := 'Player'; end if;
  base := left(base, 20);
  uname := base;
  while exists (select 1 from profiles where lower(username) = lower(uname)) loop
    uname := left(base, 15) || floor(random() * 100000)::int;
  end loop;
  loop
    code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from profiles where referral_code = code);
  end loop;
  insert into profiles (id, username, referral_code) values (new.id, uname, code);
  insert into profile_private (user_id) values (new.id);
  insert into wallets (user_id, bux) values (new.id, 0);
  perform _credit(new.id, 50, 'welcome bonus');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- PLAY REWARDS
-- =====================================================================
create or replace function public.submit_score(p_game text, p_score int, p_duration int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := _require_user();
  g games;
  v_reward int := 0;
  cap int;
  today_total int;
  last_at timestamptz;
  rewarded_plays int;
  r referrals;
begin
  select * into g from games where id = p_game and id <> 'community';
  if not found then raise exception 'Unknown game'; end if;
  if p_score < 0 or p_score > g.max_score then raise exception 'Invalid score'; end if;

  select max(created_at) into last_at from game_plays where user_id = uid and reward > 0;

  if coalesce(p_duration, 0) >= 15 and (last_at is null or last_at < now() - interval '30 seconds') then
    v_reward := least(25, 2 + p_score / g.divisor);
    if is_plus(uid) then v_reward := v_reward * 2; cap := 600; else cap := 300; end if;
    select coalesce(sum(gp.reward), 0) into today_total
      from game_plays gp where gp.user_id = uid and gp.created_at > date_trunc('day', now());
    v_reward := greatest(0, least(v_reward, cap - today_total));
  end if;

  insert into game_plays (user_id, game_id, score, reward) values (uid, p_game, p_score, v_reward);
  if v_reward > 0 then perform _credit(uid, v_reward, 'play', p_game); end if;

  -- Referral payout: referrer earns once the new player has 3 rewarded plays.
  select * into r from referrals where referee = uid and not rewarded;
  if found then
    select count(*) into rewarded_plays from game_plays where user_id = uid and reward > 0;
    if rewarded_plays >= 3 then
      update referrals set rewarded = true where referee = uid;
      if (select count(*) from referrals where referrer = r.referrer and rewarded) <= 50 then
        perform _credit(r.referrer, 200, 'referral reward', uid::text);
      end if;
    end if;
  end if;

  return jsonb_build_object('reward', v_reward, 'balance', (select bux from wallets where user_id = uid));
end $$;

create or replace function public.leaderboard(p_game text)
returns table (username text, verified boolean, best int)
language sql stable security definer set search_path = public as $$
  select p.username, p.verified, max(gp.score)::int as best
  from game_plays gp join profiles p on p.id = gp.user_id
  where gp.game_id = p_game
  group by p.username, p.verified
  order by best desc
  limit 10
$$;

-- Community game finished. Rewards the player (shared cap with built-in games)
-- and pays the creator 1 Bux per unique player per hour (max 100/day).
create or replace function public.submit_community_play(p_game uuid, p_score int, p_duration int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := _require_user();
  cg community_games;
  v_reward int := 0;
  cap int;
  today_total int;
  last_at timestamptz;
  creator_today int;
begin
  select * into cg from community_games where id = p_game and published;
  if not found then raise exception 'Game not found'; end if;
  if p_score < 0 or p_score > 100000 then raise exception 'Invalid score'; end if;

  if not exists (select 1 from community_plays where game_id = p_game and player = uid and at > now() - interval '1 hour') then
    insert into community_plays (game_id, player) values (p_game, uid);
    update community_games set plays = plays + 1 where id = p_game;
    if cg.creator <> uid then
      select coalesce(sum(delta), 0) into creator_today from bux_ledger
        where user_id = cg.creator and reason = 'creator play' and created_at > date_trunc('day', now());
      if creator_today < 100 then perform _credit(cg.creator, 1, 'creator play', p_game::text); end if;
    end if;
  end if;

  select max(created_at) into last_at from game_plays where user_id = uid and reward > 0;
  if cg.creator <> uid and coalesce(p_duration, 0) >= 15
     and (last_at is null or last_at < now() - interval '30 seconds') then
    v_reward := least(15, 2 + p_score / 100);
    if is_plus(uid) then v_reward := v_reward * 2; cap := 600; else cap := 300; end if;
    select coalesce(sum(gp.reward), 0) into today_total
      from game_plays gp where gp.user_id = uid and gp.created_at > date_trunc('day', now());
    v_reward := greatest(0, least(v_reward, cap - today_total));
  end if;

  insert into game_plays (user_id, game_id, ref_id, score, reward) values (uid, 'community', p_game, p_score, v_reward);
  if v_reward > 0 then perform _credit(uid, v_reward, 'play', 'community'); end if;
  return jsonb_build_object('reward', v_reward, 'balance', (select bux from wallets where user_id = uid));
end $$;

-- =====================================================================
-- SHOP
-- =====================================================================
create or replace function public.buy_shop_item(p_item text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); it shop_items; v bigint;
begin
  select * into it from shop_items where id = p_item and active;
  if not found then raise exception 'Item not found'; end if;
  if it.plus_only and not is_plus(uid) then raise exception 'Plus members only'; end if;
  if exists (select 1 from inventory where user_id = uid and item_id = p_item) then
    raise exception 'You already own this';
  end if;
  v := _credit(uid, -it.price, 'shop', p_item);
  insert into inventory (user_id, item_id, source) values (uid, p_item, 'shop');
  return v;
end $$;

create or replace function public.equip_item(p_item text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); k text; e jsonb;
begin
  select s.kind into k from inventory i join shop_items s on s.id = i.item_id
   where i.user_id = uid and i.item_id = p_item;
  if k is null then raise exception 'You do not own this item'; end if;
  update profiles set equipped = equipped || jsonb_build_object(k, p_item) where id = uid returning equipped into e;
  return e;
end $$;

create or replace function public.unequip_item(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); e jsonb;
begin
  update profiles set equipped = equipped - p_kind where id = uid returning equipped into e;
  return e;
end $$;

-- =====================================================================
-- GIFT CODES
-- =====================================================================
create or replace function public._new_gift_code() returns text
language plpgsql as $$
declare raw text;
begin
  raw := upper(replace(gen_random_uuid()::text, '-', ''));
  return 'BUX-' || substr(raw, 1, 4) || '-' || substr(raw, 5, 4) || '-' || substr(raw, 9, 4) || '-' || substr(raw, 13, 4);
end $$;

create or replace function public.redeem_gift_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); c gift_codes; fails int; v bigint;
begin
  select count(*) into fails from redeem_attempts where user_id = uid and not success and at > now() - interval '1 hour';
  if fails >= 10 then
    return jsonb_build_object('ok', false, 'error', 'Too many tries. Wait an hour.');
  end if;
  select * into c from gift_codes where code = upper(trim(p_code)) for update;
  if not found or c.redeemed_by is not null then
    insert into redeem_attempts (user_id, success) values (uid, false);
    return jsonb_build_object('ok', false, 'error', 'That code is invalid or already used.');
  end if;
  update gift_codes set redeemed_by = uid, redeemed_at = now() where code = c.code;
  insert into redeem_attempts (user_id, success) values (uid, true);
  v := _credit(uid, c.bux, 'gift code', c.code);
  return jsonb_build_object('ok', true, 'bux', c.bux, 'balance', v);
end $$;

create or replace function public.admin_create_gift_codes(p_count int, p_bux int)
returns setof text language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); i int; code text;
begin
  if not is_admin(uid) then raise exception 'Admins only'; end if;
  if p_count < 1 or p_count > 100 then raise exception 'Count must be 1-100'; end if;
  for i in 1..p_count loop
    code := _new_gift_code();
    insert into gift_codes (code, bux, created_by) values (code, p_bux, uid);
    return next code;
  end loop;
end $$;

-- =====================================================================
-- PLUS
-- =====================================================================
create or replace function public.claim_plus_stipend()
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); last_at timestamptz; v bigint;
begin
  if not is_plus(uid) then raise exception 'Plus members only'; end if;
  select last_stipend_at into last_at from profiles where id = uid for update;
  if last_at is not null and last_at > now() - interval '30 days' then
    raise exception 'Next stipend unlocks on %', to_char(last_at + interval '30 days', 'Mon DD');
  end if;
  update profiles set last_stipend_at = now() where id = uid;
  v := _credit(uid, 500, 'plus stipend');
  return v;
end $$;

-- =====================================================================
-- REFERRALS
-- =====================================================================
create or replace function public.apply_referral(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); ref_id uuid; joined timestamptz; v bigint;
begin
  if exists (select 1 from referrals where referee = uid) then raise exception 'You already used an invite code'; end if;
  select created_at into joined from profiles where id = uid;
  if joined < now() - interval '7 days' then raise exception 'Invite codes only work in your first 7 days'; end if;
  select id into ref_id from profiles where referral_code = upper(trim(p_code));
  if ref_id is null then raise exception 'Invite code not found'; end if;
  if ref_id = uid then raise exception 'You cannot use your own code'; end if;
  if exists (select 1 from referrals where referee = ref_id and referrer = uid) then
    raise exception 'You cannot refer each other';
  end if;
  insert into referrals (referee, referrer) values (uid, ref_id);
  v := _credit(uid, 100, 'invite bonus', ref_id::text);
  return jsonb_build_object('bonus', 100, 'balance', v);
end $$;

create or replace function public.my_referral_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'invited',  (select count(*) from referrals where referrer = auth.uid()),
    'rewarded', (select count(*) from referrals where referrer = auth.uid() and rewarded),
    'used_code',(select exists (select 1 from referrals where referee = auth.uid()))
  )
$$;

-- =====================================================================
-- SOCIAL FUNCTIONS
-- =====================================================================
create or replace function public.send_friend_request(p_target uuid)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user();
begin
  if p_target = uid then raise exception 'That is you'; end if;
  if not exists (select 1 from profiles where id = p_target) then raise exception 'User not found'; end if;
  if are_friends(uid, p_target) then return 'friends'; end if;
  if exists (select 1 from friendships where requester = p_target and addressee = uid) then
    update friendships set status = 'accepted' where requester = p_target and addressee = uid;
    return 'friends';
  end if;
  insert into friendships (requester, addressee) values (uid, p_target) on conflict do nothing;
  return 'pending';
end $$;

create or replace function public.respond_friend_request(p_from uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user();
begin
  if p_accept then
    update friendships set status = 'accepted' where requester = p_from and addressee = uid and status = 'pending';
    return 'friends';
  end if;
  delete from friendships where requester = p_from and addressee = uid and status = 'pending';
  return 'declined';
end $$;

create or replace function public.remove_friend(p_other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user();
begin
  delete from friendships where (requester = uid and addressee = p_other) or (requester = p_other and addressee = uid);
end $$;

-- =====================================================================
-- MARKETPLACE FUNCTIONS
-- =====================================================================
create or replace function public.create_listing(
  p_title text, p_description text, p_price_cents int, p_image_url text, p_stock int, p_delivery text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); lid uuid;
begin
  if not coalesce((select charges_enabled from profile_private where user_id = uid), false) then
    raise exception 'Finish Stripe seller setup first';
  end if;
  if (select count(*) from market_listings where seller = uid and status = 'pending') >= 5 then
    raise exception 'You have 5 listings waiting for review already';
  end if;
  insert into market_listings (seller, title, description, price_cents, image_url, stock)
  values (uid, trim(p_title), trim(p_description), p_price_cents, nullif(trim(p_image_url), ''), greatest(1, least(p_stock, 999)))
  returning id into lid;
  insert into market_listing_secrets (listing_id, delivery) values (lid, trim(p_delivery));
  return lid;
end $$;

create or replace function public.remove_listing(p_listing uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user();
begin
  update market_listings set status = 'removed'
   where id = p_listing and (seller = uid or is_admin(uid));
  if not found then raise exception 'Listing not found'; end if;
end $$;

create or replace function public.admin_review_listing(p_listing uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user();
begin
  if not is_admin(uid) then raise exception 'Admins only'; end if;
  update market_listings
     set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then null else p_reason end,
         reviewed_at = now()
   where id = p_listing and status = 'pending';
  if not found then raise exception 'Listing is not pending'; end if;
end $$;

create or replace function public.get_order_delivery(p_order uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare uid uuid := _require_user(); d text;
begin
  select s.delivery into d
    from market_orders o join market_listing_secrets s on s.listing_id = o.listing_id
   where o.id = p_order and o.buyer = uid and o.status = 'paid';
  if d is null then raise exception 'Order not found or not paid'; end if;
  return d;
end $$;

create or replace function public.submit_seller_review(p_order uuid, p_rating int, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); o market_orders;
begin
  select * into o from market_orders where id = p_order and buyer = uid and status = 'paid';
  if not found then raise exception 'You can only review paid orders'; end if;
  insert into seller_reviews (order_id, seller, reviewer, rating, body)
  values (p_order, o.seller, uid, p_rating, nullif(trim(p_body), ''));
exception when unique_violation then
  raise exception 'You already reviewed this order';
end $$;

-- =====================================================================
-- ADMIN
-- =====================================================================
create or replace function public.admin_set_verified(p_username text, p_value boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user();
begin
  if not is_admin(uid) then raise exception 'Admins only'; end if;
  update profiles set verified = p_value where lower(username) = lower(p_username);
  if not found then raise exception 'User not found'; end if;
end $$;

create or replace function public.admin_adjust_bux(p_username text, p_delta bigint, p_reason text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := _require_user(); target uuid;
begin
  if not is_admin(uid) then raise exception 'Admins only'; end if;
  select id into target from profiles where lower(username) = lower(p_username);
  if target is null then raise exception 'User not found'; end if;
  return _credit(target, p_delta, 'admin: ' || coalesce(p_reason, ''), uid::text);
end $$;

create or replace function public.admin_pin_post(p_post bigint, p_pinned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(_require_user()) then raise exception 'Admins only'; end if;
  update forum_posts set pinned = p_pinned where id = p_post;
end $$;

-- =====================================================================
-- SERVICE-ROLE FUNCTIONS (called by Stripe edge functions only)
-- =====================================================================
create or replace function public.svc_set_customer(p_user uuid, p_customer text)
returns void language sql security definer set search_path = public as $$
  update profile_private set stripe_customer_id = p_customer where user_id = p_user;
$$;

create or replace function public.svc_set_plus(p_user uuid, p_until timestamptz)
returns void language sql security definer set search_path = public as $$
  update profiles set plus_until = p_until where id = p_user;
$$;

create or replace function public.svc_set_plus_by_customer(p_customer text, p_until timestamptz)
returns void language sql security definer set search_path = public as $$
  update profiles set plus_until = p_until
   where id = (select user_id from profile_private where stripe_customer_id = p_customer);
$$;

create or replace function public.svc_issue_bux_code(p_user uuid, p_bux int, p_session text)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  select code into c from gift_codes where stripe_session = p_session;
  if c is not null then return c; end if;
  c := _new_gift_code();
  insert into gift_codes (code, bux, purchased_by, stripe_session) values (c, p_bux, p_user, p_session);
  return c;
end $$;

create or replace function public.svc_set_connect_account(p_user uuid, p_account text)
returns void language sql security definer set search_path = public as $$
  update profile_private set stripe_account_id = p_account where user_id = p_user;
$$;

create or replace function public.svc_update_connect_status(p_account text, p_charges boolean, p_payouts boolean)
returns void language sql security definer set search_path = public as $$
  update profile_private set charges_enabled = p_charges, payouts_enabled = p_payouts
   where stripe_account_id = p_account;
$$;

create or replace function public.svc_create_order(p_listing uuid, p_buyer uuid, p_fee_pct numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l market_listings; acct text; ok boolean; oid uuid; fee int;
begin
  select * into l from market_listings where id = p_listing for update;
  if not found or l.status <> 'approved' then raise exception 'Listing is not for sale'; end if;
  if l.stock < 1 then raise exception 'Sold out'; end if;
  if l.seller = p_buyer then raise exception 'You cannot buy your own listing'; end if;
  select stripe_account_id, charges_enabled into acct, ok from profile_private where user_id = l.seller;
  if acct is null or not ok then raise exception 'Seller cannot take payments right now'; end if;
  fee := round(l.price_cents * p_fee_pct)::int;
  insert into market_orders (listing_id, buyer, seller, amount_cents, fee_cents)
  values (l.id, p_buyer, l.seller, l.price_cents, fee) returning id into oid;
  return jsonb_build_object('order_id', oid, 'amount', l.price_cents, 'fee', fee,
                            'title', l.title, 'destination', acct, 'image', l.image_url);
end $$;

create or replace function public.svc_attach_session(p_order uuid, p_session text)
returns void language sql security definer set search_path = public as $$
  update market_orders set stripe_session_id = p_session where id = p_order;
$$;

create or replace function public.svc_mark_order_paid(p_session text, p_payment_intent text)
returns void language plpgsql security definer set search_path = public as $$
declare o market_orders;
begin
  update market_orders set status = 'paid', paid_at = now(), payment_intent = p_payment_intent
   where stripe_session_id = p_session and status in ('pending','expired')
  returning * into o;
  if not found then return; end if;  -- already handled
  update market_listings
     set stock = greatest(stock - 1, 0),
         status = case when stock - 1 <= 0 then 'sold_out' else status end
   where id = o.listing_id;
end $$;

create or replace function public.svc_expire_order(p_session text)
returns void language sql security definer set search_path = public as $$
  update market_orders set status = 'expired' where stripe_session_id = p_session and status = 'pending';
$$;

create or replace function public.svc_mark_order_refunded(p_payment_intent text)
returns void language sql security definer set search_path = public as $$
  update market_orders set status = 'refunded' where payment_intent = p_payment_intent and status = 'paid';
$$;

-- =====================================================================
-- KEEPALIVE
-- =====================================================================
create or replace function public.keepalive()
returns timestamptz language sql security definer set search_path = public as $$
  update keepalive set pinged_at = now(), pings = pings + 1 where id = 1 returning pinged_at;
$$;

-- =====================================================================
-- FORUM TRIGGERS (reply counts + basic spam limit)
-- =====================================================================
create or replace function public.forum_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'forum_posts' then
    if (select count(*) from forum_posts where author = new.author and created_at > now() - interval '10 minutes') >= 5 then
      raise exception 'Slow down. Max 5 posts per 10 minutes.';
    end if;
  else
    if (select count(*) from forum_replies where author = new.author and created_at > now() - interval '1 minute') >= 5 then
      raise exception 'Slow down. Max 5 replies per minute.';
    end if;
  end if;
  return new;
end $$;
create trigger forum_posts_rate before insert on public.forum_posts for each row execute function public.forum_rate_limit();
create trigger forum_replies_rate before insert on public.forum_replies for each row execute function public.forum_rate_limit();

create or replace function public.forum_reply_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update forum_posts set reply_count = reply_count + 1, last_activity = now() where id = new.post_id;
  else
    update forum_posts set reply_count = greatest(reply_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end $$;
create trigger forum_replies_count after insert or delete on public.forum_replies
  for each row execute function public.forum_reply_count();

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger community_games_touch before update on public.community_games
  for each row execute function public.touch_updated_at();

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles               enable row level security;
alter table public.profile_private        enable row level security;
alter table public.wallets                enable row level security;
alter table public.bux_ledger             enable row level security;
alter table public.games                  enable row level security;
alter table public.game_plays             enable row level security;
alter table public.community_games        enable row level security;
alter table public.community_plays        enable row level security;
alter table public.friendships            enable row level security;
alter table public.follows                enable row level security;
alter table public.messages               enable row level security;
alter table public.forum_posts            enable row level security;
alter table public.forum_replies          enable row level security;
alter table public.shop_items             enable row level security;
alter table public.inventory              enable row level security;
alter table public.gift_codes             enable row level security;
alter table public.redeem_attempts        enable row level security;
alter table public.referrals              enable row level security;
alter table public.market_listings        enable row level security;
alter table public.market_listing_secrets enable row level security;
alter table public.market_orders          enable row level security;
alter table public.seller_reviews         enable row level security;
alter table public.keepalive              enable row level security;

-- profiles: public read, owner edits a few columns
create policy "profiles readable" on public.profiles for select using (true);
create policy "profiles own update" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "private own read" on public.profile_private for select to authenticated using (user_id = auth.uid());
create policy "wallet own read"  on public.wallets         for select to authenticated using (user_id = auth.uid());
create policy "ledger own read"  on public.bux_ledger      for select to authenticated using (user_id = auth.uid());
create policy "games readable"   on public.games           for select using (true);
create policy "plays own read"   on public.game_plays      for select to authenticated using (user_id = auth.uid());

create policy "cg read" on public.community_games for select
  using (published or creator = auth.uid());
create policy "cg insert" on public.community_games for insert to authenticated
  with check (creator = auth.uid());
create policy "cg update" on public.community_games for update to authenticated
  using (creator = auth.uid()) with check (creator = auth.uid());
create policy "cg delete" on public.community_games for delete to authenticated
  using (creator = auth.uid() or public.is_admin(auth.uid()));

create policy "friendships own read" on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));

create policy "follows readable" on public.follows for select using (true);
create policy "follow self" on public.follows for insert to authenticated with check (follower = auth.uid());
create policy "unfollow self" on public.follows for delete to authenticated using (follower = auth.uid());

create policy "messages own read" on public.messages for select to authenticated
  using (auth.uid() in (sender, recipient));
create policy "messages send to friends" on public.messages for insert to authenticated
  with check (sender = auth.uid() and public.are_friends(sender, recipient));
create policy "messages mark read" on public.messages for update to authenticated
  using (recipient = auth.uid()) with check (recipient = auth.uid());

create policy "posts readable" on public.forum_posts for select using (true);
create policy "posts insert" on public.forum_posts for insert to authenticated with check (author = auth.uid());
create policy "posts update" on public.forum_posts for update to authenticated
  using (author = auth.uid()) with check (author = auth.uid());
create policy "posts delete" on public.forum_posts for delete to authenticated
  using (author = auth.uid() or public.is_admin(auth.uid()));

create policy "replies readable" on public.forum_replies for select using (true);
create policy "replies insert" on public.forum_replies for insert to authenticated with check (author = auth.uid());
create policy "replies delete" on public.forum_replies for delete to authenticated
  using (author = auth.uid() or public.is_admin(auth.uid()));

create policy "shop readable" on public.shop_items for select using (true);
create policy "inventory readable" on public.inventory for select using (true);

create policy "gift codes own" on public.gift_codes for select to authenticated
  using (purchased_by = auth.uid() or public.is_admin(auth.uid()));

create policy "referrals own" on public.referrals for select to authenticated
  using (auth.uid() in (referee, referrer));

create policy "listings read" on public.market_listings for select
  using (status = 'approved' or seller = auth.uid() or public.is_admin(auth.uid()));
create policy "listing secret seller" on public.market_listing_secrets for select to authenticated
  using (exists (select 1 from public.market_listings l where l.id = listing_id and l.seller = auth.uid()));
create policy "orders own" on public.market_orders for select to authenticated
  using (auth.uid() in (buyer, seller) or public.is_admin(auth.uid()));
create policy "reviews readable" on public.seller_reviews for select using (true);
-- redeem_attempts, keepalive, community_plays: no policies, functions only.

-- =====================================================================
-- COLUMN-LEVEL GRANTS
-- Supabase grants full table rights to anon/authenticated by default.
-- Lock down every write, then re-open only safe columns.
-- =====================================================================
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;

grant update (username, display_name, bio, avatar) on public.profiles to authenticated;
grant insert, delete on public.follows to authenticated;
grant insert (sender, recipient, body) on public.messages to authenticated;
grant update (read_at) on public.messages to authenticated;
grant insert (author, category, title, body) on public.forum_posts to authenticated;
grant update (title, body) on public.forum_posts to authenticated;
grant delete on public.forum_posts to authenticated;
grant insert (post_id, author, body) on public.forum_replies to authenticated;
grant delete on public.forum_replies to authenticated;
grant insert (creator, title, description, level, theme, published) on public.community_games to authenticated;
grant update (title, description, level, theme, published) on public.community_games to authenticated;
grant delete on public.community_games to authenticated;

-- =====================================================================
-- FUNCTION GRANTS
-- Supabase lets anon/authenticated execute every new function by default.
-- Revoke all, then grant exactly what the app needs.
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_admin(uuid), public.is_plus(uuid), public.are_friends(uuid, uuid)
  to anon, authenticated;
grant execute on function public.leaderboard(text) to anon, authenticated;
grant execute on function public.keepalive() to anon, authenticated;

grant execute on function
  public.submit_score(text, int, int),
  public.submit_community_play(uuid, int, int),
  public.buy_shop_item(text),
  public.equip_item(text),
  public.unequip_item(text),
  public.redeem_gift_code(text),
  public.admin_create_gift_codes(int, int),
  public.claim_plus_stipend(),
  public.apply_referral(text),
  public.my_referral_stats(),
  public.send_friend_request(uuid),
  public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid),
  public.create_listing(text, text, int, text, int, text),
  public.remove_listing(uuid),
  public.admin_review_listing(uuid, boolean, text),
  public.get_order_delivery(uuid),
  public.submit_seller_review(uuid, int, text),
  public.admin_set_verified(text, boolean),
  public.admin_adjust_bux(text, bigint, text),
  public.admin_pin_post(bigint, boolean)
to authenticated;

grant execute on function
  public.svc_set_customer(uuid, text),
  public.svc_set_plus(uuid, timestamptz),
  public.svc_set_plus_by_customer(text, timestamptz),
  public.svc_issue_bux_code(uuid, int, text),
  public.svc_set_connect_account(uuid, text),
  public.svc_update_connect_status(text, boolean, boolean),
  public.svc_create_order(uuid, uuid, numeric),
  public.svc_attach_session(uuid, text),
  public.svc_mark_order_paid(text, text),
  public.svc_expire_order(text),
  public.svc_mark_order_refunded(text)
to service_role;

-- Stop functions created later from being public by default.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- =====================================================================
-- REALTIME
-- =====================================================================
alter publication supabase_realtime add table public.messages, public.wallets, public.friendships;
