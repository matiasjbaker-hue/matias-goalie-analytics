-- ============================================================
-- Feedback drawn while tagging (Review) follows the shot to publish
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste the whole
-- file -> Run. Safe to re-run. Requires 20261024_shot_annotations.sql.
--
-- In Review a shot is still a draft (no shot id yet), so feedback drawn
-- there is saved against the draft (draft_id). Approve & publish then
-- sets shot_id on it, and it shows in the goalie's shot log. Deleting a
-- draft removes its feedback.

alter table public.shot_annotations
  alter column shot_id drop not null;

alter table public.shot_annotations
  add column if not exists draft_id bigint
  references public.video_shot_drafts(id) on delete cascade;

create index if not exists shot_annotations_draft_idx
  on public.shot_annotations (draft_id)
  where draft_id is not null;
