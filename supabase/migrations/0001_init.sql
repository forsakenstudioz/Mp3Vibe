-- Vibe music app: database schema.
-- Paste this whole file into Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- Songs: one row per audio file in the laptop music folder.
-- Written only by the laptop sync agent (service role). Read by app users.
-- ---------------------------------------------------------------------------
create table if not exists public.songs (
  id            uuid primary key default gen_random_uuid(),
  content_hash  text not null unique,          -- sha1 of the file, used to skip re-uploads
  title         text not null,
  artist        text not null default 'Unknown artist',
  album         text,
  genre         text,
  year          int,
  duration_ms   int not null default 0,
  storage_key   text not null,                 -- object key in the R2 bucket, e.g. audio/<hash>.mp3
  cover_key     text,                          -- covers/<hash>.jpg, if the file had embedded art
  file_ext      text not null default 'mp3',
  file_size     bigint not null default 0,
  source_path   text,                          -- path relative to the music folder (for your reference)

  -- Audio analysis (0..1 unless noted), produced by sync_agent/analyze.py
  bpm           real,
  energy        real,
  valence       real,                          -- musical "positivity"
  danceability  real,
  acousticness  real,
  features      real[],                        -- timbre/rhythm vector used for "sounds like" suggestions
  mood          text,                          -- best guess: energetic | party | calm | romantic | sad | focus
  mood_scores   jsonb,                         -- {"calm":0.8,"sad":0.3,...}
  mood_override text,                          -- set from the app when you disagree with the guess

  added_at      timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false -- file was removed from the laptop folder
);

create index if not exists songs_added_at_idx on public.songs (added_at desc);
create index if not exists songs_mood_idx on public.songs (coalesce(mood_override, mood));

alter table public.songs enable row level security;

drop policy if exists "signed-in users can read songs" on public.songs;
create policy "signed-in users can read songs" on public.songs
  for select to authenticated using (true);

-- App users may only change the mood override, nothing else.
drop policy if exists "signed-in users can set mood override" on public.songs;
create policy "signed-in users can set mood override" on public.songs
  for update to authenticated using (true) with check (true);
revoke update on public.songs from authenticated;
grant update (mood_override) on public.songs to authenticated;

-- ---------------------------------------------------------------------------
-- Taste: likes and listening events power personal suggestions.
-- ---------------------------------------------------------------------------
create table if not exists public.likes (
  user_id    uuid not null references auth.users (id) on delete cascade default auth.uid(),
  song_id    uuid not null references public.songs (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, song_id)
);

create table if not exists public.listen_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade default auth.uid(),
  song_id    uuid not null references public.songs (id) on delete cascade,
  kind       text not null check (kind in ('play', 'skip', 'complete')),
  listened_ms int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists listen_events_user_idx on public.listen_events (user_id, created_at desc);

alter table public.likes enable row level security;
alter table public.listen_events enable row level security;

drop policy if exists "own likes" on public.likes;
create policy "own likes" on public.likes
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own events" on public.listen_events;
create policy "own events" on public.listen_events
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Profiles: display name shown in rooms.
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade default auth.uid(),
  display_name text not null,
  updated_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles
  for select to authenticated using (true);
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- Listening rooms. Live sync happens over Supabase Realtime; the row keeps the
-- latest playback state so someone joining an empty room picks up where it was.
-- ---------------------------------------------------------------------------
create table if not exists public.rooms (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  created_by uuid not null references auth.users (id) on delete cascade default auth.uid(),
  state      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  active_at  timestamptz not null default now()
);
alter table public.rooms enable row level security;

drop policy if exists "rooms readable" on public.rooms;
create policy "rooms readable" on public.rooms
  for select to authenticated using (true);
drop policy if exists "rooms creatable" on public.rooms;
create policy "rooms creatable" on public.rooms
  for insert to authenticated with check (created_by = auth.uid());
drop policy if exists "room owner deletes" on public.rooms;
create policy "room owner deletes" on public.rooms
  for delete to authenticated using (created_by = auth.uid());

-- Any member may change playback, but only with a newer version than what is
-- stored, so two people pressing buttons at once can't roll each other back.
create or replace function public.update_room_state(p_code text, p_state jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  updated int;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  update rooms
     set state = p_state, active_at = now()
   where code = p_code
     and coalesce((state ->> 'version')::bigint, 0) < coalesce((p_state ->> 'version')::bigint, 0);
  get diagnostics updated = row_count;
  return updated > 0;
end;
$$;
revoke all on function public.update_room_state(text, jsonb) from public, anon;
grant execute on function public.update_room_state(text, jsonb) to authenticated;

-- Server clock in milliseconds. The app uses it to line up playback across devices.
create or replace function public.server_now()
returns double precision
language sql
volatile
as $$ select extract(epoch from clock_timestamp()) * 1000 $$;
grant execute on function public.server_now() to authenticated;

-- ---------------------------------------------------------------------------
-- Live updates: new songs appear in the app as soon as the laptop uploads them.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'songs'
  ) then
    alter publication supabase_realtime add table public.songs;
  end if;
end $$;
