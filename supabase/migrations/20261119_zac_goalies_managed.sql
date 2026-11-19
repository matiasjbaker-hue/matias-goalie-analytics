-- Zac Bierk's goalies are coach-managed (hidden from the overall Goalies table), like Taylor's,
-- unless they pay for their own games. Applies to new assignments too.
create or replace function public.default_coach_managed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.goalie_pays_own, false)
     and exists (select 1 from public.profiles c where c.id = new.coach_id
                 and (c.full_name ilike 'Taylor%' or c.full_name = 'Zac Bierk')) then
    new.coach_managed := true;
  end if;
  return new;
end;
$$;

update public.coach_goalie_assignments a set coach_managed = true
from public.profiles c
where c.id = a.coach_id and c.full_name = 'Zac Bierk' and a.active and not a.goalie_pays_own and not a.coach_managed;
