-- Pass/possession context tags + xG v1.8-context
alter table public."Shots"
  add column if not exists pass_low_to_high boolean,
  add column if not exists double_royal_road boolean,
  add column if not exists triple_royal_road boolean,
  add column if not exists turnover_shot boolean,
  add column if not exists draw_shot boolean,
  add column if not exists pre_pass_location text;

alter table public.video_shot_drafts
  add column if not exists pass_low_to_high boolean not null default false,
  add column if not exists double_royal_road boolean not null default false,
  add column if not exists triple_royal_road boolean not null default false,
  add column if not exists turnover_shot boolean not null default false,
  add column if not exists draw_shot boolean not null default false,
  add column if not exists pre_pass_location text;

create or replace function public.context_xg_multiplier(
  p_low_high boolean, p_double boolean, p_triple boolean, p_turnover boolean, p_draw boolean)
returns numeric language sql immutable as $$
  select least(1.60,
    case when coalesce(p_low_high,false) then 1.10 else 1 end
  * case when coalesce(p_triple,false) then 1.25
         when coalesce(p_double,false) then 1.15 else 1 end
  * case when coalesce(p_turnover,false) then 1.15 else 1 end
  * case when coalesce(p_draw,false) then 1.05 else 1 end)
$$;

create or replace function public.set_shot_xg()
returns trigger language plpgsql set search_path to 'public' as $function$
declare
  core_xg numeric; core_version text; ctx numeric;
begin
  if new.loc_x is not null and new.loc_y is not null then
    core_xg := public.calculate_shot_xg_measured(new.loc_x,new.loc_y,new.shot_type,
      new.rush,new.rebound,new.screened,new.breakaway,new.cross_ice,new.deflection);
    core_version := 'v1.6-measured';
  else
    core_xg := public.calculate_shot_xg(new.distance,new.location,new.shot_type,
      new.rush,new.rebound,new.screened,new.breakaway,new.cross_ice,new.deflection);
    core_version := 'v1.5-calibrated';
  end if;

  ctx := public.context_xg_multiplier(new.pass_low_to_high,new.double_royal_road,
    new.triple_royal_road,new.turnover_shot,new.draw_shot);

  if new.strength is not null then
    core_xg := core_xg * public.strength_xg_multiplier(new.strength);
    core_version := 'v1.7-strength';
  end if;

  if ctx > 1 then
    new.xg := greatest(0.005, least(0.35, core_xg * ctx));
    new.xg_model_version := 'v1.8-context';
  elsif new.strength is not null then
    new.xg := greatest(0.005, least(0.35, core_xg));
    new.xg_model_version := 'v1.7-strength';
  else
    new.xg := core_xg;
    new.xg_model_version := core_version;
  end if;

  new.xg_grade := public.calculate_shot_xg_grade(new.xg);
  return new;
end;
$function$;

insert into public.xg_model_versions(version, effective_at, summary, notes) values (
 'v1.8-context', now(),
 'Shots tagged with pass/possession context get a context factor on top of v1.5/v1.6/v1.7. Untagged shots are unchanged.',
 'Factors (multiplicative, combined cap 1.60, final clamp [0.005,0.35]): low-to-high pass 1.10; double royal road 1.15 (triple 1.25 replaces it, not stacked); shot off a turnover 1.15; shot off a draw 1.05. Double/triple royal road imply a cross-ice pass, so they also carry the existing cross_ice factor in the core score. Pre-pass location is recorded for stats only and does not change xG. WHY: these shots come against a goalie who is moving or out of set, so the same spot is more dangerous than a static one. Factors are literature-informed priors, NOT fit to this platform data; refit once enough tagged shots exist (compare actual goal rate vs xG per factor in the Situational tab). No existing row was rescored.');
