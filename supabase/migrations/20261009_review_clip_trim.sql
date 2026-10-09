-- Per-shot clip trim in Video Review.
-- A drafted shot normally publishes with a clip from 4 s before to 3 s
-- after its time. The admin can set the clip's own start / end instead
-- (e.g. to drop zone play before the shot). Null = the default window.
alter table public.video_shot_drafts
  add column if not exists clip_start_seconds numeric,
  add column if not exists clip_end_seconds numeric;
