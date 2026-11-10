-- Taylor's goalies don't get the free first game: his pilot already covered
-- it and their games come from his account. A goalie counts as Taylor's if
-- they're actively assigned to him, or they said "Taylor" under "How did you
-- hear about us?" (so it holds even if they sign up before being assigned).
create or replace function public.free_game_blocked(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.coach_goalie_assignments a
    join public.profiles c on c.id = a.coach_id
    where a.goalie_id = p_user and a.active and c.full_name ilike 'Taylor%'
  ) or exists (
    select 1 from public.profiles p
    where p.id = p_user
      and (coalesce(p.heard_from_other, '') ilike '%taylor%' or coalesce(p.heard_from, '') ilike '%taylor%')
  );
$$;
revoke all on function public.free_game_blocked(uuid) from public, anon;

create or replace function public.my_free_game_blocked()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select coalesce(public.free_game_blocked(auth.uid()), false); $$;
revoke all on function public.my_free_game_blocked() from public, anon;
grant execute on function public.my_free_game_blocked() to authenticated;

create or replace function public.start_free_trial()
returns goalie_access
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  row public.goalie_access;
begin
  if me is null then
    raise exception 'Not signed in';
  end if;
  if not exists (select 1 from public.profiles where id = me and role = 'goalie') then
    raise exception 'Only goalie accounts can start a trial';
  end if;
  if exists (select 1 from public.goalie_access where user_id = me) then
    raise exception 'Free game already used on this account';
  end if;
  if public.free_game_blocked(me) then
    raise exception 'Your coach covers your games, so there is no free game on this account. Ask your coach to set you up.';
  end if;
  insert into public.goalie_access (user_id, status, access_until, plan, game_credits, note)
  values (me, 'active', null, 'pay_per_game', 1, 'Free first game')
  returning * into row;
  return row;
end;
$$;
