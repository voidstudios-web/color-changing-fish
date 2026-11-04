-- =====================================================================
-- BLOCKHUB  -  finish setup (steps 2 and 3)
-- Step 1 (all bh_ tables) is already applied to this project.
-- Paste this whole file into Supabase > SQL Editor > Run, once.
-- It only creates or changes bh_ objects. Other apps are not touched.
-- =====================================================================

-- =====================================================================
-- HELPERS
-- =====================================================================
create or replace function public.bh_is_admin(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from bh_profiles where id = p), false)
$$;

create or replace function public.bh_is_plus(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select plus_until > now() from bh_profiles where id = p), false)
$$;

create or replace function public.bh_are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from bh_friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  )
$$;

-- The ONLY place Bux balances change.
create or replace function public.bh_credit(p_user uuid, p_delta bigint, p_reason text, p_ref text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  update bh_wallets set bux = bux + p_delta, updated_at = now()
   where user_id = p_user and bux + p_delta >= 0
  returning bux into v;
  if not found then
    if exists (select 1 from bh_wallets where user_id = p_user) then
      raise exception 'Not enough Bux';
    end if;
    raise exception 'Wallet not found';
  end if;
  insert into bh_bux_ledger (user_id, delta, reason, ref) values (p_user, p_delta, p_reason, p_ref);
  return v;
end $$;

create or replace function public.bh_require_user() returns uuid
language plpgsql stable as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  return auth.uid();
end $$;

-- =====================================================================
-- NEW USER SIGNUP
-- =====================================================================
create or replace function public.bh_create_profile(p_id uuid, p_base text) returns void
language plpgsql security definer set search_path = public as $$
declare base text; uname text; code text;
begin
  base := regexp_replace(coalesce(p_base, ''), '[^A-Za-z0-9_]', '', 'g');
  if char_length(base) < 3 then base := 'Player'; end if;
  base := left(base, 20);
  uname := base;
  while exists (select 1 from bh_profiles where lower(username) = lower(uname)) loop
    uname := left(base, 15) || floor(random() * 100000)::int;
  end loop;
  loop
    code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from bh_profiles where referral_code = code);
  end loop;
  insert into bh_profiles (id, username, referral_code) values (p_id, uname, code);
  insert into bh_profile_private (user_id) values (p_id);
  insert into bh_wallets (user_id, bux) values (p_id, 0);
  perform bh_credit(p_id, 50, 'welcome bonus');
end $$;

create or replace function public.bh_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Never let a Blockhub problem block signups for other apps in this project.
  begin
    perform bh_create_profile(new.id, new.raw_user_meta_data->>'username');
  exception when others then
    raise warning 'bh_handle_new_user failed for %: %', new.id, sqlerrm;
  end;
  return new;
end $$;

create trigger bh_on_auth_user_created
  after insert on auth.users
  for each row execute function public.bh_handle_new_user();

-- =====================================================================
-- PLAY REWARDS
-- =====================================================================
create or replace function public.bh_submit_score(p_game text, p_score int, p_duration int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := bh_require_user();
  g bh_games;
  v_reward int := 0;
  cap int;
  today_total int;
  last_at timestamptz;
  rewarded_plays int;
  r bh_referrals;
begin
  select * into g from bh_games where id = p_game and id <> 'community';
  if not found then raise exception 'Unknown game'; end if;
  if p_score < 0 or p_score > g.max_score then raise exception 'Invalid score'; end if;

  select max(created_at) into last_at from bh_game_plays where user_id = uid and reward > 0;

  if coalesce(p_duration, 0) >= 15 and (last_at is null or last_at < now() - interval '30 seconds') then
    v_reward := least(25, 2 + p_score / g.divisor);
    if bh_is_plus(uid) then v_reward := v_reward * 2; cap := 600; else cap := 300; end if;
    select coalesce(sum(gp.reward), 0) into today_total
      from bh_game_plays gp where gp.user_id = uid and gp.created_at > date_trunc('day', now());
    v_reward := greatest(0, least(v_reward, cap - today_total));
  end if;

  insert into bh_game_plays (user_id, game_id, score, reward) values (uid, p_game, p_score, v_reward);
  if v_reward > 0 then perform bh_credit(uid, v_reward, 'play', p_game); end if;

  -- Referral payout: referrer earns once the new player has 3 rewarded plays.
  select * into r from bh_referrals where referee = uid and not rewarded;
  if found then
    select count(*) into rewarded_plays from bh_game_plays where user_id = uid and reward > 0;
    if rewarded_plays >= 3 then
      update bh_referrals set rewarded = true where referee = uid;
      if (select count(*) from bh_referrals where referrer = r.referrer and rewarded) <= 50 then
        perform bh_credit(r.referrer, 200, 'referral reward', uid::text);
      end if;
    end if;
  end if;

  return jsonb_build_object('reward', v_reward, 'balance', (select bux from bh_wallets where user_id = uid));
end $$;

create or replace function public.bh_leaderboard(p_game text)
returns table (username text, verified boolean, best int)
language sql stable security definer set search_path = public as $$
  select p.username, p.verified, max(gp.score)::int as best
  from bh_game_plays gp join bh_profiles p on p.id = gp.user_id
  where gp.game_id = p_game
  group by p.username, p.verified
  order by best desc
  limit 10
$$;

-- Community game finished. Rewards the player (shared cap with built-in bh_games)
-- and pays the creator 1 Bux per unique player per hour (max 100/day).
create or replace function public.bh_submit_community_play(p_game uuid, p_score int, p_duration int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := bh_require_user();
  cg bh_community_games;
  v_reward int := 0;
  cap int;
  today_total int;
  last_at timestamptz;
  creator_today int;
begin
  select * into cg from bh_community_games where id = p_game and published;
  if not found then raise exception 'Game not found'; end if;
  if p_score < 0 or p_score > 100000 then raise exception 'Invalid score'; end if;

  if not exists (select 1 from bh_community_plays where game_id = p_game and player = uid and at > now() - interval '1 hour') then
    insert into bh_community_plays (game_id, player) values (p_game, uid);
    update bh_community_games set plays = plays + 1 where id = p_game;
    if cg.creator <> uid then
      select coalesce(sum(delta), 0) into creator_today from bh_bux_ledger
        where user_id = cg.creator and reason = 'creator play' and created_at > date_trunc('day', now());
      if creator_today < 100 then perform bh_credit(cg.creator, 1, 'creator play', p_game::text); end if;
    end if;
  end if;

  select max(created_at) into last_at from bh_game_plays where user_id = uid and reward > 0;
  if cg.creator <> uid and coalesce(p_duration, 0) >= 15
     and (last_at is null or last_at < now() - interval '30 seconds') then
    v_reward := least(15, 2 + p_score / 100);
    if bh_is_plus(uid) then v_reward := v_reward * 2; cap := 600; else cap := 300; end if;
    select coalesce(sum(gp.reward), 0) into today_total
      from bh_game_plays gp where gp.user_id = uid and gp.created_at > date_trunc('day', now());
    v_reward := greatest(0, least(v_reward, cap - today_total));
  end if;

  insert into bh_game_plays (user_id, game_id, ref_id, score, reward) values (uid, 'community', p_game, p_score, v_reward);
  if v_reward > 0 then perform bh_credit(uid, v_reward, 'play', 'community'); end if;
  return jsonb_build_object('reward', v_reward, 'balance', (select bux from bh_wallets where user_id = uid));
end $$;

-- =====================================================================
-- SHOP
-- =====================================================================
create or replace function public.bh_buy_shop_item(p_item text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); it bh_shop_items; v bigint;
begin
  select * into it from bh_shop_items where id = p_item and active;
  if not found then raise exception 'Item not found'; end if;
  if it.plus_only and not bh_is_plus(uid) then raise exception 'Plus members only'; end if;
  if exists (select 1 from bh_inventory where user_id = uid and item_id = p_item) then
    raise exception 'You already own this';
  end if;
  v := bh_credit(uid, -it.price, 'shop', p_item);
  insert into bh_inventory (user_id, item_id, source) values (uid, p_item, 'shop');
  return v;
end $$;

create or replace function public.bh_equip_item(p_item text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); k text; e jsonb;
begin
  select s.kind into k from bh_inventory i join bh_shop_items s on s.id = i.item_id
   where i.user_id = uid and i.item_id = p_item;
  if k is null then raise exception 'You do not own this item'; end if;
  update bh_profiles set equipped = equipped || jsonb_build_object(k, p_item) where id = uid returning equipped into e;
  return e;
end $$;

create or replace function public.bh_unequip_item(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); e jsonb;
begin
  update bh_profiles set equipped = equipped - p_kind where id = uid returning equipped into e;
  return e;
end $$;

-- =====================================================================
-- GIFT CODES
-- =====================================================================
create or replace function public.bh_new_gift_code() returns text
language plpgsql as $$
declare raw text;
begin
  raw := upper(replace(gen_random_uuid()::text, '-', ''));
  return 'BUX-' || substr(raw, 1, 4) || '-' || substr(raw, 5, 4) || '-' || substr(raw, 9, 4) || '-' || substr(raw, 13, 4);
end $$;

create or replace function public.bh_redeem_gift_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); c bh_gift_codes; fails int; v bigint;
begin
  select count(*) into fails from bh_redeem_attempts where user_id = uid and not success and at > now() - interval '1 hour';
  if fails >= 10 then
    return jsonb_build_object('ok', false, 'error', 'Too many tries. Wait an hour.');
  end if;
  select * into c from bh_gift_codes where code = upper(trim(p_code)) for update;
  if not found or c.redeemed_by is not null then
    insert into bh_redeem_attempts (user_id, success) values (uid, false);
    return jsonb_build_object('ok', false, 'error', 'That code is invalid or already used.');
  end if;
  update bh_gift_codes set redeemed_by = uid, redeemed_at = now() where code = c.code;
  insert into bh_redeem_attempts (user_id, success) values (uid, true);
  v := bh_credit(uid, c.bux, 'gift code', c.code);
  return jsonb_build_object('ok', true, 'bux', c.bux, 'balance', v);
end $$;

create or replace function public.bh_admin_create_gift_codes(p_count int, p_bux int)
returns setof text language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); i int; code text;
begin
  if not bh_is_admin(uid) then raise exception 'Admins only'; end if;
  if p_count < 1 or p_count > 100 then raise exception 'Count must be 1-100'; end if;
  for i in 1..p_count loop
    code := bh_new_gift_code();
    insert into bh_gift_codes (code, bux, created_by) values (code, p_bux, uid);
    return next code;
  end loop;
end $$;

-- =====================================================================
-- PLUS
-- =====================================================================
create or replace function public.bh_claim_plus_stipend()
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); last_at timestamptz; v bigint;
begin
  if not bh_is_plus(uid) then raise exception 'Plus members only'; end if;
  select last_stipend_at into last_at from bh_profiles where id = uid for update;
  if last_at is not null and last_at > now() - interval '30 days' then
    raise exception 'Next stipend unlocks on %', to_char(last_at + interval '30 days', 'Mon DD');
  end if;
  update bh_profiles set last_stipend_at = now() where id = uid;
  v := bh_credit(uid, 500, 'plus stipend');
  return v;
end $$;

-- =====================================================================
-- REFERRALS
-- =====================================================================
create or replace function public.bh_apply_referral(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); ref_id uuid; joined timestamptz; v bigint;
begin
  if exists (select 1 from bh_referrals where referee = uid) then raise exception 'You already used an invite code'; end if;
  select created_at into joined from bh_profiles where id = uid;
  if joined < now() - interval '7 days' then raise exception 'Invite codes only work in your first 7 days'; end if;
  select id into ref_id from bh_profiles where referral_code = upper(trim(p_code));
  if ref_id is null then raise exception 'Invite code not found'; end if;
  if ref_id = uid then raise exception 'You cannot use your own code'; end if;
  if exists (select 1 from bh_referrals where referee = ref_id and referrer = uid) then
    raise exception 'You cannot refer each other';
  end if;
  insert into bh_referrals (referee, referrer) values (uid, ref_id);
  v := bh_credit(uid, 100, 'invite bonus', ref_id::text);
  return jsonb_build_object('bonus', 100, 'balance', v);
end $$;

create or replace function public.bh_my_referral_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'invited',  (select count(*) from bh_referrals where referrer = auth.uid()),
    'rewarded', (select count(*) from bh_referrals where referrer = auth.uid() and rewarded),
    'used_code',(select exists (select 1 from bh_referrals where referee = auth.uid()))
  )
$$;

-- =====================================================================
-- SOCIAL FUNCTIONS
-- =====================================================================
create or replace function public.bh_send_friend_request(p_target uuid)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user();
begin
  if p_target = uid then raise exception 'That is you'; end if;
  if not exists (select 1 from bh_profiles where id = p_target) then raise exception 'User not found'; end if;
  if bh_are_friends(uid, p_target) then return 'friends'; end if;
  if exists (select 1 from bh_friendships where requester = p_target and addressee = uid) then
    update bh_friendships set status = 'accepted' where requester = p_target and addressee = uid;
    return 'friends';
  end if;
  insert into bh_friendships (requester, addressee) values (uid, p_target) on conflict do nothing;
  return 'pending';
end $$;

create or replace function public.bh_respond_friend_request(p_from uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user();
begin
  if p_accept then
    update bh_friendships set status = 'accepted' where requester = p_from and addressee = uid and status = 'pending';
    return 'friends';
  end if;
  delete from bh_friendships where requester = p_from and addressee = uid and status = 'pending';
  return 'declined';
end $$;

create or replace function public.bh_remove_friend(p_other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user();
begin
  delete from bh_friendships where (requester = uid and addressee = p_other) or (requester = p_other and addressee = uid);
end $$;

-- =====================================================================
-- MARKETPLACE FUNCTIONS
-- =====================================================================
create or replace function public.bh_create_listing(
  p_title text, p_description text, p_price_cents int, p_image_url text, p_stock int, p_delivery text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); lid uuid;
begin
  if not coalesce((select charges_enabled from bh_profile_private where user_id = uid), false) then
    raise exception 'Finish Stripe seller setup first';
  end if;
  if (select count(*) from bh_market_listings where seller = uid and status = 'pending') >= 5 then
    raise exception 'You have 5 listings waiting for review already';
  end if;
  insert into bh_market_listings (seller, title, description, price_cents, image_url, stock)
  values (uid, trim(p_title), trim(p_description), p_price_cents, nullif(trim(p_image_url), ''), greatest(1, least(p_stock, 999)))
  returning id into lid;
  insert into bh_market_listing_secrets (listing_id, delivery) values (lid, trim(p_delivery));
  return lid;
end $$;

create or replace function public.bh_remove_listing(p_listing uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user();
begin
  update bh_market_listings set status = 'removed'
   where id = p_listing and (seller = uid or bh_is_admin(uid));
  if not found then raise exception 'Listing not found'; end if;
end $$;

create or replace function public.bh_admin_review_listing(p_listing uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user();
begin
  if not bh_is_admin(uid) then raise exception 'Admins only'; end if;
  update bh_market_listings
     set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then null else p_reason end,
         reviewed_at = now()
   where id = p_listing and status = 'pending';
  if not found then raise exception 'Listing is not pending'; end if;
end $$;

create or replace function public.bh_get_order_delivery(p_order uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare uid uuid := bh_require_user(); d text;
begin
  select s.delivery into d
    from bh_market_orders o join bh_market_listing_secrets s on s.listing_id = o.listing_id
   where o.id = p_order and o.buyer = uid and o.status = 'paid';
  if d is null then raise exception 'Order not found or not paid'; end if;
  return d;
end $$;

create or replace function public.bh_submit_seller_review(p_order uuid, p_rating int, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); o bh_market_orders;
begin
  select * into o from bh_market_orders where id = p_order and buyer = uid and status = 'paid';
  if not found then raise exception 'You can only review paid orders'; end if;
  insert into bh_seller_reviews (order_id, seller, reviewer, rating, body)
  values (p_order, o.seller, uid, p_rating, nullif(trim(p_body), ''));
exception when unique_violation then
  raise exception 'You already reviewed this order';
end $$;

-- =====================================================================
-- ADMIN
-- =====================================================================
create or replace function public.bh_admin_set_verified(p_username text, p_value boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user();
begin
  if not bh_is_admin(uid) then raise exception 'Admins only'; end if;
  update bh_profiles set verified = p_value where lower(username) = lower(p_username);
  if not found then raise exception 'User not found'; end if;
end $$;

create or replace function public.bh_admin_adjust_bux(p_username text, p_delta bigint, p_reason text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := bh_require_user(); target uuid;
begin
  if not bh_is_admin(uid) then raise exception 'Admins only'; end if;
  select id into target from bh_profiles where lower(username) = lower(p_username);
  if target is null then raise exception 'User not found'; end if;
  return bh_credit(target, p_delta, 'admin: ' || coalesce(p_reason, ''), uid::text);
end $$;

create or replace function public.bh_admin_pin_post(p_post bigint, p_pinned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not bh_is_admin(bh_require_user()) then raise exception 'Admins only'; end if;
  update bh_forum_posts set pinned = p_pinned where id = p_post;
end $$;

-- =====================================================================
-- SERVICE-ROLE FUNCTIONS (called by Stripe edge functions only)
-- =====================================================================
create or replace function public.bh_svc_set_customer(p_user uuid, p_customer text)
returns void language sql security definer set search_path = public as $$
  update bh_profile_private set stripe_customer_id = p_customer where user_id = p_user;
$$;

create or replace function public.bh_svc_set_plus(p_user uuid, p_until timestamptz)
returns void language sql security definer set search_path = public as $$
  update bh_profiles set plus_until = p_until where id = p_user;
$$;

create or replace function public.bh_svc_set_plus_by_customer(p_customer text, p_until timestamptz)
returns void language sql security definer set search_path = public as $$
  update bh_profiles set plus_until = p_until
   where id = (select user_id from bh_profile_private where stripe_customer_id = p_customer);
$$;

create or replace function public.bh_svc_issue_bux_code(p_user uuid, p_bux int, p_session text)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  select code into c from bh_gift_codes where stripe_session = p_session;
  if c is not null then return c; end if;
  c := bh_new_gift_code();
  insert into bh_gift_codes (code, bux, purchased_by, stripe_session) values (c, p_bux, p_user, p_session);
  return c;
end $$;

create or replace function public.bh_svc_set_connect_account(p_user uuid, p_account text)
returns void language sql security definer set search_path = public as $$
  update bh_profile_private set stripe_account_id = p_account where user_id = p_user;
$$;

create or replace function public.bh_svc_update_connect_status(p_account text, p_charges boolean, p_payouts boolean)
returns void language sql security definer set search_path = public as $$
  update bh_profile_private set charges_enabled = p_charges, payouts_enabled = p_payouts
   where stripe_account_id = p_account;
$$;

create or replace function public.bh_svc_create_order(p_listing uuid, p_buyer uuid, p_fee_pct numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l bh_market_listings; acct text; ok boolean; oid uuid; fee int;
begin
  select * into l from bh_market_listings where id = p_listing for update;
  if not found or l.status <> 'approved' then raise exception 'Listing is not for sale'; end if;
  if l.stock < 1 then raise exception 'Sold out'; end if;
  if l.seller = p_buyer then raise exception 'You cannot buy your own listing'; end if;
  select stripe_account_id, charges_enabled into acct, ok from bh_profile_private where user_id = l.seller;
  if acct is null or not ok then raise exception 'Seller cannot take payments right now'; end if;
  fee := round(l.price_cents * p_fee_pct)::int;
  insert into bh_market_orders (listing_id, buyer, seller, amount_cents, fee_cents)
  values (l.id, p_buyer, l.seller, l.price_cents, fee) returning id into oid;
  return jsonb_build_object('order_id', oid, 'amount', l.price_cents, 'fee', fee,
                            'title', l.title, 'destination', acct, 'image', l.image_url);
end $$;

create or replace function public.bh_svc_attach_session(p_order uuid, p_session text)
returns void language sql security definer set search_path = public as $$
  update bh_market_orders set stripe_session_id = p_session where id = p_order;
$$;

create or replace function public.bh_svc_mark_order_paid(p_session text, p_payment_intent text)
returns void language plpgsql security definer set search_path = public as $$
declare o bh_market_orders;
begin
  update bh_market_orders set status = 'paid', paid_at = now(), payment_intent = p_payment_intent
   where stripe_session_id = p_session and status in ('pending','expired')
  returning * into o;
  if not found then return; end if;  -- already handled
  update bh_market_listings
     set stock = greatest(stock - 1, 0),
         status = case when stock - 1 <= 0 then 'sold_out' else status end
   where id = o.listing_id;
end $$;

create or replace function public.bh_svc_expire_order(p_session text)
returns void language sql security definer set search_path = public as $$
  update bh_market_orders set status = 'expired' where stripe_session_id = p_session and status = 'pending';
$$;

create or replace function public.bh_svc_mark_order_refunded(p_payment_intent text)
returns void language sql security definer set search_path = public as $$
  update bh_market_orders set status = 'refunded' where payment_intent = p_payment_intent and status = 'paid';
$$;

-- =====================================================================
-- KEEPALIVE
-- =====================================================================
create or replace function public.bh_keepalive()
returns timestamptz language sql security definer set search_path = public as $$
  update bh_keepalive set pinged_at = now(), pings = pings + 1 where id = 1 returning pinged_at;
$$;

-- =====================================================================
-- FORUM TRIGGERS (reply counts + basic spam limit)
-- =====================================================================
create or replace function public.bh_forum_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'bh_forum_posts' then
    if (select count(*) from bh_forum_posts where author = new.author and created_at > now() - interval '10 minutes') >= 5 then
      raise exception 'Slow down. Max 5 posts per 10 minutes.';
    end if;
  else
    if (select count(*) from bh_forum_replies where author = new.author and created_at > now() - interval '1 minute') >= 5 then
      raise exception 'Slow down. Max 5 replies per minute.';
    end if;
  end if;
  return new;
end $$;
create trigger bh_forum_posts_rate before insert on public.bh_forum_posts for each row execute function public.bh_forum_rate_limit();
create trigger bh_forum_replies_rate before insert on public.bh_forum_replies for each row execute function public.bh_forum_rate_limit();

create or replace function public.bh_forum_reply_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update bh_forum_posts set reply_count = reply_count + 1, last_activity = now() where id = new.post_id;
  else
    update bh_forum_posts set reply_count = greatest(reply_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end $$;
create trigger bh_forum_replies_count after insert or delete on public.bh_forum_replies
  for each row execute function public.bh_forum_reply_count();

create or replace function public.bh_touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger bh_community_games_touch before update on public.bh_community_games
  for each row execute function public.bh_touch_updated_at();

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.bh_profiles               enable row level security;
alter table public.bh_profile_private        enable row level security;
alter table public.bh_wallets                enable row level security;
alter table public.bh_bux_ledger             enable row level security;
alter table public.bh_games                  enable row level security;
alter table public.bh_game_plays             enable row level security;
alter table public.bh_community_games        enable row level security;
alter table public.bh_community_plays        enable row level security;
alter table public.bh_friendships            enable row level security;
alter table public.bh_follows                enable row level security;
alter table public.bh_messages               enable row level security;
alter table public.bh_forum_posts            enable row level security;
alter table public.bh_forum_replies          enable row level security;
alter table public.bh_shop_items             enable row level security;
alter table public.bh_inventory              enable row level security;
alter table public.bh_gift_codes             enable row level security;
alter table public.bh_redeem_attempts        enable row level security;
alter table public.bh_referrals              enable row level security;
alter table public.bh_market_listings        enable row level security;
alter table public.bh_market_listing_secrets enable row level security;
alter table public.bh_market_orders          enable row level security;
alter table public.bh_seller_reviews         enable row level security;
alter table public.bh_keepalive              enable row level security;

-- bh_profiles: public read, owner edits a few columns
create policy "bh_profiles readable" on public.bh_profiles for select using (true);
create policy "bh_profiles own update" on public.bh_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "private own read" on public.bh_profile_private for select to authenticated using (user_id = auth.uid());
create policy "wallet own read"  on public.bh_wallets         for select to authenticated using (user_id = auth.uid());
create policy "ledger own read"  on public.bh_bux_ledger      for select to authenticated using (user_id = auth.uid());
create policy "bh_games readable"   on public.bh_games           for select using (true);
create policy "plays own read"   on public.bh_game_plays      for select to authenticated using (user_id = auth.uid());

create policy "cg read" on public.bh_community_games for select
  using (published or creator = auth.uid());
create policy "cg insert" on public.bh_community_games for insert to authenticated
  with check (creator = auth.uid());
create policy "cg update" on public.bh_community_games for update to authenticated
  using (creator = auth.uid()) with check (creator = auth.uid());
create policy "cg delete" on public.bh_community_games for delete to authenticated
  using (creator = auth.uid() or public.bh_is_admin(auth.uid()));

create policy "bh_friendships own read" on public.bh_friendships for select to authenticated
  using (auth.uid() in (requester, addressee));

create policy "bh_follows readable" on public.bh_follows for select using (true);
create policy "follow self" on public.bh_follows for insert to authenticated with check (follower = auth.uid());
create policy "unfollow self" on public.bh_follows for delete to authenticated using (follower = auth.uid());

create policy "bh_messages own read" on public.bh_messages for select to authenticated
  using (auth.uid() in (sender, recipient));
create policy "bh_messages send to friends" on public.bh_messages for insert to authenticated
  with check (sender = auth.uid() and public.bh_are_friends(sender, recipient));
create policy "bh_messages mark read" on public.bh_messages for update to authenticated
  using (recipient = auth.uid()) with check (recipient = auth.uid());

create policy "posts readable" on public.bh_forum_posts for select using (true);
create policy "posts insert" on public.bh_forum_posts for insert to authenticated with check (author = auth.uid());
create policy "posts update" on public.bh_forum_posts for update to authenticated
  using (author = auth.uid()) with check (author = auth.uid());
create policy "posts delete" on public.bh_forum_posts for delete to authenticated
  using (author = auth.uid() or public.bh_is_admin(auth.uid()));

create policy "replies readable" on public.bh_forum_replies for select using (true);
create policy "replies insert" on public.bh_forum_replies for insert to authenticated with check (author = auth.uid());
create policy "replies delete" on public.bh_forum_replies for delete to authenticated
  using (author = auth.uid() or public.bh_is_admin(auth.uid()));

create policy "shop readable" on public.bh_shop_items for select using (true);
create policy "bh_inventory readable" on public.bh_inventory for select using (true);

create policy "gift codes own" on public.bh_gift_codes for select to authenticated
  using (purchased_by = auth.uid() or public.bh_is_admin(auth.uid()));

create policy "bh_referrals own" on public.bh_referrals for select to authenticated
  using (auth.uid() in (referee, referrer));

create policy "listings read" on public.bh_market_listings for select
  using (status = 'approved' or seller = auth.uid() or public.bh_is_admin(auth.uid()));
create policy "listing secret seller" on public.bh_market_listing_secrets for select to authenticated
  using (exists (select 1 from public.bh_market_listings l where l.id = listing_id and l.seller = auth.uid()));
create policy "orders own" on public.bh_market_orders for select to authenticated
  using (auth.uid() in (buyer, seller) or public.bh_is_admin(auth.uid()));
create policy "reviews readable" on public.bh_seller_reviews for select using (true);
-- bh_redeem_attempts, bh_keepalive, bh_community_plays: no policies, functions only.

-- =====================================================================
-- COLUMN-LEVEL GRANTS
-- Supabase grants full table rights to anon/authenticated by default.
-- Lock down every write, then re-open only safe columns.
-- =====================================================================
-- Only Blockhub (bh_) tables. Other apps in this project are not touched.
do $$ declare r record; begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relname like 'bh\_%' and c.relkind in ('r','v') loop
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', r.relname);
  end loop;
end $$;

grant update (username, display_name, bio, avatar) on public.bh_profiles to authenticated;
grant insert, delete on public.bh_follows to authenticated;
grant insert (sender, recipient, body) on public.bh_messages to authenticated;
grant update (read_at) on public.bh_messages to authenticated;
grant insert (author, category, title, body) on public.bh_forum_posts to authenticated;
grant update (title, body) on public.bh_forum_posts to authenticated;
grant delete on public.bh_forum_posts to authenticated;
grant insert (post_id, author, body) on public.bh_forum_replies to authenticated;
grant delete on public.bh_forum_replies to authenticated;
grant insert (creator, title, description, level, theme, published) on public.bh_community_games to authenticated;
grant update (title, description, level, theme, published) on public.bh_community_games to authenticated;
grant delete on public.bh_community_games to authenticated;

-- =====================================================================
-- FUNCTION GRANTS
-- Supabase lets anon/authenticated execute every new function by default.
-- Revoke all, then grant exactly what the app needs.
-- =====================================================================
-- Only Blockhub (bh_) functions. Other apps in this project are not touched.
do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'bh\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.bh_is_admin(uuid), public.bh_is_plus(uuid), public.bh_are_friends(uuid, uuid)
  to anon, authenticated;
grant execute on function public.bh_leaderboard(text) to anon, authenticated;
grant execute on function public.bh_keepalive() to anon, authenticated;

grant execute on function
  public.bh_submit_score(text, int, int),
  public.bh_submit_community_play(uuid, int, int),
  public.bh_buy_shop_item(text),
  public.bh_equip_item(text),
  public.bh_unequip_item(text),
  public.bh_redeem_gift_code(text),
  public.bh_admin_create_gift_codes(int, int),
  public.bh_claim_plus_stipend(),
  public.bh_apply_referral(text),
  public.bh_my_referral_stats(),
  public.bh_send_friend_request(uuid),
  public.bh_respond_friend_request(uuid, boolean),
  public.bh_remove_friend(uuid),
  public.bh_create_listing(text, text, int, text, int, text),
  public.bh_remove_listing(uuid),
  public.bh_admin_review_listing(uuid, boolean, text),
  public.bh_get_order_delivery(uuid),
  public.bh_submit_seller_review(uuid, int, text),
  public.bh_admin_set_verified(text, boolean),
  public.bh_admin_adjust_bux(text, bigint, text),
  public.bh_admin_pin_post(bigint, boolean)
to authenticated;

grant execute on function
  public.bh_svc_set_customer(uuid, text),
  public.bh_svc_set_plus(uuid, timestamptz),
  public.bh_svc_set_plus_by_customer(text, timestamptz),
  public.bh_svc_issue_bux_code(uuid, int, text),
  public.bh_svc_set_connect_account(uuid, text),
  public.bh_svc_update_connect_status(text, boolean, boolean),
  public.bh_svc_create_order(uuid, uuid, numeric),
  public.bh_svc_attach_session(uuid, text),
  public.bh_svc_mark_order_paid(text, text),
  public.bh_svc_expire_order(text),
  public.bh_svc_mark_order_refunded(text)
to service_role;


-- =====================================================================
-- BACKFILL: give every existing auth user a Blockhub profile + wallet.
-- Reuses their username from public.profiles when that table exists.
-- =====================================================================
do $$ declare u record; uname text; begin
  for u in select id, raw_user_meta_data from auth.users
           where id not in (select id from public.bh_profiles) loop
    uname := u.raw_user_meta_data->>'username';
    if to_regclass('public.profiles') is not null then
      begin
        execute 'select username from public.profiles where id = $1' into uname using u.id;
      exception when others then null;
      end;
      uname := coalesce(uname, u.raw_user_meta_data->>'username');
    end if;
    perform public.bh_create_profile(u.id, uname);
  end loop;
end $$;

-- =====================================================================
-- REALTIME
-- =====================================================================
alter publication supabase_realtime add table public.bh_messages, public.bh_wallets, public.bh_friendships;
