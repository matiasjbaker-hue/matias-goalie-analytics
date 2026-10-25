-- ============================================================
-- Let logged-in users read and write shot_annotations
-- ============================================================
-- The table was created without the grant the rest of the app's tables
-- have, so saving feedback failed with "permission denied for table
-- shot_annotations". The row-level security policies still decide who
-- can do what. Safe to re-run.

grant select, insert, update, delete on public.shot_annotations to authenticated;
