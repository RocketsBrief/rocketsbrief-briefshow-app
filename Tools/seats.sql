-- BriefShow — "one email, one computer", with per-email exceptions.
--
-- Run this ONCE in the Supabase SQL editor (project gzbkpnogeegyntoznzzn),
-- BEFORE locking the app from the BriefControl settings page. Until it
-- exists the app fails open: every RPC 404s, every heartbeat returns
-- "we don't know", and nobody is ever signed out. That is deliberate — it
-- means running this file is what switches the rule on, and there is no
-- window where a client is locked out by a half-finished setup.
--
-- The count lives HERE, not in the app. Raising a client from 1 computer
-- to 3 is one UPDATE on briefshow_seat_limits, with no app release.

-- ---------------------------------------------------------------------
-- 1. Which Macs currently hold a seat
-- ---------------------------------------------------------------------

create table if not exists public.briefshow_seats (
  user_id      uuid        not null references auth.users(id) on delete cascade,
  device_id    text        not null,
  email        text,
  device_name  text,
  app_version  text,
  claimed_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

create index if not exists briefshow_seats_email_idx on public.briefshow_seats (email);

-- RLS on, and DELIBERATELY no policies: the two functions below are
-- SECURITY DEFINER and bypass RLS, so this table is reachable only
-- through them. A client with the anon key cannot read other people's
-- seats, and — the point of the whole exercise — cannot delete its own
-- eviction to keep a seat it lost.
alter table public.briefshow_seats enable row level security;

-- ---------------------------------------------------------------------
-- 2. Per-email exceptions (everyone else gets 1)
-- ---------------------------------------------------------------------

create table if not exists public.briefshow_seat_limits (
  email        text primary key,
  device_limit int  not null default 1 check (device_limit >= 1),
  note         text,
  updated_at   timestamptz not null default now()
);

alter table public.briefshow_seat_limits enable row level security;

insert into public.briefshow_seat_limits (email, device_limit, note)
values ('vuk@vista-photography.com', 22, 'Vista Photography — 22 computers on one account')
on conflict (email) do update
  set device_limit = excluded.device_limit,
      note         = excluded.note,
      updated_at   = now();

-- ---------------------------------------------------------------------
-- 3. Claim / verify a seat
-- ---------------------------------------------------------------------
--
-- p_claim = true  -> sign-in: take a seat, evicting the OLDEST claim if
--                    this email is already at its limit. Newest wins, so
--                    the computer the client is sitting at is the one
--                    that keeps working.
-- p_claim = false -> heartbeat: just "do I still have my seat?", plus a
--                    last_seen_at touch for the admin panel.
--
-- Returns ok=false ONLY when this Mac genuinely has no seat. The app
-- signs out on exactly that and on nothing else.

create or replace function public.briefshow_seat_heartbeat(
  p_device_id   text,
  p_device_name text default null,
  p_app_version text default null,
  p_claim       boolean default false
)
returns json
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user   uuid := auth.uid();
  v_email  text;
  v_limit  int;
  v_active boolean;
begin
  if v_user is null or coalesce(p_device_id, '') = '' then
    return json_build_object('ok', true, 'reason', 'no_session');
  end if;

  select lower(u.email) into v_email from auth.users u where u.id = v_user;

  select coalesce(l.device_limit, 1) into v_limit
    from public.briefshow_seat_limits l
   where lower(l.email) = v_email;

  v_limit := coalesce(v_limit, 1);

  if p_claim then
    insert into public.briefshow_seats
      (user_id, device_id, email, device_name, app_version, claimed_at, last_seen_at)
    values
      (v_user, p_device_id, v_email, p_device_name, p_app_version, now(), now())
    on conflict (user_id, device_id) do update
      set claimed_at   = now(),
          last_seen_at = now(),
          email        = excluded.email,
          device_name  = coalesce(excluded.device_name, briefshow_seats.device_name),
          app_version  = coalesce(excluded.app_version, briefshow_seats.app_version);

    -- Keep the v_limit newest claims, drop the rest. The device_id tie
    -- break keeps this deterministic when two Macs claim in the same
    -- millisecond, which is otherwise a way for both to survive a limit
    -- of 1.
    delete from public.briefshow_seats s
     where s.user_id = v_user
       and s.device_id not in (
         select device_id
           from public.briefshow_seats
          where user_id = v_user
          order by claimed_at desc, device_id desc
          limit v_limit
       );
  else
    update public.briefshow_seats
       set last_seen_at = now(),
           app_version  = coalesce(p_app_version, app_version),
           device_name  = coalesce(p_device_name, device_name)
     where user_id = v_user and device_id = p_device_id;

    -- No row for this Mac. That is NOT automatically an eviction, and
    -- treating it as one would have signed out every client who was
    -- already signed in before this file existed: their session is in
    -- the Keychain, they never signed in again, so they never claimed.
    -- An unclaimed seat is a free seat — take it. ok=false is reserved
    -- for the one case that actually means something: the account is
    -- full and this Mac is not one of the holders.
    if not found
       and (select count(*) from public.briefshow_seats where user_id = v_user) < v_limit
    then
      insert into public.briefshow_seats
        (user_id, device_id, email, device_name, app_version, claimed_at, last_seen_at)
      values
        (v_user, p_device_id, v_email, p_device_name, p_app_version, now(), now())
      on conflict (user_id, device_id) do update
        set last_seen_at = now();
    end if;
  end if;

  select exists(
    select 1 from public.briefshow_seats
     where user_id = v_user and device_id = p_device_id
  ) into v_active;

  return json_build_object(
    'ok',           v_active,
    'reason',       case when v_active then 'active' else 'seat_taken' end,
    'device_limit', v_limit,
    'seats_used',   (select count(*) from public.briefshow_seats where user_id = v_user)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Hand a seat back on an explicit sign-out
-- ---------------------------------------------------------------------

create or replace function public.briefshow_seat_release(p_device_id text)
returns json
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return json_build_object('ok', true);
  end if;

  delete from public.briefshow_seats
   where user_id = v_user and device_id = p_device_id;

  return json_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Only a signed-in client may call these
-- ---------------------------------------------------------------------

revoke all on function public.briefshow_seat_heartbeat(text, text, text, boolean) from public, anon;
revoke all on function public.briefshow_seat_release(text) from public, anon;

grant execute on function public.briefshow_seat_heartbeat(text, text, text, boolean) to authenticated;
grant execute on function public.briefshow_seat_release(text) to authenticated;

-- ---------------------------------------------------------------------
-- Everyday admin, for the BriefControl page
-- ---------------------------------------------------------------------
--
-- Give someone extra computers:
--   insert into public.briefshow_seat_limits (email, device_limit, note)
--   values ('someone@example.com', 3, 'why')
--   on conflict (email) do update
--     set device_limit = excluded.device_limit, updated_at = now();
--
-- Put someone back to one computer:
--   delete from public.briefshow_seat_limits where email = 'someone@example.com';
--   delete from public.briefshow_seats where email = 'someone@example.com';
--   -- (the second line frees the Macs; they sign back in one at a time)
--
-- Free up a stuck Mac (client lost/sold a computer):
--   delete from public.briefshow_seats where email = 'someone@example.com';
--
-- Who is using what:
--   select email, device_name, app_version, claimed_at, last_seen_at
--     from public.briefshow_seats
--    order by email, claimed_at desc;
