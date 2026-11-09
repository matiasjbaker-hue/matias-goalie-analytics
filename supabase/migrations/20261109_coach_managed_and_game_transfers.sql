-- 1) Coach-managed goalies: an assignment can be flagged so the goalie
--    drops out of the admin's overall Goalies table (their games are paid
--    for from the coach's balance). Shown again with a checkbox.
alter table public.coach_goalie_assignments
  add column if not exists coach_managed boolean not null default false;

-- 2) Move games between accounts (coach <-> goalie), atomically, admin only.
create table if not exists public.game_credit_transfers (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  games integer not null check (games > 0),
  by_admin uuid references auth.users(id) on delete set null
);
alter table public.game_credit_transfers enable row level security;
drop policy if exists "Admin reads game transfers" on public.game_credit_transfers;
create policy "Admin reads game transfers" on public.game_credit_transfers
  for select using (public.is_admin());

create or replace function public.transfer_game_credits(p_from uuid, p_to uuid, p_games integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.goalie_access;
  b public.goalie_access;
  from_left integer;
  to_left integer;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only an admin can move games between accounts.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'Pick two different accounts.';
  end if;
  if p_games is null or p_games < 1 or p_games > 1000 then
    raise exception 'Enter a number of games from 1 to 1000.';
  end if;

  -- lock both rows in a fixed order so two transfers can't deadlock
  perform 1 from public.goalie_access where user_id in (p_from, p_to) order by user_id for update;

  select * into a from public.goalie_access where user_id = p_from;
  if not found or a.plan is distinct from 'pay_per_game' or a.status <> 'active' then
    raise exception 'The account you are taking games from is not on pay-per-game, so it has no games to move.';
  end if;
  if a.game_credits < p_games then
    raise exception 'That account only has % game(s) left.', a.game_credits;
  end if;

  select * into b from public.goalie_access where user_id = p_to;
  if not found then
    insert into public.goalie_access (user_id, status, plan, game_credits, paid, granted_by, updated_at)
    values (p_to, 'active', 'pay_per_game', p_games, false, auth.uid(), now());
    to_left := p_games;
  else
    -- same as typing "Games left" in the Access box: the account goes on
    -- pay-per-game with the new balance (status and end date untouched)
    to_left := (case when b.plan = 'pay_per_game' then b.game_credits else 0 end) + p_games;
    update public.goalie_access
       set plan = 'pay_per_game', game_credits = to_left, updated_at = now()
     where user_id = p_to;
  end if;

  from_left := a.game_credits - p_games;
  update public.goalie_access
     set game_credits = from_left, updated_at = now()
   where user_id = p_from;

  insert into public.game_credit_transfers (from_user, to_user, games, by_admin)
  values (p_from, p_to, p_games, auth.uid());

  return jsonb_build_object('from_left', from_left, 'to_left', to_left);
end;
$$;

revoke all on function public.transfer_game_credits(uuid, uuid, integer) from public, anon;
grant execute on function public.transfer_game_credits(uuid, uuid, integer) to authenticated;

-- Taylor's goalies (except Wesley, who bought his own games) are coach-managed.
update public.coach_goalie_assignments a
   set coach_managed = true
  from public.profiles c, public.profiles g
 where a.coach_id = c.id and a.goalie_id = g.id
   and c.full_name = 'Taylor Welsh'
   and g.full_name <> 'Wesley Gabrielse';
