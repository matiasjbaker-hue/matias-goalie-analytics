-- Everyone's season defaults to "2026-27 Season" (new profiles, and existing
-- profiles that were on "2026 preseason" or a typo'd variant). Games keep
-- whatever season they were entered with.
alter table public.profiles alter column season set default '2026-27 Season';
update public.profiles set season = '2026-27 Season' where season is distinct from '2026-27 Season';
