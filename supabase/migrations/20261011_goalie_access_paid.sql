-- Explicit "has paid" marker on goalie_access.
--
-- Status alone can't say who has paid: free-first-game goalies are stored
-- as status 'active' / plan 'pay_per_game', the same as paying ones. The
-- admin Accounts page uses this column (plus purchase records and active
-- Stripe subscriptions) to label an account Paid, Free trial or Free, and
-- the Access settings modal sets it when you pick Paid.

alter table public.goalie_access
  add column if not exists paid boolean not null default false;

-- Backfill from what we already know: a recorded purchase, an active
-- Stripe subscription, or a note saying they paid (e-transfers).
update public.goalie_access a
set paid = true
where a.paid = false
  and (
    exists (select 1 from public.game_credit_purchases c where c.user_id = a.user_id)
    or (a.stripe_subscription_id is not null and a.status = 'active')
    or (a.note ~* '\ypaid\y' and a.note !~* '\y(not|un)\s?paid\y')
  );

-- Future Stripe purchases mark the account as paid automatically.
create or replace function public.grant_game_credits(p_user uuid, p_credits integer, p_session text, p_amount integer, p_currency text, p_customer text)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  inserted int;
  new_balance int;
begin
  if p_credits is null or p_credits <= 0 then
    raise exception 'Invalid credit amount';
  end if;

  insert into public.game_credit_purchases (stripe_session_id, user_id, credits, amount_total, currency)
  values (p_session, p_user, p_credits, p_amount, p_currency)
  on conflict (stripe_session_id) do nothing;
  get diagnostics inserted = row_count;

  if inserted = 0 then
    select game_credits into new_balance from public.goalie_access where user_id = p_user;
    return coalesce(new_balance, 0); -- already processed
  end if;

  insert into public.goalie_access (user_id, status, plan, access_until, game_credits, stripe_customer_id, note, paid)
  values (p_user, 'active', 'pay_per_game', null, p_credits, p_customer, 'Pay per game', true)
  on conflict (user_id) do update set
    status = case when goalie_access.status = 'comp' then 'comp' else 'active' end,
    plan = case when goalie_access.status = 'comp' then goalie_access.plan else 'pay_per_game' end,
    access_until = case when goalie_access.status = 'comp' then goalie_access.access_until else null end,
    game_credits = goalie_access.game_credits + excluded.game_credits,
    stripe_customer_id = coalesce(excluded.stripe_customer_id, goalie_access.stripe_customer_id),
    paid = true,
    updated_at = now()
  returning game_credits into new_balance;

  return new_balance;
end;
$function$;
