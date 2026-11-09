-- A goalie assigned to a coach can be flagged "pays own": the goalie bought
-- games for themselves (e.g. Wesley), so a coach uploading film for them is
-- NOT charged a game; the goalie's own balance is used when the game is
-- created. Applied to prod via apply_migration as goalie_pays_own_assignment
-- (adds the column, re-creates coach_sponsor_game_video with the own_pays
-- check, and flags Taylor's Wesley assignment).
alter table public.coach_goalie_assignments
  add column if not exists goalie_pays_own boolean not null default false;
-- see 20261108_coach_multi_file_upload.sql for the trigger body; the only change
-- is the own_pays lookup added before the charge.
