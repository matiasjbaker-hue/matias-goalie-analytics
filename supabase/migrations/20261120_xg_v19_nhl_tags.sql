-- xG v1.9-nhl-tags: pass/chaos tag factors set from published NHL rates.
-- Changes (new and edited shots only; nothing is bulk-rescored here):
--   single royal road   x1.10 -> x1.90  (average royal road shot ~30%, NHL: 30% Valiquette, 15.5% Stimson)
--   double royal road   x1.15 -> x1.35  (provisional: no published rate, 0 tagged shots)
--   triple royal road   x1.25 -> x1.50  (provisional)
--   low-to-high pass    x1.10 -> x1.00  (NHL: ~2% goal rate off low-to-high)
--   per-shot multiplier cap 2.25 -> 3.00, final clamp 0.35 -> 0.50, context cap 1.60 -> 1.80
-- Rebound, screen, deflection, turnover, draw, strength: unchanged.

create or replace function public.calculate_shot_xg(
  p_distance numeric, p_location text, p_shot_type text, p_rush boolean, p_rebound boolean,
  p_screened boolean, p_breakaway boolean, p_cross_ice boolean, p_deflection boolean)
returns numeric language plpgsql immutable set search_path to 'public' as $function$
declare
  base_xg numeric; mult numeric := 1.0;
  norm_location text := lower(trim(coalesce(p_location,'')));
  norm_type text := lower(trim(coalesce(p_shot_type,'')));
  raw_xg numeric; d numeric := p_distance;
  league_calibration constant numeric := 1.62;
begin
  if d is null or d <= 0 then
    d := case
      when norm_location like '%crease%' then 2.2
      when norm_location like '%low slot%' then 3.5
      when norm_location like '%goal line%' then 5
      when norm_location like '%bottom of circle%' then 7.8
      when norm_location like '%hash%' then 8.5
      when norm_location like '%high slot%' then 18.3
      when norm_location like '%slot%' then 10
      when norm_location like '%top of circle%' then 19.2
      when norm_location like '%dot%' then 18
      when norm_location like '%circle%' then 13
      when norm_location like '%wall%' or norm_location like '%perimeter%' then 20
      when norm_location like '%point%' then 28.9
      else null end;
  end if;
  if d is null or d <= 0 then base_xg := 0.080;
  elsif d <= 6  then base_xg := 0.120;
  elsif d <= 12 then base_xg := 0.075;
  elsif d <= 20 then base_xg := 0.038;
  elsif d <= 30 then base_xg := 0.018;
  elsif d <= 40 then base_xg := 0.008;
  else base_xg := 0.004; end if;

  if norm_location = 'crease' then mult := mult * 1.20;
  elsif norm_location = 'point' then mult := mult * 0.85;
  elsif norm_location like '%slot%' or norm_location like '%hash%' then mult := mult * 1.10;
  elsif norm_location like '%circle%' or norm_location like '%dot%' then mult := mult * 0.90;
  elsif norm_location like '%perimeter%' or norm_location like '%wall%' or norm_location like '%goal line%' then mult := mult * 0.75;
  end if;

  if norm_type in ('one timer','one-timer') then mult := mult * 1.15; end if;
  if norm_type = 'backhand' then mult := mult * 1.05; end if;
  if norm_type in ('slap shot','slap') then mult := mult * 1.03; end if;
  if coalesce(p_rush,false)       then mult := mult * 1.05; end if;
  if coalesce(p_rebound,false)    then mult := mult * 1.15; end if;
  if coalesce(p_screened,false)   then mult := mult * 1.08; end if;
  if coalesce(p_breakaway,false)  then mult := mult * 1.45; end if;
  if coalesce(p_cross_ice,false)  then mult := mult * 1.90; end if;
  if coalesce(p_deflection,false) then mult := mult * 1.20; end if;

  mult := least(3.00, mult);
  raw_xg := base_xg * mult * league_calibration;
  return greatest(0.005, least(0.50, raw_xg));
end;
$function$;

create or replace function public.calculate_shot_xg_measured(
  p_x numeric, p_y numeric, p_shot_type text, p_rush boolean, p_rebound boolean,
  p_screened boolean, p_breakaway boolean, p_cross_ice boolean, p_deflection boolean)
returns numeric language plpgsql immutable set search_path to 'public' as $function$
declare
  norm_type text := lower(trim(coalesce(p_shot_type,'')));
  d numeric; theta numeric; base_xg numeric; ang numeric; mult numeric := 1.0;
  k constant numeric := 1.60;
begin
  d := greatest(0.5, sqrt(p_x*p_x + p_y*p_y));
  theta := case when p_x = 0 and p_y = 0 then 90
    else degrees(atan2(abs(p_x)::float8, p_y::float8))::numeric end;
  base_xg := 0.02 + 0.30 * exp(-d / 14.0);
  ang := exp(-theta / 90.0);

  if norm_type in ('one timer','one-timer') then mult := mult * 1.15; end if;
  if norm_type = 'backhand' then mult := mult * 1.05; end if;
  if norm_type in ('slap shot','slap') then mult := mult * 1.03; end if;
  if coalesce(p_rush,false)       then mult := mult * 1.05; end if;
  if coalesce(p_rebound,false)    then mult := mult * 1.15; end if;
  if coalesce(p_screened,false)   then mult := mult * 1.08; end if;
  if coalesce(p_breakaway,false)  then mult := mult * 1.45; end if;
  if coalesce(p_cross_ice,false)  then mult := mult * 1.90; end if;
  if coalesce(p_deflection,false) then mult := mult * 1.20; end if;

  mult := least(3.00, mult);
  return greatest(0.005, least(0.50, base_xg * ang * mult * k));
end;
$function$;

create or replace function public.context_xg_multiplier(
  p_low_high boolean, p_double boolean, p_triple boolean, p_turnover boolean, p_draw boolean)
returns numeric language sql immutable as $function$
  select least(1.80,
    case when coalesce(p_triple,false) then 1.50
         when coalesce(p_double,false) then 1.35 else 1 end
  * case when coalesce(p_turnover,false) then 1.15 else 1 end
  * case when coalesce(p_draw,false) then 1.05 else 1 end)
$function$;

create or replace function public.set_shot_xg()
returns trigger language plpgsql set search_path to 'public' as $function$
declare
  core_xg numeric; core_version text; ctx numeric; nhl_tags boolean;
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

  -- Shots whose score uses the v1.9 royal-road factors are labelled v1.9.
  nhl_tags := coalesce(new.cross_ice,false) or coalesce(new.double_royal_road,false)
           or coalesce(new.triple_royal_road,false);

  if new.strength is not null then
    core_xg := core_xg * public.strength_xg_multiplier(new.strength);
    core_version := 'v1.7-strength';
  end if;

  if ctx > 1 then
    new.xg := greatest(0.005, least(0.50, core_xg * ctx));
    new.xg_model_version := case when nhl_tags then 'v1.9-nhl-tags' else 'v1.8-context' end;
  elsif new.strength is not null then
    new.xg := greatest(0.005, least(0.50, core_xg));
    new.xg_model_version := case when nhl_tags then 'v1.9-nhl-tags' else 'v1.7-strength' end;
  else
    new.xg := core_xg;
    new.xg_model_version := case when nhl_tags then 'v1.9-nhl-tags' else core_version end;
  end if;

  new.xg_grade := public.calculate_shot_xg_grade(new.xg);
  return new;
end;
$function$;

insert into public.xg_model_versions (version, effective_at, summary, notes) values (
  'v1.9-nhl-tags', now(),
  'Royal road factors set from published NHL rates (single x1.90, double x1.35, triple x1.50); low-to-high neutral.',
  'WHY: NHL tracking puts a shot after a royal-road pass at about 30% (Valiquette, 100 NHL games; Stimson/Wells cross-slot 15.5%), and this platform''s 222 royal-road shots score 29.3% against a v1.8 prediction of 17.0%. Single royal road x1.10 -> x1.90 so the average royal-road shot lands near 30%. Double (x1.35) and triple (x1.50) are PROVISIONAL: no published rate exists and none are tagged yet, so refit once ~50 each are tagged. Low-to-high x1.10 -> x1.00: NHL tracking shows ~2% goal rate off low-to-high passes. Per-shot multiplier cap 2.25 -> 3.00, final clamp 0.35 -> 0.50, context cap 1.60 -> 1.80 so a royal-road shot from the slot can reach its real rate. Rebound, screen, deflection, turnover, draw, strength and the league calibration constants are unchanged. Applies to shots saved or edited from now on; existing rows were not rescored.'
);
