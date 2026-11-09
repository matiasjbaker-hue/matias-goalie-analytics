-- Lets an admin reorder a request's extra files (Part 2, Part 3 ...).
-- Null = fall back to upload order, so nothing changes until a file is moved.
alter table public.game_videos add column if not exists part_order integer;
