-- ============================================================
-- Local YOLO/puck-tracking scan: job queue fields on game_videos
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste the whole
-- file -> Run. Safe to re-run. Requires 20261007_video_review.sql
-- (public.is_admin(), public.guard_video_review_fields()).
--
-- The admin's own PC runs tracking/worker.py, which polls
-- /api/admin/yolo-worker (api/_lib/admin-yolo.js) for queued videos,
-- processes one locally with the YOLO + Kalman puck tracker in
-- tracking/, and reports shots back. That endpoint authenticates the
-- worker with a shared secret (YOLO_WORKER_TOKEN), not a Supabase
-- session, and does every Supabase write itself with the service role
-- key -- the worker never holds Supabase or R2 credentials.
--
-- yolo_status flow: none -> queued (admin clicks "Run YOLO scan") ->
-- claimed -> running -> done | failed.

alter table public.game_videos add column if not exists yolo_status       text not null default 'none';
alter table public.game_videos add column if not exists yolo_progress     real not null default 0;
alter table public.game_videos add column if not exists yolo_calibration  jsonb;
alter table public.game_videos add column if not exists yolo_requested_at timestamptz;
alter table public.game_videos add column if not exists yolo_started_at   timestamptz;
alter table public.game_videos add column if not exists yolo_finished_at  timestamptz;
alter table public.game_videos add column if not exists yolo_error        text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'game_videos_yolo_status_check'
  ) then
    alter table public.game_videos
      add constraint game_videos_yolo_status_check
      check (yolo_status in ('none', 'queued', 'claimed', 'running', 'done', 'failed'));
  end if;
end $$;

-- The worker's "claim" op picks the oldest queued row; this is that
-- query's index. Partial, so it stays tiny regardless of table size.
create index if not exists game_videos_yolo_queued_idx
  on public.game_videos (yolo_requested_at)
  where yolo_status = 'queued';

-- Extends the guard added in 20261007_video_review.sql: only an admin
-- (or the server, acting as service_role) may change these fields.
-- Goalies can still update their own game_videos row for everything
-- else (e.g. re-uploading), same as before.
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
    new.yolo_status := 'none';
    new.yolo_progress := 0;
    new.yolo_calibration := null;
    new.yolo_requested_at := null;
    new.yolo_started_at := null;
    new.yolo_finished_at := null;
    new.yolo_error := null;
    return new;
  end if;

  if new.review_status is distinct from old.review_status
     or new.admin_note is distinct from old.admin_note
     or new.reviewed_by is distinct from old.reviewed_by
     or new.approved_at is distinct from old.approved_at
     or new.period_marks is distinct from old.period_marks
     or new.scan_cursor is distinct from old.scan_cursor
     or new.scan_progress is distinct from old.scan_progress
     or new.yolo_status is distinct from old.yolo_status
     or new.yolo_progress is distinct from old.yolo_progress
     or new.yolo_calibration is distinct from old.yolo_calibration
     or new.yolo_requested_at is distinct from old.yolo_requested_at
     or new.yolo_started_at is distinct from old.yolo_started_at
     or new.yolo_finished_at is distinct from old.yolo_finished_at
     or new.yolo_error is distinct from old.yolo_error then
    raise exception 'Only an admin can change a video''s review.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- Trigger already exists (created in 20261007_video_review.sql) and
-- fires the function above either way; no need to recreate it.
