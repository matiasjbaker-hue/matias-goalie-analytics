-- xG v1.9 (final): tag factors live in a table and are fitted so the average
-- xG of shots carrying each tag equals the target rate. Applies to every shot.
--   screened 11.6%, rebound 31.3%, deflection 12.5%, breakaway 32.7%, low-to-high 2.0%
--   royal road stays x1.90 (average royal-road shot ~30%), double 1.35, triple 1.50.

create table if not exists public.xg_tag_factors (
  tag text primary key,
  factor numeric not null,
  target_rate numeric,
  note text
);
alter table public.xg_tag_factors enable row level security;

insert into public.xg_tag_factors (tag, factor, target_rate, note) values
  ('cross_ice',  1.90, null,  'single royal road, set from NHL rate (~30% average)'),
  ('double',     1.35, null,  'provisional, no published rate'),
  ('triple',     1.50, null,  'provisional, no published rate'),
  ('rebound',    1.15, 0.313, 'fitted'),
  ('screened',   1.08, 0.116, 'fitted'),
  ('deflection', 1.20, 0.125, 'fitted'),
  ('breakaway',  1.45, 0.327, 'fitted'),
  ('low_high',   1.00, 0.020, 'fitted')
on conflict (tag) do nothing;

create or replace function public.xg_factor(p_tag text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select factor from public.xg_tag_factors where tag = p_tag
$$;

create or replace function public.calculate_shot_xg(
  p_distance numeric, p_location text, p_shot_type text, p_rush boolean, p_rebound boolean,
  p_screened boolean, p_breakaway boolean, p_cross_ice boolean, p_deflection boolean)
returns numeric language plpgsql stable set search_path to 'public' as $function$
declare
  base_xg numeric; mult numeric := 1.0;
  norm_location text := lower(trim(coalesce(p_location,'')));
  norm_type text := lower(trim(coalesce(p_shot_type,'')));
  d numeric := p_distance;
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
  if coalesce(p_rebound,false)    then mult := mult * public.xg_factor('rebound'); end if;
  if coalesce(p_screened,false)   then mult := mult * public.xg_factor('screened'); end if;
  if coalesce(p_breakaway,false)  then mult := mult * public.xg_factor('breakaway'); end if;
  if coalesce(p_cross_ice,false)  then mult := mult * public.xg_factor('cross_ice'); end if;
  if coalesce(p_deflection,false) then mult := mult * public.xg_factor('deflection'); end if;

  mult := least(4.00, mult);
  return greatest(0.005, least(0.50, base_xg * mult * league_calibration));
end;
$function$;

create or replace function public.calculate_shot_xg_measured(
  p_x numeric, p_y numeric, p_shot_type text, p_rush boolean, p_rebound boolean,
  p_screened boolean, p_breakaway boolean, p_cross_ice boolean, p_deflection boolean)
returns numeric language plpgsql stable set search_path to 'public' as $function$
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
  if coalesce(p_rebound,false)    then mult := mult * public.xg_factor('rebound'); end if;
  if coalesce(p_screened,false)   then mult := mult * public.xg_factor('screened'); end if;
  if coalesce(p_breakaway,false)  then mult := mult * public.xg_factor('breakaway'); end if;
  if coalesce(p_cross_ice,false)  then mult := mult * public.xg_factor('cross_ice'); end if;
  if coalesce(p_deflection,false) then mult := mult * public.xg_factor('deflection'); end if;

  mult := least(4.00, mult);
  return greatest(0.005, least(0.50, base_xg * ang * mult * k));
end;
$function$;

create or replace function public.context_xg_multiplier(
  p_low_high boolean, p_double boolean, p_triple boolean, p_turnover boolean, p_draw boolean)
returns numeric language sql stable as $function$
  select least(1.80,
    case when coalesce(p_low_high,false) then public.xg_factor('low_high') else 1 end
  * case when coalesce(p_triple,false) then public.xg_factor('triple')
         when coalesce(p_double,false) then public.xg_factor('double') else 1 end
  * case when coalesce(p_turnover,false) then 1.15 else 1 end
  * case when coalesce(p_draw,false) then 1.05 else 1 end)
$function$;

-- One place that scores a shot row (the trigger and the fit both use it).
create or replace function public.shot_xg_for(s public."Shots")
returns table (xg numeric, version text) language plpgsql stable set search_path to 'public' as $function$
declare
  core_xg numeric; core_version text; ctx numeric; tagged boolean;
begin
  if s.loc_x is not null and s.loc_y is not null then
    core_xg := public.calculate_shot_xg_measured(s.loc_x,s.loc_y,s.shot_type,
      s.rush,s.rebound,s.screened,s.breakaway,s.cross_ice,s.deflection);
    core_version := 'v1.6-measured';
  else
    core_xg := public.calculate_shot_xg(s.distance,s.location,s.shot_type,
      s.rush,s.rebound,s.screened,s.breakaway,s.cross_ice,s.deflection);
    core_version := 'v1.5-calibrated';
  end if;
  ctx := public.context_xg_multiplier(s.pass_low_to_high,s.double_royal_road,
    s.triple_royal_road,s.turnover_shot,s.draw_shot);
  tagged := coalesce(s.cross_ice,false) or coalesce(s.double_royal_road,false) or coalesce(s.triple_royal_road,false)
         or coalesce(s.rebound,false) or coalesce(s.screened,false) or coalesce(s.deflection,false)
         or coalesce(s.breakaway,false) or coalesce(s.pass_low_to_high,false);
  if s.strength is not null then
    core_xg := core_xg * public.strength_xg_multiplier(s.strength);
    core_version := 'v1.7-strength';
  end if;
  core_xg := greatest(0.005, least(0.50, core_xg * ctx));
  if tagged then core_version := 'v1.9-nhl-tags';
  elsif ctx > 1 then core_version := 'v1.8-context'; end if;
  xg := core_xg; version := core_version;
  return next;
end;
$function$;

create or replace function public.set_shot_xg()
returns trigger language plpgsql set search_path to 'public' as $function$
declare r record;
begin
  select * into r from public.shot_xg_for(new);
  new.xg := r.xg;
  new.xg_model_version := r.version;
  new.xg_grade := public.calculate_shot_xg_grade(new.xg);
  return new;
end;
$function$;

-- Fit: move each fitted factor until the average xG of shots with that tag
-- equals its target rate (iterative, tags overlap).
do $$
declare
  i int; t record; m numeric; worst numeric;
begin
  for i in 1..80 loop
    worst := 0;
    for t in select tag, target_rate from public.xg_tag_factors where target_rate is not null loop
      select avg(f.xg) into m from public."Shots" s cross join lateral public.shot_xg_for(s) f
       where case t.tag when 'rebound' then s.rebound when 'screened' then s.screened
                        when 'deflection' then s.deflection when 'breakaway' then s.breakaway
                        when 'low_high' then s.pass_low_to_high end;
      if m is not null and m > 0 then
        worst := greatest(worst, abs(m / t.target_rate - 1));
        update public.xg_tag_factors set factor = factor * power(t.target_rate / m, 0.6) where tag = t.tag;
      end if;
    end loop;
    exit when worst < 0.002;
  end loop;
end $$;

update public.xg_model_versions
   set summary = 'Tag factors set from observed/published rates: royal road x1.90 (~30%), rebound, screen, deflection, breakaway and low-to-high fitted to 31.3% / 11.6% / 12.5% / 32.7% / 2.0% average xG; double 1.35, triple 1.50 provisional. Applied to every existing shot.',
       notes = notes || ' UPDATE: factors moved to table xg_tag_factors and fitted so the average xG of shots carrying each tag equals its target rate (rebound 31.3%, screened 11.6%, deflection 12.5%, breakaway 32.7%, low-to-high 2.0%); royal road fixed at 1.90, double 1.35, triple 1.50. Per-shot multiplier cap 4.00. All existing shots were rescored.'
 where version = 'v1.9-nhl-tags';
