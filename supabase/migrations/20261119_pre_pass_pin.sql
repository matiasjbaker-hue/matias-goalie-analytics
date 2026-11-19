-- Pinned location of the pass before a royal road shot (same feet coordinates as loc_x / loc_y)
alter table public."Shots" add column if not exists pre_pass_x numeric, add column if not exists pre_pass_y numeric;
alter table public.video_shot_drafts add column if not exists pre_pass_x numeric, add column if not exists pre_pass_y numeric;
