-- Per-shot rebound-control outcome (how the save went: glove_caught,
-- glove_rebound, blocker_bad, pad_stick_goal, ...). Before this, the
-- outcome was only counted into goalierebound_control totals and the
-- link to the individual shot (and its clip) was lost. NULL = not tagged.
alter table public."Shots" add column if not exists rebound_tag text;
