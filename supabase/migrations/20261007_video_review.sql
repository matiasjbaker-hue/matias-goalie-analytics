-- ============================================================
-- Video review: goalie requests -> AI drafts -> admin approval
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste the whole
-- file -> Run. Safe to re-run. Requires 20261006_ai_clip_tagging.sql
-- (and the existing public.is_admin() function).
--
-- How it fits together:
--   * A goalie's upload is a request (a game_videos row). Its
--     review_status is what the goalie sees: received -> in_review ->
--     approved (or needs_attention, with admin_note).
--   * For a brand-new game nothing is created in Games until approval;
--     the game details wait in requested_game.
--   * Everything the AI finds, and every admin edit, lives in
--     video_shot_drafts, which only admins can read or write. Goalies
--     see no stats until the admin approves and the shots are written
--     to Shots / Period Stats / Games.

-- 1. Request state on each uploaded video ---------------------------
alter table public.game_videos alter column game_id drop not null;

-- Videos uploaded before this existed were handled the old way and
-- their stats are already live, so they start out 'approved'; every
-- new upload starts as 'received'. (Only on the first run.)
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'game_videos' and column_name = 'review_status'
  ) then
    alter table public.game_videos add column review_status text not null default 'approved';
    alter table public.game_videos alter column review_status set default 'received';
  end if;
end $$;

alter table public.game_videos add column if not exists requested_game jsonb;
alter table public.game_videos add column if not exists period_marks   jsonb not null default '{}'::jsonb;
alter table public.game_videos add column if not exists duration_seconds real;
alter table public.game_videos add column if not exists scan_cursor    real not null default 0;
alter table public.game_videos add column if not exists scan_progress  real not null default 0;
alter table public.game_videos add column if not exists admin_note     text;
alter table public.game_videos add column if not exists reviewed_by    uuid;
alter table public.game_videos add column if not exists approved_at    timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'game_videos_review_status_check'
  ) then
    alter table public.game_videos
      add constraint game_videos_review_status_check
      check (review_status in ('received', 'in_review', 'approved', 'needs_attention'));
  end if;
end $$;

-- Goalies must not be able to approve their own request. They may
-- still insert their own upload (existing policies), but these
-- review fields can only be changed by an admin.
create or replace function public.guard_video_review_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') = 'service_role' or coalesce(public.is_admin(), false) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.review_status := 'received';
    new.admin_note := null;
    new.reviewed_by := null;
    new.approved_at := null;
    new.scan_cursor := 0;
    new.scan_progress := 0;
    return new;
  end if;

  if new.review_status is distinct from old.review_status
     or new.admin_note is distinct from old.admin_note
     or new.reviewed_by is distinct from old.reviewed_by
     or new.approved_at is distinct from old.approved_at
     or new.period_marks is distinct from old.period_marks
     or new.scan_cursor is distinct from old.scan_cursor
     or new.scan_progress is distinct from old.scan_progress then
    raise exception 'Only an admin can change a video''s review.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_video_review_fields on public.game_videos;
create trigger guard_video_review_fields
  before insert or update on public.game_videos
  for each row execute function public.guard_video_review_fields();

-- 2. Draft shots: admin-only until approval -------------------------
create table if not exists public.video_shot_drafts (
  id             bigint generated always as identity primary key,
  game_video_id  bigint not null references public.game_videos(id) on delete cascade,
  t_seconds      real not null check (t_seconds >= 0),
  period         text,
  outcome        text not null default 'save' check (outcome in ('save', 'goal')),
  strength       text,
  location       text,
  loc_x          real,
  loc_y          real,
  shot_type      text,
  release_type   text,
  rush           boolean not null default false,
  rebound        boolean not null default false,
  screened       boolean not null default false,
  breakaway      boolean not null default false,
  cross_ice      boolean not null default false,
  deflection     boolean not null default false,
  rebound_tag    text not null default 'skip',
  source         text not null default 'ai' check (source in ('ai', 'admin')),
  ai_confidence  real,
  ai_notes       text,
  ai_model       text,
  edited         boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists video_shot_drafts_video_idx
  on public.video_shot_drafts (game_video_id, t_seconds);

alter table public.video_shot_drafts enable row level security;

drop policy if exists "admin manages shot drafts" on public.video_shot_drafts;
create policy "admin manages shot drafts"
  on public.video_shot_drafts
  for all
  to authenticated
  using (coalesce(public.is_admin(), false))
  with check (coalesce(public.is_admin(), false));
