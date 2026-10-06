-- ============================================================
-- AI clip tagging + video ownership hardening
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste -> Run.
-- Safe to re-run: every statement checks before it changes anything.

-- 1. Mark shots that came from AI clip tagging -----------------------
-- The site keeps working without these columns (shots save without
-- their AI markers), but the Shot Log's "AI" badge and review state
-- need them.
alter table public."Shots" add column if not exists ai_tagged      boolean not null default false;
alter table public."Shots" add column if not exists ai_confidence  real;
alter table public."Shots" add column if not exists ai_model       text;
alter table public."Shots" add column if not exists ai_notes       text;
alter table public."Shots" add column if not exists ai_reviewed_at timestamptz;

create index if not exists shots_ai_unreviewed_idx
  on public."Shots" (game_id)
  where ai_tagged and ai_reviewed_at is null;

-- 2. One row per stored video file ------------------------------------
-- game_videos rows are written from the browser. Without this, a user
-- could insert a row pointing at someone else's file path. The API now
-- refuses those too, but the database should not allow it at all.
-- If this fails with "could not create unique index", two rows already
-- share a path: run the query in supabase/security-checks.sql (section
-- 4) to find them, fix them, then re-run this file.
create unique index if not exists game_videos_storage_path_key
  on public.game_videos (storage_path);

-- 3. Nobody can promote themselves ------------------------------------
-- Blocks a signed-in user from changing their own profiles.role (e.g.
-- to 'admin' or 'coach') through the public API, whatever the UPDATE
-- policy on profiles allows. Admins (is_admin()) and the service role
-- can still change roles.
create or replace function public.guard_profile_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is distinct from old.role
     and coalesce(auth.role(), '') <> 'service_role'
     and not coalesce(public.is_admin(), false) then
    raise exception 'Only an admin can change an account''s role.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_profile_role_change on public.profiles;
create trigger guard_profile_role_change
  before update of role on public.profiles
  for each row execute function public.guard_profile_role_change();
