-- C4S Suite performance diagnostics — see BriefShow/Diagnostics.swift.
-- RocketsBrief project (gzbkpnogeegyntoznzzn). Run once in the SQL editor.
--
-- The app writes with the ANON key and can only INSERT: no select, update or
-- delete for anon/authenticated. Rows are read from the dashboard (postgres).

create table if not exists public.briefshow_diagnostics (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  received_at   timestamptz not null default now(),
  session_id    text not null check (char_length(session_id) <= 64),
  kind          text not null check (kind in ('hang', 'heartbeat', 'launch', 'quit')),
  duration_ms   integer check (duration_ms between 0 and 86400000),
  app_version   text check (char_length(app_version) <= 32),
  machine       text check (char_length(machine) <= 200),
  account_email text check (char_length(account_email) <= 200),
  uptime_s      integer,
  memory_mb     integer,
  cpu_s         double precision,
  "window"      text check (char_length("window") <= 100),
  event         text check (char_length(event) <= 40),
  tool          text check (char_length(tool) <= 60),
  file_name     text check (char_length(file_name) <= 255),
  activity      text check (char_length(activity) <= 120),
  app_active    boolean
);

create index if not exists briefshow_diagnostics_created_idx
  on public.briefshow_diagnostics (created_at desc);

alter table public.briefshow_diagnostics enable row level security;

drop policy if exists "diagnostics insert only" on public.briefshow_diagnostics;
create policy "diagnostics insert only" on public.briefshow_diagnostics
  for insert to anon, authenticated with check (true);

revoke all on public.briefshow_diagnostics from anon, authenticated;
grant insert on public.briefshow_diagnostics to anon, authenticated;

-- Reading, from the dashboard:
--   select created_at, kind, duration_ms, "window", event, tool, file_name,
--          activity, memory_mb, uptime_s, machine
--   from briefshow_diagnostics
--   where created_at > now() - interval '1 day'
--   order by created_at desc;
