-- Puck playing breakdown.
-- Rims (forecheck against) are tracked by side (forehand / backhand) and
-- height (on the ice / up high); passes by type (forehand / backhand /
-- stretch). rims_faced, rims_stopped, pass_attempts and passes_completed
-- stay as the totals, so existing reports keep working.
alter table public.puck_playing
  add column if not exists rims_faced_forehand_ice    integer not null default 0,
  add column if not exists rims_faced_backhand_ice    integer not null default 0,
  add column if not exists rims_faced_forehand_high   integer not null default 0,
  add column if not exists rims_faced_backhand_high   integer not null default 0,
  add column if not exists rims_stopped_forehand_ice  integer not null default 0,
  add column if not exists rims_stopped_backhand_ice  integer not null default 0,
  add column if not exists rims_stopped_forehand_high integer not null default 0,
  add column if not exists rims_stopped_backhand_high integer not null default 0,
  add column if not exists pass_attempts_forehand     integer not null default 0,
  add column if not exists pass_attempts_backhand     integer not null default 0,
  add column if not exists pass_attempts_stretch      integer not null default 0,
  add column if not exists passes_completed_forehand  integer not null default 0,
  add column if not exists passes_completed_backhand  integer not null default 0,
  add column if not exists passes_completed_stretch   integer not null default 0;

-- Existing games: every rim was on the ice, split evenly between forehand
-- and backhand with whole numbers. When the count is odd the extra rim goes
-- to forehand on even game ids and backhand on odd ones, so it balances
-- out across games. Stopped uses the same rule, so a side never has more
-- stopped than faced. Passes weren't typed back then, so they stay in the
-- totals only.
update public.puck_playing set
  rims_faced_forehand_ice   = case when game_id % 2 = 0 then (coalesce(rims_faced, 0) + 1) / 2 else coalesce(rims_faced, 0) / 2 end,
  rims_faced_backhand_ice   = coalesce(rims_faced, 0) - case when game_id % 2 = 0 then (coalesce(rims_faced, 0) + 1) / 2 else coalesce(rims_faced, 0) / 2 end,
  rims_stopped_forehand_ice = case when game_id % 2 = 0 then (coalesce(rims_stopped, 0) + 1) / 2 else coalesce(rims_stopped, 0) / 2 end,
  rims_stopped_backhand_ice = coalesce(rims_stopped, 0) - case when game_id % 2 = 0 then (coalesce(rims_stopped, 0) + 1) / 2 else coalesce(rims_stopped, 0) / 2 end
where rims_faced_forehand_ice + rims_faced_backhand_ice + rims_faced_forehand_high + rims_faced_backhand_high
    + rims_stopped_forehand_ice + rims_stopped_backhand_ice + rims_stopped_forehand_high + rims_stopped_backhand_high = 0;
