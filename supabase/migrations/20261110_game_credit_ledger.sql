-- One history of every change to anyone's game balance, with the reason.
create table if not exists public.game_credit_ledger (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null references auth.users(id) on delete cascade,
  delta integer not null,
  balance_after integer not null,
  reason text not null,
  other_user uuid,            -- who the games came from / went to, if any
  actor uuid                  -- who made the change (null = system/webhook)
);
create index if not exists game_credit_ledger_user_idx on public.game_credit_ledger (user_id, created_at desc);
alter table public.game_credit_ledger enable row level security;
drop policy if exists "Read own ledger, admin all, coach assigned" on public.game_credit_ledger;
create policy "Read own ledger, admin all, coach assigned" on public.game_credit_ledger
  for select using (user_id = auth.uid() or public.is_admin() or public.is_my_goalie(user_id));

create or replace function public.log_game_credit_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  d integer;
  why text := nullif(current_setting('app.credit_reason', true), '');
  other uuid := nullif(current_setting('app.credit_other', true), '')::uuid;
begin
  if tg_op = 'INSERT' then
    d := coalesce(new.game_credits, 0);
  else
    d := coalesce(new.game_credits, 0) - coalesce(old.game_credits, 0);
  end if;
  if d = 0 then return new; end if;
  insert into public.game_credit_ledger (user_id, delta, balance_after, reason, other_user, actor)
  values (new.user_id, d, coalesce(new.game_credits, 0),
          coalesce(why, case when public.is_admin() then 'Set by admin' else 'Other change' end),
          case when why is null then null else other end,
          auth.uid());
  perform set_config('app.credit_reason', '', true);
  perform set_config('app.credit_other', '', true);
  return new;
end;
$$;
drop trigger if exists log_game_credit_change on public.goalie_access;
create trigger log_game_credit_change after insert or update of game_credits on public.goalie_access
  for each row execute function public.log_game_credit_change();

-- Opening balances so the ledger adds up to what each account has today.
insert into public.game_credit_ledger (user_id, delta, balance_after, reason)
select user_id, game_credits, game_credits, 'Balance before the ledger started'
from public.goalie_access where coalesce(game_credits, 0) <> 0
and not exists (select 1 from public.game_credit_ledger l where l.user_id = goalie_access.user_id);

-- Tag the places that change a balance.
create or replace function public.transfer_game_credits(p_from uuid, p_to uuid, p_games integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a public.goalie_access; b public.goalie_access; from_left integer; to_left integer; b_found boolean;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only an admin can move games between accounts.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'Pick two different accounts.'; end if;
  if p_games is null or p_games < 1 or p_games > 1000 then raise exception 'Enter a number of games from 1 to 1000.'; end if;

  perform 1 from public.goalie_access where user_id in (p_from, p_to) order by user_id for update;

  select * into a from public.goalie_access where user_id = p_from;
  if not found or a.plan is distinct from 'pay_per_game' or a.status <> 'active' then
    raise exception 'The account you are taking games from is not on pay-per-game, so it has no games to move.';
  end if;
  if a.game_credits < p_games then raise exception 'That account only has % game(s) left.', a.game_credits; end if;

  select * into b from public.goalie_access where user_id = p_to;
  b_found := found;
  perform set_config('app.credit_reason', 'Moved to another account', true);
  perform set_config('app.credit_other', p_to::text, true);
  from_left := a.game_credits - p_games;
  update public.goalie_access set game_credits = from_left, updated_at = now() where user_id = p_from;

  perform set_config('app.credit_reason', 'Moved from another account', true);
  perform set_config('app.credit_other', p_from::text, true);
  if not b_found then
    insert into public.goalie_access (user_id, status, plan, game_credits, paid, granted_by, updated_at)
    values (p_to, 'active', 'pay_per_game', p_games, false, auth.uid(), now());
    to_left := p_games;
  else
    to_left := (case when b.plan = 'pay_per_game' then b.game_credits else 0 end) + p_games;
    update public.goalie_access set plan = 'pay_per_game', game_credits = to_left, updated_at = now() where user_id = p_to;
  end if;

  insert into public.game_credit_transfers (from_user, to_user, games, by_admin) values (p_from, p_to, p_games, auth.uid());
  return jsonb_build_object('from_left', from_left, 'to_left', to_left);
end;
$$;

create or replace function public.consume_game_credit()
returns trigger language plpgsql security definer set search_path = public as $$
declare acc public.goalie_access;
begin
  if new.billed_to is not null then
    if auth.uid() is null or public.is_admin() then return new; end if;
    new.billed_to := null;
  end if;
  select * into acc from public.goalie_access where user_id = new.user_id for update;
  if not found or acc.plan is distinct from 'pay_per_game' or acc.status <> 'active' then return new; end if;
  if acc.game_credits <= 0 and not is_admin() then
    raise exception 'You have no games left. Buy more games to add this one.' using errcode = 'P0001';
  end if;
  perform set_config('app.credit_reason', 'Game added', true);
  update public.goalie_access set game_credits = game_credits - 1, updated_at = now() where user_id = new.user_id;
  return new;
end;
$$;

create or replace function public.refund_coach_game_video()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.paid_by_coach is not null and old.game_id is null then
    perform set_config('app.credit_reason', 'Upload deleted, game returned', true);
    perform set_config('app.credit_other', old.user_id::text, true);
    update public.goalie_access set game_credits = game_credits + 1, updated_at = now()
     where user_id = old.paid_by_coach and plan = 'pay_per_game' and status = 'active';
  end if;
  return old;
end;
$$;

create or replace function public.coach_sponsor_game_video()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  acc public.goalie_access; caller uuid := auth.uid(); is_part boolean := false; own_pays boolean := false;
begin
  if tg_op = 'UPDATE' then
    if caller is not null and not public.is_admin() then new.paid_by_coach := old.paid_by_coach; end if;
    return new;
  end if;
  new.paid_by_coach := null;
  if caller is null or public.is_admin() then return new; end if;
  if new.parent_video_id is not null then
    select exists (
      select 1 from public.game_videos p
       where p.id = new.parent_video_id and p.user_id = new.user_id and p.parent_video_id is null
         and p.status is distinct from 'clip' and coalesce(p.review_status, 'received') = 'received'
    ) into is_part;
  end if;
  select exists (
    select 1 from public.coach_goalie_assignments a
     where a.coach_id = caller and a.goalie_id = new.user_id and a.active and a.goalie_pays_own
  ) into own_pays;
  if not is_part and not own_pays and new.user_id is distinct from caller
     and public.is_my_goalie(new.user_id) and new.game_id is null and new.requested_game is not null then
    select * into acc from public.goalie_access where user_id = caller for update;
    if found and acc.plan = 'pay_per_game' and acc.status = 'active' then
      if acc.game_credits <= 0 then
        raise exception 'You have no games left. Ask Matias for more games.' using errcode = 'P0001';
      end if;
      perform set_config('app.credit_reason', 'Coach upload for a goalie', true);
      perform set_config('app.credit_other', new.user_id::text, true);
      update public.goalie_access set game_credits = game_credits - 1, updated_at = now() where user_id = caller;
    end if;
    new.paid_by_coach := caller;
  end if;
  return new;
end;
$$;

create or replace function public.start_free_trial()
returns goalie_access language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); row public.goalie_access;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = me and role = 'goalie') then
    raise exception 'Only goalie accounts can start a trial';
  end if;
  if exists (select 1 from public.goalie_access where user_id = me) then
    raise exception 'Free game already used on this account';
  end if;
  if public.free_game_blocked(me) then
    raise exception 'Your coach covers your games, so there is no free game on this account. Ask your coach to set you up.';
  end if;
  perform set_config('app.credit_reason', 'Free first game', true);
  insert into public.goalie_access (user_id, status, access_until, plan, game_credits, note)
  values (me, 'active', null, 'pay_per_game', 1, 'Free first game') returning * into row;
  return row;
end;
$$;

create or replace function public.grant_game_credits(p_user uuid, p_credits integer, p_session text, p_amount integer, p_currency text, p_customer text)
returns integer language plpgsql security definer set search_path = public as $$
declare inserted int; new_balance int;
begin
  if p_credits is null or p_credits <= 0 then raise exception 'Invalid credit amount'; end if;
  insert into public.game_credit_purchases (stripe_session_id, user_id, credits, amount_total, currency)
  values (p_session, p_user, p_credits, p_amount, p_currency) on conflict (stripe_session_id) do nothing;
  get diagnostics inserted = row_count;
  if inserted = 0 then
    select game_credits into new_balance from public.goalie_access where user_id = p_user;
    return coalesce(new_balance, 0);
  end if;
  perform set_config('app.credit_reason', 'Bought games', true);
  insert into public.goalie_access (user_id, status, plan, access_until, game_credits, stripe_customer_id, note, paid)
  values (p_user, 'active', 'pay_per_game', null, p_credits, p_customer, 'Pay per game', true)
  on conflict (user_id) do update set
    status = case when goalie_access.status = 'comp' then 'comp' else 'active' end,
    plan = case when goalie_access.status = 'comp' then goalie_access.plan else 'pay_per_game' end,
    access_until = case when goalie_access.status = 'comp' then goalie_access.access_until else null end,
    game_credits = goalie_access.game_credits + excluded.game_credits,
    stripe_customer_id = coalesce(excluded.stripe_customer_id, goalie_access.stripe_customer_id),
    paid = true, updated_at = now()
  returning game_credits into new_balance;
  return new_balance;
end;
$$;

grant select on public.game_credit_ledger to authenticated;
