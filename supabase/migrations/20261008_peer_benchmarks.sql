-- Season names are typed by hand ("2026-27 Season" / "2026-27 season"), so
-- compare them the same way the app does.
create or replace function public.norm_season(s text) returns text language sql immutable as $$
  select case when regexp_replace(lower(btrim(coalesce(s,''))), '\s+', ' ', 'g') in ('2026 preseason','2026 pre season','2026 pre-season') then '2026 preseason'
         else regexp_replace(lower(btrim(coalesce(s,''))), '\s+', ' ', 'g') end
$$;

-- Anonymous peer averages. Goalies can't read each other's rows (RLS), so
-- this SECURITY DEFINER function returns only cohort averages, and nothing
-- at all until the cohort has at least 5 goalies with games this season.
-- Cohort = goalies at the same level; if that group is under 5, all goalies.
create or replace function public.peer_benchmarks(p_season text, p_user uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := coalesce(p_user, auth.uid());
  lvl text;
  v_cohort uuid[];
  cohort_label text;
  k int;
  result jsonb;
begin
  if auth.uid() is null or v_uid is null then
    return jsonb_build_object('unlocked', false, 'goalies', 0, 'needed', 5);
  end if;

  if v_uid <> auth.uid() and not (is_admin() or is_my_goalie(v_uid)) then
    raise exception 'not allowed';
  end if;

  select level into lvl from profiles where id = v_uid;

  select array_agg(p.id) into v_cohort
  from profiles p
  where p.role = 'goalie' and lvl is not null and p.level = lvl
    and exists (select 1 from "Games" g where g.user_id = p.id and norm_season(g.season) = norm_season(p_season));
  k := coalesce(array_length(v_cohort, 1), 0);
  cohort_label := lvl;

  if k < 5 then
    select array_agg(p.id) into v_cohort
    from profiles p
    where p.role = 'goalie'
      and exists (select 1 from "Games" g where g.user_id = p.id and norm_season(g.season) = norm_season(p_season));
    k := coalesce(array_length(v_cohort, 1), 0);
    cohort_label := 'All GoalieIQ goalies';
  end if;

  if k < 5 then
    return jsonb_build_object('unlocked', false, 'goalies', k, 'needed', 5);
  end if;

  with gs as (
    select user_id as uid,
           sum(saves + goals_against) as sa,
           sum(saves) as sv,
           sum(goals_against) as ga,
           sum(coalesce(minutes_played, 60) * 60.0 / coalesce(nullif(game_length, 0), 60)) as mins
    from "Games" where norm_season(season) = norm_season(p_season) group by user_id
  ),
  sh as (
    select g.user_id as uid,
           (lower(coalesce(s.outcome, '')) = 'goal') as goal,
           s.xg, s.xg_grade, s.rush, s.rebound, s.screened, s.breakaway, s.cross_ice, s.deflection,
           case
             when s.release_type = 'extended_possession' then 'extended'
             when s.release_type in ('one_timer', 'catch_and_release', 'quick_release') then 'quick'
             when s.possession_duration_seconds is not null
               then case when s.possession_duration_seconds > 2 then 'extended' else 'quick' end
           end as rel
    from "Shots" s join "Games" g on g.id = s.game_id
    where norm_season(g.season) = norm_season(p_season)
  ),
  rb as (
    select g.user_id as uid,
           sum(r.glove_caught + r.blocker_good + r.midsection_good + r.pad_stick_good) as good,
           sum(r.glove_rebound + r.blocker_bad + r.midsection_bad + r.pad_stick_bad) as bad
    from goalierebound_control r join "Games" g on g.id = r.game_id
    where norm_season(g.season) = norm_season(p_season) group by g.user_id
  ),
  pk as (
    select g.user_id as uid,
           sum(p.rims_faced) as rf, sum(p.rims_stopped) as rs,
           sum(p.pass_attempts) as pa, sum(p.passes_completed) as pc
    from puck_playing p join "Games" g on g.id = p.game_id
    where norm_season(g.season) = norm_season(p_season) group by g.user_id
  ),
  m as (
    select uid, 'sv_pct' as metric, sv * 100.0 / nullif(sa, 0) as v, sa as n, 20 as minn from gs
    union all select uid, 'gaa', ga * 60.0 / nullif(mins, 0), sa, 20 from gs
    union all select sh.uid, 'sv_above_expected',
              (sum(xg) - sum(goal::int)) * 100.0 / count(*), count(*), 20
              from sh where xg is not null group by sh.uid
    union all select sh.uid, 'gsax_per60',
              (sum(xg) - sum(goal::int)) / nullif(max(gs.mins), 0) * 60, count(*), 20
              from sh join gs on gs.uid = sh.uid where xg is not null group by sh.uid
    union all select uid, 'hd_sv', (1 - avg(goal::int)) * 100, count(*), 5 from sh where xg_grade in ('A+', 'A') group by uid
    union all select uid, 'rush_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where rush group by uid
    union all select uid, 'rebound_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where rebound group by uid
    union all select uid, 'screened_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where screened group by uid
    union all select uid, 'breakaway_sv', (1 - avg(goal::int)) * 100, count(*), 3 from sh where breakaway group by uid
    union all select uid, 'cross_ice_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where cross_ice group by uid
    union all select uid, 'deflection_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where deflection group by uid
    union all select uid, 'quick_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where rel = 'quick' group by uid
    union all select uid, 'extended_sv', (1 - avg(goal::int)) * 100, count(*), 6 from sh where rel = 'extended' group by uid
    union all select uid, 'good_rebound', good * 100.0 / nullif(good + bad, 0), good + bad, 8 from rb
    union all select uid, 'rim_stop', rs * 100.0 / nullif(rf, 0), rf, 5 from pk
    union all select uid, 'pass_pct', pc * 100.0 / nullif(pa, 0), pa, 5 from pk
  ),
  ok as (select * from m where v is not null and n >= minn),
  peer as (
    select metric, avg(v) as peer_avg, count(*) as peer_goalies
    from ok where uid = any(v_cohort) group by metric
  ),
  me as (select metric, v, n from ok where uid = v_uid)
  select jsonb_object_agg(metric, obj) into result
  from (
    select coalesce(peer.metric, me.metric) as metric,
           jsonb_build_object(
             'you', me.v,
             'you_n', me.n,
             'peer', case when peer.peer_goalies >= 5 then peer.peer_avg end,
             'peer_goalies', coalesce(peer.peer_goalies, 0)
           ) as obj
    from peer full join me on me.metric = peer.metric
  ) x;

  return jsonb_build_object(
    'unlocked', true,
    'cohort', cohort_label,
    'goalies', k,
    'season', p_season,
    'metrics', coalesce(result, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.peer_benchmarks(text, uuid) from public, anon;
grant execute on function public.peer_benchmarks(text, uuid) to authenticated;
