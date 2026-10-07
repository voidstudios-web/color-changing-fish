-- =====================================================================
--  BonkBrick : complete Supabase migration
--  Paste this whole file into Supabase Dashboard -> SQL Editor -> Run.
--  Every object is prefixed with bb_ so it can live in a shared project.
--  Safe to re-run: tables use IF NOT EXISTS, functions use OR REPLACE,
--  policies are dropped and recreated, seeds use ON CONFLICT.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table if not exists public.bb_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  bio text not null default '' check (char_length(bio) <= 300),
  avatar jsonb not null default '{"skin":"#f5c08a","torso":"#3b82f6","legs":"#1e293b"}'::jsonb,
  bonks integer not null default 100 check (bonks >= 0),
  role text not null default 'user' check (role in ('user','admin')),
  verified boolean not null default false,
  plus_until timestamptz,
  banned boolean not null default false,
  referred_by uuid references public.bb_profiles(id) on delete set null,
  referral_rewarded boolean not null default false,
  last_daily date,
  daily_streak integer not null default 0,
  stripe_charges_enabled boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists bb_profiles_username_lower on public.bb_profiles (lower(username));
create index if not exists bb_profiles_referred_by on public.bb_profiles (referred_by);

-- private per-user data (never public)
create table if not exists public.bb_private (
  id uuid primary key references public.bb_profiles(id) on delete cascade,
  stripe_account_id text,
  stripe_customer_id text,
  stripe_subscription_id text
);
create index if not exists bb_private_customer on public.bb_private (stripe_customer_id);

create table if not exists public.bb_games (
  id uuid primary key default gen_random_uuid(),
  slug text unique,
  title text not null check (char_length(title) between 1 and 60),
  description text not null default '' check (char_length(description) <= 500),
  thumb jsonb not null default '{}'::jsonb,
  builtin boolean not null default false,
  creator_id uuid references public.bb_profiles(id) on delete cascade,
  level jsonb,
  published boolean not null default false,
  score_order text not null default 'desc' check (score_order in ('asc','desc')),
  score_label text not null default 'Score',
  min_score numeric not null default 0,
  max_score numeric not null default 1000000,
  plays integer not null default 0,
  likes integer not null default 0,
  dislikes integer not null default 0,
  favorites integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bb_games_level_size check (level is null or pg_column_size(level) < 250000)
);
create index if not exists bb_games_creator on public.bb_games (creator_id);
create index if not exists bb_games_pub_plays on public.bb_games (published, plays desc);

create table if not exists public.bb_game_votes (
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  game_id uuid not null references public.bb_games(id) on delete cascade,
  vote smallint not null check (vote in (-1, 1)),
  primary key (user_id, game_id)
);

create table if not exists public.bb_favorites (
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  game_id uuid not null references public.bb_games(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, game_id)
);

create table if not exists public.bb_play_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  game_id uuid not null references public.bb_games(id) on delete cascade,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  score numeric,
  earned integer not null default 0
);
create index if not exists bb_sessions_user on public.bb_play_sessions (user_id, started_at desc);

create table if not exists public.bb_scores (
  game_id uuid not null references public.bb_games(id) on delete cascade,
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  score numeric not null,
  updated_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
create index if not exists bb_scores_game_score on public.bb_scores (game_id, score);

create table if not exists public.bb_daily_earnings (
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  day date not null,
  amount integer not null default 0,
  primary key (user_id, day)
);

create table if not exists public.bb_ledger (
  id bigserial primary key,
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  amount integer not null,
  reason text not null,
  created_at timestamptz not null default now()
);
create index if not exists bb_ledger_user on public.bb_ledger (user_id, created_at desc);

create table if not exists public.bb_items (
  id uuid primary key default gen_random_uuid(),
  slug text unique,
  name text not null check (char_length(name) between 1 and 40),
  type text not null check (type in ('hat','face','shirt','pants','accessory','gear')),
  price integer not null check (price >= 0),
  stock integer check (stock is null or stock >= 0),
  sold integer not null default 0,
  limited boolean not null default false,
  plus_only boolean not null default false,
  style jsonb not null default '{}'::jsonb,
  description text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.bb_inventory (
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  item_id uuid not null references public.bb_items(id) on delete cascade,
  acquired_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

create table if not exists public.bb_gift_codes (
  id uuid primary key default gen_random_uuid(),
  code_hash text not null unique,
  code_hint text not null default '',
  amount integer not null check (amount > 0),
  note text not null default '',
  created_by uuid references public.bb_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  redeemed_by uuid references public.bb_profiles(id) on delete set null,
  redeemed_at timestamptz
);

create table if not exists public.bb_redeem_attempts (
  id bigserial primary key,
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  ok boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists bb_redeem_attempts_user on public.bb_redeem_attempts (user_id, created_at desc);

create table if not exists public.bb_mkt_listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.bb_profiles(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 80),
  description text not null default '' check (char_length(description) <= 3000),
  price_cents integer not null check (price_cents between 100 and 100000),
  image_url text,
  category text not null default 'Other',
  status text not null default 'pending' check (status in ('pending','approved','rejected','paused')),
  admin_note text not null default '',
  sales integer not null default 0,
  rating_avg numeric(3,2) not null default 0,
  rating_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  approved_at timestamptz
);
create index if not exists bb_mkt_listings_status on public.bb_mkt_listings (status, created_at desc);
create index if not exists bb_mkt_listings_seller on public.bb_mkt_listings (seller_id);

create table if not exists public.bb_mkt_listing_secrets (
  listing_id uuid primary key references public.bb_mkt_listings(id) on delete cascade,
  delivery text not null default '' check (char_length(delivery) <= 3000)
);

create table if not exists public.bb_mkt_orders (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.bb_mkt_listings(id) on delete cascade,
  buyer_id uuid not null references public.bb_profiles(id) on delete cascade,
  seller_id uuid not null references public.bb_profiles(id) on delete cascade,
  amount_cents integer not null,
  fee_cents integer not null default 0,
  status text not null default 'pending' check (status in ('pending','paid','refunded')),
  stripe_session_id text unique,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists bb_mkt_orders_buyer on public.bb_mkt_orders (buyer_id, created_at desc);
create index if not exists bb_mkt_orders_seller on public.bb_mkt_orders (seller_id, created_at desc);

create table if not exists public.bb_mkt_reviews (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.bb_mkt_listings(id) on delete cascade,
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  body text not null default '' check (char_length(body) <= 1000),
  created_at timestamptz not null default now(),
  unique (listing_id, user_id)
);

create table if not exists public.bb_stripe_events (
  id text primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.bb_friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.bb_profiles(id) on delete cascade,
  addressee_id uuid not null references public.bb_profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (requester_id <> addressee_id)
);
create unique index if not exists bb_friendships_pair on public.bb_friendships
  (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index if not exists bb_friendships_addressee on public.bb_friendships (addressee_id);

create table if not exists public.bb_follows (
  follower_id uuid not null references public.bb_profiles(id) on delete cascade,
  following_id uuid not null references public.bb_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);
create index if not exists bb_follows_following on public.bb_follows (following_id);

create table if not exists public.bb_blocks (
  blocker_id uuid not null references public.bb_profiles(id) on delete cascade,
  blocked_id uuid not null references public.bb_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

create table if not exists public.bb_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.bb_profiles(id) on delete cascade,
  recipient_id uuid not null references public.bb_profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists bb_messages_recipient on public.bb_messages (recipient_id, read_at);
create index if not exists bb_messages_pair on public.bb_messages (sender_id, recipient_id, created_at desc);

create table if not exists public.bb_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text not null default '',
  link text not null default '',
  actor_id uuid references public.bb_profiles(id) on delete set null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists bb_notifications_user on public.bb_notifications (user_id, read, created_at desc);

create table if not exists public.bb_forum_categories (
  id serial primary key,
  slug text not null unique,
  name text not null,
  description text not null default '',
  color text not null default '#3da5ff',
  sort integer not null default 0,
  admin_only boolean not null default false
);

create table if not exists public.bb_forum_threads (
  id uuid primary key default gen_random_uuid(),
  category_id integer not null references public.bb_forum_categories(id) on delete cascade,
  author_id uuid not null references public.bb_profiles(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 1 and 10000),
  pinned boolean not null default false,
  locked boolean not null default false,
  likes integer not null default 0,
  reply_count integer not null default 0,
  created_at timestamptz not null default now(),
  last_activity timestamptz not null default now()
);
create index if not exists bb_forum_threads_cat on public.bb_forum_threads (category_id, pinned desc, last_activity desc);

create table if not exists public.bb_forum_replies (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.bb_forum_threads(id) on delete cascade,
  author_id uuid not null references public.bb_profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 5000),
  likes integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists bb_forum_replies_thread on public.bb_forum_replies (thread_id, created_at);

create table if not exists public.bb_forum_likes (
  user_id uuid not null references public.bb_profiles(id) on delete cascade,
  target_id uuid not null,
  kind text not null check (kind in ('thread','reply')),
  primary key (user_id, target_id)
);

create table if not exists public.bb_ping (
  id bigserial primary key,
  pinged_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. ROW LEVEL SECURITY
--    Clients only READ tables. Every write goes through an RPC below.
-- ---------------------------------------------------------------------

alter table public.bb_profiles enable row level security;
alter table public.bb_private enable row level security;
alter table public.bb_games enable row level security;
alter table public.bb_game_votes enable row level security;
alter table public.bb_favorites enable row level security;
alter table public.bb_play_sessions enable row level security;
alter table public.bb_scores enable row level security;
alter table public.bb_daily_earnings enable row level security;
alter table public.bb_ledger enable row level security;
alter table public.bb_items enable row level security;
alter table public.bb_inventory enable row level security;
alter table public.bb_gift_codes enable row level security;
alter table public.bb_redeem_attempts enable row level security;
alter table public.bb_mkt_listings enable row level security;
alter table public.bb_mkt_listing_secrets enable row level security;
alter table public.bb_mkt_orders enable row level security;
alter table public.bb_mkt_reviews enable row level security;
alter table public.bb_stripe_events enable row level security;
alter table public.bb_friendships enable row level security;
alter table public.bb_follows enable row level security;
alter table public.bb_blocks enable row level security;
alter table public.bb_messages enable row level security;
alter table public.bb_notifications enable row level security;
alter table public.bb_forum_categories enable row level security;
alter table public.bb_forum_threads enable row level security;
alter table public.bb_forum_replies enable row level security;
alter table public.bb_forum_likes enable row level security;
alter table public.bb_ping enable row level security;

-- helper checks used by policies (security definer avoids RLS recursion)
create or replace function public.bb_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bb_profiles where id = auth.uid() and role = 'admin' and not banned);
$$;

create or replace function public.bb_is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bb_profiles where id = auth.uid() and not banned);
$$;

create or replace function public.bb_has_plus(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select plus_until > now() from public.bb_profiles where id = p_user), false);
$$;

do $$
declare r record;
begin
  -- drop old bb_ policies so the file is re-runnable
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename like 'bb\_%' loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy bb_profiles_read on public.bb_profiles for select using (true);
create policy bb_private_read on public.bb_private for select using (id = auth.uid());
create policy bb_games_read on public.bb_games for select
  using (builtin or published or creator_id = auth.uid() or public.bb_is_admin());
create policy bb_game_votes_read on public.bb_game_votes for select using (user_id = auth.uid());
create policy bb_favorites_read on public.bb_favorites for select using (user_id = auth.uid());
create policy bb_sessions_read on public.bb_play_sessions for select using (user_id = auth.uid());
create policy bb_scores_read on public.bb_scores for select using (true);
create policy bb_daily_read on public.bb_daily_earnings for select using (user_id = auth.uid());
create policy bb_ledger_read on public.bb_ledger for select using (user_id = auth.uid() or public.bb_is_admin());
create policy bb_items_read on public.bb_items for select using (true);
create policy bb_inventory_read on public.bb_inventory for select using (true);
create policy bb_gift_codes_read on public.bb_gift_codes for select using (public.bb_is_admin());
create policy bb_listings_read on public.bb_mkt_listings for select
  using (status = 'approved' or seller_id = auth.uid() or public.bb_is_admin());
create policy bb_orders_read on public.bb_mkt_orders for select
  using (buyer_id = auth.uid() or seller_id = auth.uid() or public.bb_is_admin());
create policy bb_reviews_read on public.bb_mkt_reviews for select using (true);
create policy bb_friendships_read on public.bb_friendships for select
  using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy bb_follows_read on public.bb_follows for select using (true);
create policy bb_blocks_read on public.bb_blocks for select using (blocker_id = auth.uid());
create policy bb_messages_read on public.bb_messages for select
  using (sender_id = auth.uid() or recipient_id = auth.uid());
create policy bb_notifications_read on public.bb_notifications for select using (user_id = auth.uid());
create policy bb_forum_cat_read on public.bb_forum_categories for select using (true);
create policy bb_forum_threads_read on public.bb_forum_threads for select using (true);
create policy bb_forum_replies_read on public.bb_forum_replies for select using (true);
create policy bb_forum_likes_read on public.bb_forum_likes for select using (user_id = auth.uid());
-- bb_mkt_listing_secrets, bb_redeem_attempts, bb_stripe_events, bb_ping: no client access at all

-- ---------------------------------------------------------------------
-- 3. INTERNAL HELPERS (not callable from the browser)
-- ---------------------------------------------------------------------

create or replace function public.bb_add_bonks(p_user uuid, p_amount integer, p_reason text)
returns integer language plpgsql security definer set search_path = public as $$
declare bal integer;
begin
  update public.bb_profiles set bonks = greatest(0, bonks + p_amount)
   where id = p_user returning bonks into bal;
  if not found then raise exception 'User not found'; end if;
  insert into public.bb_ledger (user_id, amount, reason) values (p_user, p_amount, left(p_reason, 120));
  return bal;
end $$;

create or replace function public.bb_notify(p_user uuid, p_type text, p_title text, p_body text, p_link text, p_actor uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_user = p_actor then return; end if;
  insert into public.bb_notifications (user_id, type, title, body, link, actor_id)
  values (p_user, p_type, left(p_title, 120), left(coalesce(p_body, ''), 300), coalesce(p_link, ''), p_actor);
end $$;

create or replace function public.bb_is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bb_blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;

create or replace function public.bb_require_user() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please sign in first'; end if;
  if not exists (select 1 from public.bb_profiles where id = uid) then raise exception 'Profile missing, reload the page'; end if;
  if exists (select 1 from public.bb_profiles where id = uid and banned) then raise exception 'Your account is banned'; end if;
  return uid;
end $$;

create or replace function public.bb_require_admin() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  if not public.bb_is_admin() then raise exception 'Admins only'; end if;
  return uid;
end $$;

create or replace function public.bb_today() returns date
language sql stable as $$ select (now() at time zone 'utc')::date $$;

-- ---------------------------------------------------------------------
-- 4. AUTH / PROFILES
-- ---------------------------------------------------------------------

create or replace function public.bb_make_username(p_base text) returns text
language plpgsql security definer set search_path = public as $$
declare base text; uname text; n integer := 0;
begin
  base := left(regexp_replace(coalesce(p_base, ''), '[^A-Za-z0-9_]', '', 'g'), 20);
  if char_length(base) < 3 then base := 'Bonker' || substr(md5(random()::text), 1, 4); end if;
  uname := base;
  while exists (select 1 from public.bb_profiles where lower(username) = lower(uname)) loop
    n := n + 1;
    uname := left(base, 15) || (floor(random() * 90000) + 10000)::int;
    exit when n > 25;
  end loop;
  return uname;
end $$;

create or replace function public.bb_create_profile(p_id uuid, p_username text, p_ref text)
returns void language plpgsql security definer set search_path = public as $$
declare ref uuid;
begin
  if exists (select 1 from public.bb_profiles where id = p_id) then return; end if;
  select id into ref from public.bb_profiles where lower(username) = lower(coalesce(p_ref, '')) and id <> p_id;
  insert into public.bb_profiles (id, username, referred_by)
  values (p_id, public.bb_make_username(p_username), ref);
  insert into public.bb_private (id) values (p_id) on conflict do nothing;
  insert into public.bb_ledger (user_id, amount, reason) values (p_id, 100, 'Welcome bonus');
end $$;

create or replace function public.bb_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.bb_create_profile(new.id,
      coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
      new.raw_user_meta_data->>'ref');
  exception when others then
    -- never block a signup in a shared project; the app calls bb_ensure_profile as a fallback
    raise warning 'bb_handle_new_user: %', sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists bb_on_auth_user_created on auth.users;
create trigger bb_on_auth_user_created after insert on auth.users
  for each row execute function public.bb_handle_new_user();

-- fallback for accounts that existed in the project before BonkBrick
create or replace function public.bb_ensure_profile(p_username text, p_ref text default null)
returns public.bb_profiles language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); p public.bb_profiles;
begin
  if uid is null then raise exception 'Please sign in first'; end if;
  perform public.bb_create_profile(uid, p_username, p_ref);
  select * into p from public.bb_profiles where id = uid;
  return p;
end $$;

create or replace function public.bb_check_username(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_username ~ '^[A-Za-z0-9_]{3,20}$'
     and not exists (select 1 from public.bb_profiles where lower(username) = lower(p_username));
$$;

create or replace function public.bb_update_profile(p_bio text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  update public.bb_profiles set bio = left(coalesce(p_bio, ''), 300) where id = uid;
end $$;

create or replace function public.bb_save_avatar(p_avatar jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public.bb_require_user();
  res jsonb := '{}'::jsonb;
  k text; v text; slot_type text;
  slots text[][] := array[['hat','hat'],['face','face'],['shirt','shirt'],['pants','pants'],['accessory','accessory'],['gear','gear']];
  i integer;
begin
  foreach k in array array['skin','torso','legs'] loop
    v := p_avatar->>k;
    if v is not null and v ~ '^#[0-9A-Fa-f]{6}$' then res := res || jsonb_build_object(k, v); end if;
  end loop;
  for i in 1 .. array_length(slots, 1) loop
    k := slots[i][1]; slot_type := slots[i][2];
    v := p_avatar->>k;
    if v is not null and v <> '' then
      if not exists (select 1 from public.bb_inventory inv join public.bb_items it on it.id = inv.item_id
                     where inv.user_id = uid and it.id::text = v and it.type = slot_type) then
        raise exception 'You do not own that %', slot_type;
      end if;
      res := res || jsonb_build_object(k, v);
    end if;
  end loop;
  update public.bb_profiles set avatar = res where id = uid;
  return res;
end $$;

create or replace function public.bb_claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); p public.bb_profiles; streak integer; amt integer; bal integer;
begin
  select * into p from public.bb_profiles where id = uid for update;
  if p.last_daily = public.bb_today() then raise exception 'Already claimed today. Come back tomorrow!'; end if;
  streak := case when p.last_daily = public.bb_today() - 1 then p.daily_streak + 1 else 1 end;
  amt := 25 + least(streak - 1, 7) * 5;
  if public.bb_has_plus(uid) then amt := amt * 2; end if;
  update public.bb_profiles set last_daily = public.bb_today(), daily_streak = streak where id = uid;
  bal := public.bb_add_bonks(uid, amt, 'Daily reward (day ' || streak || ')');
  return json_build_object('amount', amt, 'streak', streak, 'balance', bal);
end $$;

create or replace function public.bb_profile_stats(p_user uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'friends', (select count(*) from public.bb_friendships where status = 'accepted' and (requester_id = p_user or addressee_id = p_user)),
    'followers', (select count(*) from public.bb_follows where following_id = p_user),
    'following', (select count(*) from public.bb_follows where follower_id = p_user),
    'games', (select count(*) from public.bb_games where creator_id = p_user and published),
    'game_plays', (select coalesce(sum(plays), 0) from public.bb_games where creator_id = p_user and published),
    'items', (select count(*) from public.bb_inventory where user_id = p_user),
    'posts', (select count(*) from public.bb_forum_threads where author_id = p_user) + (select count(*) from public.bb_forum_replies where author_id = p_user)
  );
$$;

create or replace function public.bb_my_referrals() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'joined', (select count(*) from public.bb_profiles where referred_by = auth.uid()),
    'rewarded', (select count(*) from public.bb_profiles where referred_by = auth.uid() and referral_rewarded)
  );
$$;

-- ---------------------------------------------------------------------
-- 5. GAMES, SESSIONS, EARNING, LEADERBOARDS
-- ---------------------------------------------------------------------

create or replace function public.bb_start_game(p_game uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); sid uuid;
begin
  if not exists (select 1 from public.bb_games where id = p_game and (builtin or published or creator_id = uid)) then
    raise exception 'Game not found';
  end if;
  if (select count(*) from public.bb_play_sessions where user_id = uid and started_at > now() - interval '1 minute') >= 12 then
    raise exception 'Slow down a little!';
  end if;
  -- only one live session per user, so parallel tabs cannot farm Bonks
  update public.bb_play_sessions set finished_at = now() where user_id = uid and finished_at is null;
  insert into public.bb_play_sessions (user_id, game_id) values (uid, p_game) returning id into sid;
  update public.bb_games set plays = plays + 1 where id = p_game;
  return sid;
end $$;

create or replace function public.bb_finish_game(p_session uuid, p_score numeric default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public.bb_require_user();
  s public.bb_play_sessions; g public.bb_games; p public.bb_profiles;
  secs integer; earn integer; cap integer; today_amt integer; bal integer;
  best numeric; prev numeric; ref_bonus integer := 0; referrer public.bb_profiles;
begin
  select * into s from public.bb_play_sessions where id = p_session and user_id = uid for update;
  if not found then raise exception 'Session not found'; end if;
  if s.finished_at is not null then
    return json_build_object('earned', 0, 'closed', true, 'balance', (select bonks from public.bb_profiles where id = uid));
  end if;
  select * into g from public.bb_games where id = s.game_id;
  select * into p from public.bb_profiles where id = uid for update;

  -- time is measured on the server, never trusted from the client
  secs := least(extract(epoch from (now() - s.started_at))::integer, 1800);
  cap := case when public.bb_has_plus(uid) then 500 else 250 end;
  earn := least(secs / 20, 30) + case when secs >= 30 then 5 else 0 end;
  -- community games pay half, your own game pays nothing (stops self-farming)
  if not g.builtin then earn := case when g.creator_id = uid then 0 else earn / 2 end; end if;

  insert into public.bb_daily_earnings (user_id, day, amount) values (uid, public.bb_today(), 0) on conflict do nothing;
  select amount into today_amt from public.bb_daily_earnings where user_id = uid and day = public.bb_today() for update;
  earn := greatest(0, least(earn, cap - today_amt));
  if earn > 0 then
    update public.bb_daily_earnings set amount = amount + earn where user_id = uid and day = public.bb_today();
    perform public.bb_add_bonks(uid, earn, 'Played ' || g.title);
  end if;
  update public.bb_play_sessions set finished_at = now(), earned = earn, score = p_score where id = s.id;

  -- leaderboard: score must be in the game's sane range, and a timed score can't beat the server clock
  if p_score is not null and p_score >= g.min_score and p_score <= g.max_score and secs >= 3
     and (g.score_order = 'desc' or p_score <= secs + 5) then
    select score into prev from public.bb_scores where game_id = g.id and user_id = uid;
    if prev is null then
      insert into public.bb_scores (game_id, user_id, score) values (g.id, uid, p_score);
    elsif (g.score_order = 'asc' and p_score < prev) or (g.score_order = 'desc' and p_score > prev) then
      update public.bb_scores set score = p_score, updated_at = now() where game_id = g.id and user_id = uid;
    end if;
  end if;
  select score into best from public.bb_scores where game_id = g.id and user_id = uid;

  -- referral reward: once, after the new user's first real (60s+) game, email must be confirmed
  if secs >= 60 and p.referred_by is not null and not p.referral_rewarded
     and exists (select 1 from auth.users where id = uid and email_confirmed_at is not null) then
    update public.bb_profiles set referral_rewarded = true where id = uid;
    perform public.bb_add_bonks(uid, 100, 'Referral welcome bonus');
    ref_bonus := 100;
    select * into referrer from public.bb_profiles where id = p.referred_by;
    if found and not referrer.banned and
       (select count(*) from public.bb_ledger where user_id = referrer.id and reason like 'Referral: %'
          and created_at > now() - interval '1 day') < 10 then
      perform public.bb_add_bonks(referrer.id, 100, 'Referral: ' || p.username);
      perform public.bb_notify(referrer.id, 'referral', 'Referral reward!',
        p.username || ' played their first game. You both got 100 Bonks.', '#/profile/' || p.username, uid);
    end if;
  end if;

  select bonks into bal from public.bb_profiles where id = uid;
  return json_build_object('earned', earn, 'balance', bal, 'capped', (today_amt + earn) >= cap,
    'cap', cap, 'referral', ref_bonus, 'best', best, 'seconds', secs, 'prev', prev);
end $$;

create or replace function public.bb_vote_game(p_game uuid, p_vote integer) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); old smallint; g public.bb_games;
begin
  if p_vote not in (-1, 0, 1) then raise exception 'Bad vote'; end if;
  select vote into old from public.bb_game_votes where user_id = uid and game_id = p_game;
  if old is not null then
    update public.bb_games set likes = likes - (old = 1)::int, dislikes = dislikes - (old = -1)::int where id = p_game;
    delete from public.bb_game_votes where user_id = uid and game_id = p_game;
  end if;
  if p_vote <> 0 then
    insert into public.bb_game_votes (user_id, game_id, vote) values (uid, p_game, p_vote);
    update public.bb_games set likes = likes + (p_vote = 1)::int, dislikes = dislikes + (p_vote = -1)::int where id = p_game;
  end if;
  select * into g from public.bb_games where id = p_game;
  return json_build_object('likes', g.likes, 'dislikes', g.dislikes, 'vote', p_vote);
end $$;

create or replace function public.bb_toggle_favorite(p_game uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  if exists (select 1 from public.bb_favorites where user_id = uid and game_id = p_game) then
    delete from public.bb_favorites where user_id = uid and game_id = p_game;
    update public.bb_games set favorites = greatest(0, favorites - 1) where id = p_game;
    return false;
  end if;
  insert into public.bb_favorites (user_id, game_id) values (uid, p_game);
  update public.bb_games set favorites = favorites + 1 where id = p_game;
  return true;
end $$;

create or replace function public.bb_save_game(p_id uuid, p_title text, p_description text, p_level jsonb,
  p_thumb jsonb, p_published boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); gid uuid;
begin
  if p_level is null or jsonb_typeof(p_level->'rows') <> 'array' then raise exception 'Level data is missing'; end if;
  if p_published and (position('S' in (p_level->'rows')::text) = 0 or position('F' in (p_level->'rows')::text) = 0) then
    raise exception 'Add a spawn point and a finish line before publishing';
  end if;
  if p_id is null then
    if (select count(*) from public.bb_games where creator_id = uid) >= 30 then raise exception 'You can have up to 30 games'; end if;
    insert into public.bb_games (title, description, thumb, level, published, creator_id, builtin, score_order, score_label, min_score, max_score)
    values (left(p_title, 60), left(coalesce(p_description, ''), 500), coalesce(p_thumb, '{}'), p_level, p_published, uid, false, 'asc', 'Time (s)', 1, 7200)
    returning id into gid;
  else
    update public.bb_games set title = left(p_title, 60), description = left(coalesce(p_description, ''), 500),
      thumb = coalesce(p_thumb, '{}'), level = p_level, published = p_published, updated_at = now()
    where id = p_id and creator_id = uid and not builtin returning id into gid;
    if gid is null then raise exception 'Game not found'; end if;
  end if;
  return gid;
end $$;

create or replace function public.bb_delete_game(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  delete from public.bb_games where id = p_id and not builtin and (creator_id = uid or public.bb_is_admin());
end $$;

-- ---------------------------------------------------------------------
-- 6. SHOP + GIFT CODES
-- ---------------------------------------------------------------------

create or replace function public.bb_buy_item(p_item uuid) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); it public.bb_items; bal integer;
begin
  select * into it from public.bb_items where id = p_item for update;
  if not found or not it.active then raise exception 'This item is not for sale'; end if;
  if exists (select 1 from public.bb_inventory where user_id = uid and item_id = p_item) then raise exception 'You already own this'; end if;
  if it.plus_only and not public.bb_has_plus(uid) then raise exception 'This item is for BonkBrick Plus members'; end if;
  if it.stock is not null and it.sold >= it.stock then raise exception 'Sold out!'; end if;
  update public.bb_profiles set bonks = bonks - it.price where id = uid and bonks >= it.price returning bonks into bal;
  if not found then raise exception 'Not enough Bonks'; end if;
  update public.bb_items set sold = sold + 1 where id = it.id;
  insert into public.bb_inventory (user_id, item_id) values (uid, it.id);
  insert into public.bb_ledger (user_id, amount, reason) values (uid, -it.price, 'Bought ' || it.name);
  return json_build_object('balance', bal, 'serial', it.sold + 1);
end $$;

create or replace function public.bb_hash_code(p_code text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex');
$$;

create or replace function public.bb_redeem_code(p_code text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.bb_require_user(); c public.bb_gift_codes; bal integer; hit boolean;
begin
  -- errors are returned (not raised) so the failed attempt row is kept for rate limiting
  if (select count(*) from public.bb_redeem_attempts where user_id = uid and not ok and created_at > now() - interval '1 hour') >= 8 then
    return json_build_object('ok', false, 'error', 'Too many wrong codes. Try again in an hour.');
  end if;
  select * into c from public.bb_gift_codes where code_hash = public.bb_hash_code(p_code) for update;
  hit := found;
  if not hit or c.redeemed_by is not null then
    insert into public.bb_redeem_attempts (user_id, ok) values (uid, false);
    return json_build_object('ok', false, 'error',
      case when hit then 'This code was already redeemed' else 'That code is not valid' end);
  end if;
  update public.bb_gift_codes set redeemed_by = uid, redeemed_at = now() where id = c.id;
  insert into public.bb_redeem_attempts (user_id, ok) values (uid, true);
  bal := public.bb_add_bonks(uid, c.amount, 'Gift code ' || c.code_hint);
  return json_build_object('ok', true, 'amount', c.amount, 'balance', bal);
end $$;

-- ---------------------------------------------------------------------
-- 7. SOCIAL: friends, follows, blocks, DMs, notifications
-- ---------------------------------------------------------------------

create or replace function public.bb_friend_request(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); f public.bb_friendships; me text;
begin
  if p_user = uid then raise exception 'You cannot friend yourself'; end if;
  if public.bb_is_blocked_between(uid, p_user) then raise exception 'You cannot add this user'; end if;
  select username into me from public.bb_profiles where id = uid;
  select * into f from public.bb_friendships
   where least(requester_id, addressee_id) = least(uid, p_user) and greatest(requester_id, addressee_id) = greatest(uid, p_user);
  if found then
    if f.status = 'accepted' then return 'friends'; end if;
    if f.addressee_id = uid then
      update public.bb_friendships set status = 'accepted', responded_at = now() where id = f.id;
      perform public.bb_notify(p_user, 'friend', 'Friend request accepted', me || ' is now your friend', '#/profile/' || me, uid);
      return 'friends';
    end if;
    return 'pending';
  end if;
  if (select count(*) from public.bb_friendships where requester_id = uid and status = 'pending') >= 100 then
    raise exception 'Too many pending requests';
  end if;
  insert into public.bb_friendships (requester_id, addressee_id) values (uid, p_user);
  perform public.bb_notify(p_user, 'friend', 'New friend request', me || ' wants to be friends', '#/friends', uid);
  return 'pending';
end $$;

create or replace function public.bb_friend_respond(p_request uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); f public.bb_friendships; me text;
begin
  select * into f from public.bb_friendships where id = p_request and addressee_id = uid and status = 'pending';
  if not found then raise exception 'Request not found'; end if;
  if p_accept then
    update public.bb_friendships set status = 'accepted', responded_at = now() where id = f.id;
    select username into me from public.bb_profiles where id = uid;
    perform public.bb_notify(f.requester_id, 'friend', 'Friend request accepted', me || ' is now your friend', '#/profile/' || me, uid);
  else
    delete from public.bb_friendships where id = f.id;
  end if;
end $$;

create or replace function public.bb_friend_remove(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  delete from public.bb_friendships
   where least(requester_id, addressee_id) = least(uid, p_user) and greatest(requester_id, addressee_id) = greatest(uid, p_user);
end $$;

create or replace function public.bb_toggle_follow(p_user uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); me text;
begin
  if p_user = uid then raise exception 'You cannot follow yourself'; end if;
  if exists (select 1 from public.bb_follows where follower_id = uid and following_id = p_user) then
    delete from public.bb_follows where follower_id = uid and following_id = p_user;
    return false;
  end if;
  if public.bb_is_blocked_between(uid, p_user) then raise exception 'You cannot follow this user'; end if;
  insert into public.bb_follows (follower_id, following_id) values (uid, p_user);
  select username into me from public.bb_profiles where id = uid;
  perform public.bb_notify(p_user, 'follow', 'New follower', me || ' started following you', '#/profile/' || me, uid);
  return true;
end $$;

create or replace function public.bb_toggle_block(p_user uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  if p_user = uid then raise exception 'You cannot block yourself'; end if;
  if exists (select 1 from public.bb_blocks where blocker_id = uid and blocked_id = p_user) then
    delete from public.bb_blocks where blocker_id = uid and blocked_id = p_user;
    return false;
  end if;
  insert into public.bb_blocks (blocker_id, blocked_id) values (uid, p_user);
  delete from public.bb_friendships
   where least(requester_id, addressee_id) = least(uid, p_user) and greatest(requester_id, addressee_id) = greatest(uid, p_user);
  delete from public.bb_follows where (follower_id = uid and following_id = p_user) or (follower_id = p_user and following_id = uid);
  return true;
end $$;

create or replace function public.bb_send_message(p_to uuid, p_body text) returns public.bb_messages
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); m public.bb_messages; me text; existing uuid; v_body text := btrim(coalesce(p_body, ''));
begin
  if p_to = uid then raise exception 'You cannot message yourself'; end if;
  if v_body = '' then raise exception 'Message is empty'; end if;
  if not exists (select 1 from public.bb_profiles where id = p_to) then raise exception 'User not found'; end if;
  if public.bb_is_blocked_between(uid, p_to) then raise exception 'You cannot message this user'; end if;
  if (select count(*) from public.bb_messages where sender_id = uid and created_at > now() - interval '10 seconds') >= 6 then
    raise exception 'Slow down! You are sending messages too fast';
  end if;
  insert into public.bb_messages (sender_id, recipient_id, body) values (uid, p_to, left(v_body, 2000)) returning * into m;
  select username into me from public.bb_profiles where id = uid;
  -- one rolling unread DM notification per sender instead of one per message
  select id into existing from public.bb_notifications
   where user_id = p_to and type = 'dm' and actor_id = uid and not read limit 1;
  if existing is not null then
    update public.bb_notifications set body = left(v_body, 140), created_at = now() where id = existing;
  else
    perform public.bb_notify(p_to, 'dm', 'Message from ' || me, left(v_body, 140), '#/messages/' || me, uid);
  end if;
  return m;
end $$;

create or replace function public.bb_mark_read(p_other uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  update public.bb_messages set read_at = now() where recipient_id = uid and sender_id = p_other and read_at is null;
  update public.bb_notifications set read = true where user_id = uid and type = 'dm' and actor_id = p_other;
end $$;

create or replace function public.bb_conversations() returns table (
  other_id uuid, username text, avatar jsonb, verified boolean, last_body text, last_at timestamptz, last_mine boolean, unread bigint)
language sql stable security definer set search_path = public as $$
  with mine as (
    select case when sender_id = auth.uid() then recipient_id else sender_id end as other, m.*
    from public.bb_messages m where sender_id = auth.uid() or recipient_id = auth.uid()
  ), last as (
    select distinct on (other) other, body, created_at, sender_id = auth.uid() as mine_flag
    from mine order by other, created_at desc
  )
  select l.other, p.username, p.avatar, p.verified, l.body, l.created_at, l.mine_flag,
    (select count(*) from public.bb_messages x where x.sender_id = l.other and x.recipient_id = auth.uid() and x.read_at is null)
  from last l join public.bb_profiles p on p.id = l.other
  order by l.created_at desc limit 100;
$$;

create or replace function public.bb_unread_counts() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'dms', (select count(*) from public.bb_messages where recipient_id = auth.uid() and read_at is null),
    'notifications', (select count(*) from public.bb_notifications where user_id = auth.uid() and not read));
$$;

create or replace function public.bb_mark_notifications_read() returns void
language sql security definer set search_path = public as $$
  update public.bb_notifications set read = true where user_id = auth.uid() and not read;
$$;

create or replace function public.bb_clear_notifications() returns void
language sql security definer set search_path = public as $$
  delete from public.bb_notifications where user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- 8. DEVFORUM
-- ---------------------------------------------------------------------

create or replace function public.bb_forum_post_thread(p_category integer, p_title text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); c public.bb_forum_categories; tid uuid;
begin
  select * into c from public.bb_forum_categories where id = p_category;
  if not found then raise exception 'Category not found'; end if;
  if c.admin_only and not public.bb_is_admin() then raise exception 'Only admins can post in %', c.name; end if;
  if (select count(*) from public.bb_forum_threads where author_id = uid and created_at > now() - interval '2 minutes') >= 2 then
    raise exception 'Wait a couple of minutes before posting another thread';
  end if;
  insert into public.bb_forum_threads (category_id, author_id, title, body)
  values (p_category, uid, btrim(p_title), btrim(p_body)) returning id into tid;
  return tid;
end $$;

create or replace function public.bb_forum_reply(p_thread uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); t public.bb_forum_threads; rid uuid; me text;
begin
  select * into t from public.bb_forum_threads where id = p_thread for update;
  if not found then raise exception 'Thread not found'; end if;
  if t.locked and not public.bb_is_admin() then raise exception 'This thread is locked'; end if;
  if (select count(*) from public.bb_forum_replies where author_id = uid and created_at > now() - interval '20 seconds') >= 3 then
    raise exception 'Slow down a little';
  end if;
  insert into public.bb_forum_replies (thread_id, author_id, body) values (p_thread, uid, btrim(p_body)) returning id into rid;
  update public.bb_forum_threads set reply_count = reply_count + 1, last_activity = now() where id = p_thread;
  select username into me from public.bb_profiles where id = uid;
  perform public.bb_notify(t.author_id, 'forum', 'New reply', me || ' replied to "' || left(t.title, 60) || '"', '#/forum/t/' || t.id, uid);
  return rid;
end $$;

create or replace function public.bb_forum_like(p_target uuid, p_kind text) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); liked boolean; n integer;
begin
  if p_kind not in ('thread','reply') then raise exception 'Bad kind'; end if;
  if exists (select 1 from public.bb_forum_likes where user_id = uid and target_id = p_target) then
    delete from public.bb_forum_likes where user_id = uid and target_id = p_target; liked := false;
  else
    insert into public.bb_forum_likes (user_id, target_id, kind) values (uid, p_target, p_kind); liked := true;
  end if;
  if p_kind = 'thread' then
    update public.bb_forum_threads set likes = greatest(0, likes + case when liked then 1 else -1 end) where id = p_target returning likes into n;
  else
    update public.bb_forum_replies set likes = greatest(0, likes + case when liked then 1 else -1 end) where id = p_target returning likes into n;
  end if;
  return json_build_object('liked', liked, 'likes', coalesce(n, 0));
end $$;

create or replace function public.bb_forum_delete(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); tid uuid;
begin
  if p_kind = 'thread' then
    delete from public.bb_forum_threads where id = p_id and (author_id = uid or public.bb_is_admin());
  else
    delete from public.bb_forum_replies where id = p_id and (author_id = uid or public.bb_is_admin()) returning thread_id into tid;
    if tid is not null then
      update public.bb_forum_threads set reply_count = greatest(0, reply_count - 1) where id = tid;
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 9. REAL-MONEY MARKETPLACE
-- ---------------------------------------------------------------------

create or replace function public.bb_save_listing(p_id uuid, p_title text, p_description text, p_price_cents integer,
  p_image_url text, p_category text, p_delivery text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); lid uuid; me text; a record;
begin
  if p_category not in ('Game Assets','Art','Models','Scripts','Services','Other') then p_category := 'Other'; end if;
  if p_image_url is not null and p_image_url <> '' and p_image_url !~ '^https://' then raise exception 'Image must be an https URL'; end if;
  if p_id is null then
    if (select count(*) from public.bb_mkt_listings where seller_id = uid and status = 'pending') >= 10 then
      raise exception 'You have too many listings waiting for review';
    end if;
    insert into public.bb_mkt_listings (seller_id, title, description, price_cents, image_url, category)
    values (uid, btrim(p_title), coalesce(p_description, ''), p_price_cents, nullif(p_image_url, ''), p_category) returning id into lid;
  else
    -- any edit goes back to the review queue
    update public.bb_mkt_listings set title = btrim(p_title), description = coalesce(p_description, ''), price_cents = p_price_cents,
      image_url = nullif(p_image_url, ''), category = p_category, status = 'pending', updated_at = now()
    where id = p_id and seller_id = uid returning id into lid;
    if lid is null then raise exception 'Listing not found'; end if;
  end if;
  insert into public.bb_mkt_listing_secrets (listing_id, delivery) values (lid, coalesce(p_delivery, ''))
  on conflict (listing_id) do update set delivery = excluded.delivery;
  select username into me from public.bb_profiles where id = uid;
  for a in select id from public.bb_profiles where role = 'admin' loop
    perform public.bb_notify(a.id, 'approval', 'Listing needs review', me || ' submitted "' || left(p_title, 60) || '"', '#/admin/listings', uid);
  end loop;
  return lid;
end $$;

create or replace function public.bb_set_listing_paused(p_id uuid, p_paused boolean) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  update public.bb_mkt_listings set status = case when p_paused then 'paused' else 'pending' end, updated_at = now()
  where id = p_id and seller_id = uid and status in ('approved','paused');
end $$;

create or replace function public.bb_delete_listing(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user();
begin
  if exists (select 1 from public.bb_mkt_orders where listing_id = p_id and status = 'paid') then
    update public.bb_mkt_listings set status = 'paused' where id = p_id and (seller_id = uid or public.bb_is_admin());
  else
    delete from public.bb_mkt_listings where id = p_id and (seller_id = uid or public.bb_is_admin());
  end if;
end $$;

create or replace function public.bb_get_delivery(p_listing uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  if exists (select 1 from public.bb_mkt_listings where id = p_listing and seller_id = uid)
     or exists (select 1 from public.bb_mkt_orders where listing_id = p_listing and buyer_id = uid and status = 'paid')
     or public.bb_is_admin() then
    return (select delivery from public.bb_mkt_listing_secrets where listing_id = p_listing);
  end if;
  return null;
end $$;

create or replace function public.bb_review_listing(p_listing uuid, p_rating integer, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := public.bb_require_user(); l public.bb_mkt_listings; me text;
begin
  if not exists (select 1 from public.bb_mkt_orders where listing_id = p_listing and buyer_id = uid and status = 'paid') then
    raise exception 'Only buyers can review this item';
  end if;
  insert into public.bb_mkt_reviews (listing_id, user_id, rating, body) values (p_listing, uid, p_rating, left(coalesce(p_body, ''), 1000))
  on conflict (listing_id, user_id) do update set rating = excluded.rating, body = excluded.body, created_at = now();
  update public.bb_mkt_listings set
    rating_avg = (select round(avg(rating)::numeric, 2) from public.bb_mkt_reviews where listing_id = p_listing),
    rating_count = (select count(*) from public.bb_mkt_reviews where listing_id = p_listing)
  where id = p_listing returning * into l;
  select username into me from public.bb_profiles where id = uid;
  perform public.bb_notify(l.seller_id, 'review', 'New review: ' || p_rating || ' stars', me || ' reviewed "' || left(l.title, 60) || '"', '#/market/' || l.id, uid);
end $$;

-- called by the Stripe Edge Function only (service role)
create or replace function public.bb_mark_order_paid(p_session text) returns json
language plpgsql security definer set search_path = public as $$
declare o public.bb_mkt_orders; l public.bb_mkt_listings; buyer text;
begin
  update public.bb_mkt_orders set status = 'paid', paid_at = now()
   where stripe_session_id = p_session and status = 'pending' returning * into o;
  if not found then return json_build_object('updated', false); end if;
  update public.bb_mkt_listings set sales = sales + 1 where id = o.listing_id returning * into l;
  select username into buyer from public.bb_profiles where id = o.buyer_id;
  perform public.bb_notify(o.seller_id, 'sale', 'You made a sale!',
    buyer || ' bought "' || left(l.title, 60) || '" for $' || to_char(o.amount_cents / 100.0, 'FM999990.00'), '#/sell', o.buyer_id);
  perform public.bb_notify(o.buyer_id, 'sale', 'Purchase complete', 'You bought "' || left(l.title, 60) || '". Open it to see your delivery.', '#/market/' || l.id, null);
  return json_build_object('updated', true);
end $$;

create or replace function public.bb_set_plus(p_user uuid, p_until timestamptz, p_customer text, p_subscription text, p_stipend boolean)
returns void language plpgsql security definer set search_path = public as $$
declare was boolean;
begin
  was := public.bb_has_plus(p_user);
  update public.bb_profiles set plus_until = p_until where id = p_user;
  update public.bb_private set stripe_customer_id = coalesce(p_customer, stripe_customer_id),
    stripe_subscription_id = coalesce(p_subscription, stripe_subscription_id) where id = p_user;
  if p_stipend then perform public.bb_add_bonks(p_user, 500, 'BonkBrick Plus monthly Bonks'); end if;
  if not was and p_until > now() then
    perform public.bb_notify(p_user, 'plus', 'Welcome to BonkBrick Plus!', 'Your Plus badge and perks are active.', '#/plus', null);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10. ADMIN
-- ---------------------------------------------------------------------

create or replace function public.bb_admin_stats() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.bb_require_admin();
  return json_build_object(
    'users', (select count(*) from public.bb_profiles),
    'users_7d', (select count(*) from public.bb_profiles where created_at > now() - interval '7 days'),
    'banned', (select count(*) from public.bb_profiles where banned),
    'plus', (select count(*) from public.bb_profiles where plus_until > now()),
    'community_games', (select count(*) from public.bb_games where not builtin and published),
    'plays', (select coalesce(sum(plays), 0) from public.bb_games),
    'plays_24h', (select count(*) from public.bb_play_sessions where started_at > now() - interval '1 day'),
    'bonks_supply', (select coalesce(sum(bonks), 0) from public.bb_profiles),
    'pending_listings', (select count(*) from public.bb_mkt_listings where status = 'pending'),
    'orders_paid', (select count(*) from public.bb_mkt_orders where status = 'paid'),
    'revenue_cents', (select coalesce(sum(amount_cents), 0) from public.bb_mkt_orders where status = 'paid'),
    'fees_cents', (select coalesce(sum(fee_cents), 0) from public.bb_mkt_orders where status = 'paid'),
    'codes_open', (select count(*) from public.bb_gift_codes where redeemed_by is null),
    'codes_redeemed', (select count(*) from public.bb_gift_codes where redeemed_by is not null),
    'threads', (select count(*) from public.bb_forum_threads),
    'messages_24h', (select count(*) from public.bb_messages where created_at > now() - interval '1 day'));
end $$;

create or replace function public.bb_admin_set_verified(p_user uuid, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
declare admin_id uuid := public.bb_require_admin();
begin
  update public.bb_profiles set verified = p_value where id = p_user;
  if p_value then perform public.bb_notify(p_user, 'verified', 'You are verified!', 'An admin gave you the verified badge.', '#/profile', admin_id); end if;
end $$;

create or replace function public.bb_admin_set_banned(p_user uuid, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
declare admin_id uuid := public.bb_require_admin();
begin
  if p_user = admin_id then raise exception 'You cannot ban yourself'; end if;
  update public.bb_profiles set banned = p_value where id = p_user;
  if p_value then
    update public.bb_mkt_listings set status = 'paused' where seller_id = p_user and status = 'approved';
    update public.bb_games set published = false where creator_id = p_user;
  end if;
end $$;

create or replace function public.bb_admin_set_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare admin_id uuid := public.bb_require_admin();
begin
  if p_role not in ('user','admin') then raise exception 'Bad role'; end if;
  if p_user = admin_id and p_role <> 'admin' then raise exception 'You cannot remove your own admin role'; end if;
  update public.bb_profiles set role = p_role where id = p_user;
end $$;

create or replace function public.bb_admin_grant_bonks(p_user uuid, p_amount integer, p_reason text) returns integer
language plpgsql security definer set search_path = public as $$
begin
  perform public.bb_require_admin();
  if abs(p_amount) > 1000000 then raise exception 'Amount too large'; end if;
  return public.bb_add_bonks(p_user, p_amount, 'Admin: ' || coalesce(nullif(p_reason, ''), 'adjustment'));
end $$;

create or replace function public.bb_admin_review_listing(p_id uuid, p_status text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare admin_id uuid := public.bb_require_admin(); l public.bb_mkt_listings;
begin
  if p_status not in ('approved','rejected','paused','pending') then raise exception 'Bad status'; end if;
  update public.bb_mkt_listings set status = p_status, admin_note = coalesce(p_note, ''), updated_at = now(),
    approved_at = case when p_status = 'approved' then now() else approved_at end
  where id = p_id returning * into l;
  if not found then raise exception 'Listing not found'; end if;
  perform public.bb_notify(l.seller_id, 'approval',
    case when p_status = 'approved' then 'Listing approved!' else 'Listing ' || p_status end,
    '"' || left(l.title, 60) || '"' || case when coalesce(p_note, '') <> '' then ': ' || p_note else '' end,
    '#/market/' || l.id, admin_id);
end $$;

create or replace function public.bb_admin_create_codes(p_amount integer, p_count integer, p_note text) returns setof text
language plpgsql security definer set search_path = public, extensions as $$
declare admin_id uuid := public.bb_require_admin(); raw text; code text; i integer;
begin
  if p_amount < 1 or p_amount > 1000000 then raise exception 'Amount must be 1 to 1,000,000'; end if;
  if p_count < 1 or p_count > 200 then raise exception 'Create 1 to 200 codes at a time'; end if;
  for i in 1 .. p_count loop
    raw := upper(encode(extensions.gen_random_bytes(8), 'hex'));
    code := 'BB-' || substr(raw, 1, 4) || '-' || substr(raw, 5, 4) || '-' || substr(raw, 9, 4) || '-' || substr(raw, 13, 4);
    insert into public.bb_gift_codes (code_hash, code_hint, amount, note, created_by)
    values (public.bb_hash_code(code), 'BB-' || substr(raw, 1, 4) || '-...', p_amount, coalesce(p_note, ''), admin_id);
    return next code;   -- plaintext is returned once and never stored
  end loop;
end $$;

create or replace function public.bb_admin_save_item(p_id uuid, p_name text, p_type text, p_price integer, p_stock integer,
  p_limited boolean, p_plus_only boolean, p_style jsonb, p_description text, p_active boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare iid uuid;
begin
  perform public.bb_require_admin();
  if p_id is null then
    insert into public.bb_items (name, type, price, stock, limited, plus_only, style, description, active)
    values (p_name, p_type, p_price, p_stock, p_limited, p_plus_only, coalesce(p_style, '{}'), coalesce(p_description, ''), p_active)
    returning id into iid;
  else
    update public.bb_items set name = p_name, type = p_type, price = p_price, stock = p_stock, limited = p_limited,
      plus_only = p_plus_only, style = coalesce(p_style, '{}'), description = coalesce(p_description, ''), active = p_active
    where id = p_id returning id into iid;
  end if;
  return iid;
end $$;

create or replace function public.bb_admin_forum(p_thread uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.bb_require_admin();
  case p_action
    when 'pin' then update public.bb_forum_threads set pinned = true where id = p_thread;
    when 'unpin' then update public.bb_forum_threads set pinned = false where id = p_thread;
    when 'lock' then update public.bb_forum_threads set locked = true where id = p_thread;
    when 'unlock' then update public.bb_forum_threads set locked = false where id = p_thread;
    when 'delete' then delete from public.bb_forum_threads where id = p_thread;
    else raise exception 'Bad action';
  end case;
end $$;

-- ---------------------------------------------------------------------
-- 11. KEEPALIVE
-- ---------------------------------------------------------------------

create or replace function public.bb_ping() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare t timestamptz;
begin
  insert into public.bb_ping default values returning pinged_at into t;
  delete from public.bb_ping where pinged_at < now() - interval '3 days';
  return t;
end $$;

do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  if exists (select 1 from cron.job where jobname = 'bb_keepalive') then
    perform cron.unschedule('bb_keepalive');
  end if;
  perform cron.schedule('bb_keepalive', '17 */6 * * *', 'select public.bb_ping()');
exception when others then
  raise notice 'pg_cron not available (%). Use the free external cron from the setup checklist.', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 12. GRANTS: lock helpers down, open RPCs to signed-in users
-- ---------------------------------------------------------------------

grant select on public.bb_profiles, public.bb_games, public.bb_scores, public.bb_items, public.bb_inventory,
  public.bb_mkt_listings, public.bb_mkt_reviews, public.bb_follows, public.bb_forum_categories,
  public.bb_forum_threads, public.bb_forum_replies to anon;
grant select on public.bb_profiles, public.bb_private, public.bb_games, public.bb_game_votes, public.bb_favorites,
  public.bb_play_sessions, public.bb_scores, public.bb_daily_earnings, public.bb_ledger, public.bb_items, public.bb_inventory,
  public.bb_gift_codes, public.bb_mkt_listings, public.bb_mkt_orders, public.bb_mkt_reviews, public.bb_friendships,
  public.bb_follows, public.bb_blocks, public.bb_messages, public.bb_notifications, public.bb_forum_categories,
  public.bb_forum_threads, public.bb_forum_replies, public.bb_forum_likes to authenticated;
-- no direct writes from the browser, ever
revoke insert, update, delete, truncate on public.bb_profiles, public.bb_private, public.bb_games, public.bb_game_votes,
  public.bb_favorites, public.bb_play_sessions, public.bb_scores, public.bb_daily_earnings, public.bb_ledger, public.bb_items,
  public.bb_inventory, public.bb_gift_codes, public.bb_redeem_attempts, public.bb_mkt_listings, public.bb_mkt_listing_secrets,
  public.bb_mkt_orders, public.bb_mkt_reviews, public.bb_stripe_events, public.bb_friendships, public.bb_follows, public.bb_blocks,
  public.bb_messages, public.bb_notifications, public.bb_forum_categories, public.bb_forum_threads, public.bb_forum_replies,
  public.bb_forum_likes, public.bb_ping from anon, authenticated;
do $$
declare r record;
begin
  -- touch only bb_ objects, never other apps sharing this project
  for r in select tablename from pg_tables where schemaname = 'public' and tablename like 'bb\_%' loop
    execute format('grant all on public.%I to service_role', r.tablename);
  end loop;
  for r in select sequence_name from information_schema.sequences where sequence_schema = 'public' and sequence_name like 'bb\_%' loop
    execute format('grant usage, select on sequence public.%I to service_role', r.sequence_name);
  end loop;
end $$;

-- internal helpers: server only
revoke execute on function public.bb_add_bonks(uuid, integer, text) from public, anon, authenticated;
revoke execute on function public.bb_notify(uuid, text, text, text, text, uuid) from public, anon, authenticated;
revoke execute on function public.bb_create_profile(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.bb_make_username(text) from public, anon, authenticated;
revoke execute on function public.bb_handle_new_user() from public, anon, authenticated;
revoke execute on function public.bb_mark_order_paid(text) from public, anon, authenticated;
revoke execute on function public.bb_set_plus(uuid, timestamptz, text, text, boolean) from public, anon, authenticated;
grant execute on function public.bb_add_bonks(uuid, integer, text) to service_role;
grant execute on function public.bb_notify(uuid, text, text, text, text, uuid) to service_role;
grant execute on function public.bb_mark_order_paid(text) to service_role;
grant execute on function public.bb_set_plus(uuid, timestamptz, text, text, boolean) to service_role;

-- public RPCs for guests
grant execute on function public.bb_ping() to anon, authenticated;
grant execute on function public.bb_check_username(text) to anon, authenticated;
grant execute on function public.bb_profile_stats(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. REALTIME + STORAGE
-- ---------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['bb_messages','bb_notifications','bb_profiles'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
              when undefined_object then raise notice 'supabase_realtime publication missing';
    end;
  end loop;
end $$;

do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('bb_media', 'bb_media', true, 2097152, array['image/png','image/jpeg','image/webp','image/gif'])
  on conflict (id) do nothing;

  drop policy if exists bb_media_read on storage.objects;
  drop policy if exists bb_media_insert on storage.objects;
  drop policy if exists bb_media_delete on storage.objects;
  create policy bb_media_read on storage.objects for select using (bucket_id = 'bb_media');
  create policy bb_media_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'bb_media' and (storage.foldername(name))[1] = auth.uid()::text);
  create policy bb_media_delete on storage.objects for delete to authenticated
    using (bucket_id = 'bb_media' and (storage.foldername(name))[1] = auth.uid()::text);
exception when others then
  raise notice 'Storage setup skipped (%). Create a public bucket named bb_media by hand.', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 14. SEED DATA
-- ---------------------------------------------------------------------

insert into public.bb_games (slug, title, description, thumb, builtin, published, score_order, score_label, min_score, max_score) values
 ('obby','Mega Obby','Jump across floating bricks, dodge red kill bricks and bounce off pads. Hit checkpoints and race to the finish flag.','{"e":"🏃","c1":"#ff4d6d","c2":"#ffb703"}',true,true,'asc','Time (s)',20,3600),
 ('tower','Tower Climb','The lava is rising! Climb the endless tower as high as you can before it catches you.','{"e":"🗼","c1":"#f97316","c2":"#7c2d12"}',true,true,'desc','Height',0,100000),
 ('sword','Sword Duel','Grab your blade and fight waves of sword bots. Watch for their red wind-up and dash out of the way.','{"e":"⚔️","c1":"#6366f1","c2":"#1e1b4b"}',true,true,'desc','Kills',0,10000),
 ('racing','Brick Racing','Three laps against three bots on a twisty track. Stay on the road and drift the corners.','{"e":"🏎️","c1":"#22c55e","c2":"#14532d"}',true,true,'asc','Time (s)',30,3600),
 ('tycoon','Brick Tycoon','Click bricks, buy droppers and factories, then rebirth for a giant multiplier.','{"e":"🏭","c1":"#eab308","c2":"#854d0e"}',true,true,'desc','Cash earned',0,1000000000000000),
 ('zombie','Zombie Survival','Hold out against endless waves of zombies. Fast ones, tanky ones, all of them hungry.','{"e":"🧟","c1":"#84cc16","c2":"#1a2e05"}',true,true,'desc','Kills',0,100000),
 ('pets','Pet Simulator','Hatch eggs, collect cute pets and send them to break coin piles. Unlock new worlds.','{"e":"🐶","c1":"#ec4899","c2":"#831843"}',true,true,'desc','Coins',0,1000000000000000),
 ('maze','Escape the Maze','Find the exit of three dark mazes as fast as you can. Your torch only shows so much.','{"e":"🌀","c1":"#06b6d4","c2":"#164e63"}',true,true,'asc','Time (s)',15,7200),
 ('arena','Bonk Arena','Dash into bots to bonk them off the shrinking platform. Last brick standing wins.','{"e":"💥","c1":"#ef4444","c2":"#450a0a"}',true,true,'desc','Knockouts',0,10000),
 ('builder','Brick Builder','A relaxing sandbox. Stack colorful bricks in 3D, paint them and rotate your build.','{"e":"🧱","c1":"#a855f7","c2":"#3b0764"}',true,true,'desc','Bricks placed',0,100000),
 ('tag','Tag & Seek','One player is IT. Hide behind walls, break line of sight and stay free as long as you can.','{"e":"🫣","c1":"#14b8a6","c2":"#042f2e"}',true,true,'desc','Seconds free',0,200)
on conflict (slug) do update set title = excluded.title, description = excluded.description, thumb = excluded.thumb,
  score_order = excluded.score_order, score_label = excluded.score_label, min_score = excluded.min_score, max_score = excluded.max_score;

insert into public.bb_forum_categories (slug, name, description, color, sort, admin_only) values
 ('announcements','Announcements','News and updates from the BonkBrick team','#ffd23f',1,true),
 ('help','Help','Stuck on something? Ask the community','#3da5ff',2,false),
 ('showcase','Showcase','Show off your games, builds and avatars','#3ddc84',3,false),
 ('bugs','Bugs','Found a bug? Report it here','#ff4d6d',4,false),
 ('off-topic','Off-topic','Anything else, keep it friendly','#a66bff',5,false)
on conflict (slug) do nothing;

insert into public.bb_items (slug, name, type, price, stock, limited, plus_only, style, description) values
 ('red-cap','Red Cap','hat',50,null,false,false,'{"kind":"cap","color":"#ef4444","color2":"#991b1b"}','A classic.'),
 ('blue-cap','Blue Cap','hat',50,null,false,false,'{"kind":"cap","color":"#3b82f6","color2":"#1e3a8a"}','Cool and casual.'),
 ('top-hat','Fancy Top Hat','hat',250,null,false,false,'{"kind":"tophat","color":"#111827","color2":"#dc2626"}','Very distinguished.'),
 ('party-hat','Party Hat','hat',120,null,false,false,'{"kind":"party","color":"#ec4899","color2":"#facc15"}','Every day is a party.'),
 ('beanie','Cozy Beanie','hat',90,null,false,false,'{"kind":"beanie","color":"#22c55e","color2":"#f8fafc"}','Warm head, warm heart.'),
 ('viking','Viking Helmet','hat',400,null,false,false,'{"kind":"horns","color":"#9ca3af","color2":"#fef3c7"}','Raid the obby.'),
 ('cone','Traffic Cone','hat',75,null,false,false,'{"kind":"cone","color":"#f97316","color2":"#f8fafc"}','Caution: bonker ahead.'),
 ('headphones','Bass Headphones','hat',300,null,false,false,'{"kind":"headphones","color":"#a855f7","color2":"#1f2937"}','Hear the bonks.'),
 ('crown','Golden Crown','hat',2500,50,true,false,'{"kind":"crown","color":"#facc15","color2":"#dc2626"}','Limited. Only 50 will ever exist.'),
 ('halo','Bonk Halo','hat',5000,25,true,false,'{"kind":"halo","color":"#fde047","color2":"#fef9c3"}','Limited. Only 25 exist.'),
 ('plus-crown','Plus Crown','hat',0,null,false,true,'{"kind":"crown","color":"#38bdf8","color2":"#f0abfc"}','Free for BonkBrick Plus members.'),
 ('face-cool','Cool Shades','face',150,null,false,false,'{"kind":"cool","color":"#111827"}','Too cool for school.'),
 ('face-wink','Wink','face',60,null,false,false,'{"kind":"wink","color":"#111827"}',';)'),
 ('face-angry','Grr Face','face',60,null,false,false,'{"kind":"angry","color":"#111827"}','Do not bonk me.'),
 ('face-robot','Robot Visor','face',350,null,false,false,'{"kind":"robot","color":"#22d3ee"}','Beep boop.'),
 ('face-cat','Kitty Face','face',200,null,false,false,'{"kind":"cat","color":"#111827"}','Meow.'),
 ('face-star','Star Eyes','face',800,100,true,false,'{"kind":"star","color":"#facc15"}','Limited. Starstruck.'),
 ('shirt-stripe','Striped Tee','shirt',80,null,false,false,'{"kind":"stripes","color":"#f8fafc","color2":"#ef4444"}','Stripes never die.'),
 ('shirt-hoodie','Cozy Hoodie','shirt',200,null,false,false,'{"kind":"hoodie","color":"#64748b","color2":"#334155"}','Hood up.'),
 ('shirt-logo','BonkBrick Tee','shirt',120,null,false,false,'{"kind":"logo","color":"#111827","color2":"#ffd23f"}','Rep the brick.'),
 ('shirt-tux','Tuxedo','shirt',600,null,false,false,'{"kind":"tux","color":"#111827","color2":"#f8fafc"}','For formal bonking.'),
 ('shirt-camo','Camo Jacket','shirt',300,null,false,false,'{"kind":"camo","color":"#4d7c0f","color2":"#365314"}','You cannot see me.'),
 ('pants-jeans','Blue Jeans','pants',80,null,false,false,'{"kind":"jeans","color":"#1d4ed8","color2":"#1e3a8a"}','Comfy.'),
 ('pants-black','Black Slacks','pants',80,null,false,false,'{"kind":"plain","color":"#111827"}','Sharp.'),
 ('pants-red','Red Joggers','pants',100,null,false,false,'{"kind":"plain","color":"#b91c1c"}','Fast legs.'),
 ('pants-gold','Golden Pants','pants',3000,30,true,false,'{"kind":"plain","color":"#eab308"}','Limited. Shiny legs.'),
 ('acc-cape','Hero Cape','accessory',350,null,false,false,'{"kind":"cape","color":"#dc2626"}','Not for flying. Probably.'),
 ('acc-wings','Angel Wings','accessory',1200,null,false,false,'{"kind":"wings","color":"#f8fafc"}','Heavenly.'),
 ('acc-backpack','Adventure Pack','accessory',150,null,false,false,'{"kind":"backpack","color":"#a16207"}','Holds snacks.'),
 ('acc-scarf','Winter Scarf','accessory',90,null,false,false,'{"kind":"scarf","color":"#2563eb"}','Toasty.'),
 ('acc-dragon','Dragon Wings','accessory',4000,40,true,false,'{"kind":"wings","color":"#7c3aed"}','Limited. Rawr.'),
 ('gear-sword','Brick Sword','gear',250,null,false,false,'{"kind":"sword","color":"#cbd5e1"}','Pointy.'),
 ('gear-hammer','Bonk Hammer','gear',500,null,false,false,'{"kind":"hammer","color":"#f97316"}','The official bonking tool.'),
 ('gear-balloon','Red Balloon','gear',40,null,false,false,'{"kind":"balloon","color":"#ef4444"}','Do not let go.'),
 ('gear-wand','Magic Wand','gear',700,null,false,false,'{"kind":"wand","color":"#a855f7"}','Sparkles included.'),
 ('gear-pizza','Pizza Slice','gear',60,null,false,false,'{"kind":"pizza","color":"#facc15"}','Snack time.')
on conflict (slug) do nothing;

-- =====================================================================
-- DONE. Make yourself admin after you sign up in the app:
--   update public.bb_profiles set role = 'admin', verified = true where username = 'YOUR_USERNAME';
-- =====================================================================
