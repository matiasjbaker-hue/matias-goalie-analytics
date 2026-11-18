-- Goalies assigned to Taylor are coach-managed (hidden from the overall
-- Goalies table) by default, unless they pay for their own games.
create or replace function public.default_coach_managed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.goalie_pays_own, false)
     and exists (select 1 from public.profiles c where c.id = new.coach_id and c.full_name ilike 'Taylor%') then
    new.coach_managed := true;
  end if;
  return new;
end;
$$;
drop trigger if exists default_coach_managed on public.coach_goalie_assignments;
create trigger default_coach_managed before insert on public.coach_goalie_assignments
  for each row execute function public.default_coach_managed();

-- One-off: the two goalies who signed up after the first batch.
update public.coach_goalie_assignments a set coach_managed = true
from public.profiles c
where c.id = a.coach_id and c.full_name ilike 'Taylor%' and a.active and not a.goalie_pays_own and not a.coach_managed;
