-- Read-only queries for the ML dataset export without a service key.
-- Run each one on its own in Supabase -> SQL Editor (row limit: none),
-- then "Download CSV" and save it in ml/data/csv/ as <table>.csv:
--   Games.csv, Shots.csv, game_videos.csv, video_shot_drafts.csv
-- Then: node ml/export-dataset.mjs --from-csv ml/data/csv

select * from public."Games" order by id;

select * from public."Shots" order by game_id;

select * from public.game_videos order by id;

select * from public.video_shot_drafts order by game_video_id, t_seconds;
