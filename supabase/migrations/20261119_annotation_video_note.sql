-- Webcam video notes on feedback (stored in the voice-notes bucket, goalie folder).
alter table public.shot_annotations add column if not exists video_path text;
