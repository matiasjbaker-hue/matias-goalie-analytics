-- ============================================================
-- Extra files on one game: "Part 2" of a review
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste the whole
-- file -> Run. Safe to re-run. Requires 20261007_video_review.sql.
--
-- A game's film sometimes comes as two files. Each extra file is its
-- own game_videos row (so it keeps its own shots, period marks, AI
-- results and clips) that points at the first file's row through
-- parent_video_id. The review screen shows them as one request with a
-- Part 1 / Part 2 switch, and publishing sends every part to the same
-- game at once.
--
--   parent_video_id is null      -> the request itself (Part 1)
--   parent_video_id = <id>       -> an extra file of that request

alter table public.game_videos
  add column if not exists parent_video_id bigint
  references public.game_videos(id) on delete cascade;

create index if not exists game_videos_parent_video_id_idx
  on public.game_videos (parent_video_id)
  where parent_video_id is not null;

-- Only an admin (or the server, with the service key) may attach an
-- extra file to a request. Same guard as the other review fields; this
-- is the 20261007 function plus the parent_video_id check.
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
    new.parent_video_id := null;
    return new;
  end if;

  if new.review_status is distinct from old.review_status
     or new.admin_note is distinct from old.admin_note
     or new.reviewed_by is distinct from old.reviewed_by
     or new.approved_at is distinct from old.approved_at
     or new.period_marks is distinct from old.period_marks
     or new.scan_cursor is distinct from old.scan_cursor
     or new.scan_progress is distinct from old.scan_progress
     or new.parent_video_id is distinct from old.parent_video_id then
    raise exception 'Only an admin can change a video''s review.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;
