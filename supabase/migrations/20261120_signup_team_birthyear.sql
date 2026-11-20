-- Sign-up now collects Team and Birth year; store them on the profile.
-- Parsing is defensive so a bad value can never block account creation.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  by_txt text := new.raw_user_meta_data ->> 'birth_year';
  by_int int;
begin
  if by_txt ~ '^[0-9]{4}$' then
    by_int := by_txt::int;
    if by_int < 1950 or by_int > extract(year from now())::int then by_int := null; end if;
  end if;

  insert into public.profiles (id, full_name, role, heard_from, heard_from_other, team, birth_year)
  values (
    new.id,
    new.raw_user_meta_data ->> 'name',
    'goalie',
    nullif(left(new.raw_user_meta_data ->> 'heard_from', 80), ''),
    nullif(left(new.raw_user_meta_data ->> 'heard_from_other', 200), ''),
    nullif(left(btrim(new.raw_user_meta_data ->> 'team'), 80), ''),
    by_int
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
