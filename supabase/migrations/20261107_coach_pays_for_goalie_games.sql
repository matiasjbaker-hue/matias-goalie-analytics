-- A coach can sponsor a goalie's game: the coach's game balance
-- (goalie_access.game_credits on the coach's own account) pays for it,
-- not the goalie's.
--
--  * When a coach uploads film for a NEW game for an assigned goalie,
--    one of the coach's games is reserved right then (so they can't
--    upload more than they have) and the request is stamped with
--    paid_by_coach.
--  * When the admin approves it, the game is created with billed_to =
--    that coach and the goalie is not charged.
--  * If the request is deleted before it became a game, the coach gets
--    the game back.
--  * A coach on a free / comp / trial plan (not pay-per-game) isn't
--    limited, same as goalies on those plans.
-- Only an admin (or the server) can set these two columns.

alter table public.game_videos add column if not exists paid_by_coach uuid references auth.users(id);
alter table public."Games" add column if not exists billed_to uuid references auth.users(id);

create or replace function public.coach_sponsor_game_video()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  acc public.goalie_access;
  caller uuid := auth.uid();
begin
  if tg_op = 'UPDATE' then
    -- nobody but an admin / the server can move who pays
    if caller is not null and not public.is_admin() then
      new.paid_by_coach := old.paid_by_coach;
    end if;
    return new;
  end if;

  -- INSERT
  new.paid_by_coach := null;

  if caller is null or public.is_admin() then
    return new;
  end if;

  if new.user_id is distinct from caller
     and public.is_my_goalie(new.user_id)
     and new.game_id is null
     and new.parent_video_id is null
     and new.requested_game is not null then

    select * into acc from public.goalie_access where user_id = caller for update;

    if found and acc.plan = 'pay_per_game' and acc.status = 'active' then
      if acc.game_credits <= 0 then
        raise exception 'You have no games left. Ask Matias for more games.' using errcode = 'P0001';
      end if;
      update public.goalie_access
         set game_credits = game_credits - 1, updated_at = now()
       where user_id = caller;
    end if;

    new.paid_by_coach := caller;
  end if;

  return new;
end;
$function$;

drop trigger if exists coach_sponsor_game_video on public.game_videos;
create trigger coach_sponsor_game_video
  before insert or update on public.game_videos
  for each row execute function public.coach_sponsor_game_video();

-- Give the game back if a coach-paid request is removed before it became a game.
create or replace function public.refund_coach_game_video()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if old.paid_by_coach is not null and old.game_id is null then
    update public.goalie_access
       set game_credits = game_credits + 1, updated_at = now()
     where user_id = old.paid_by_coach and plan = 'pay_per_game' and status = 'active';
  end if;
  return old;
end;
$function$;

drop trigger if exists refund_coach_game_video on public.game_videos;
create trigger refund_coach_game_video
  after delete on public.game_videos
  for each row execute function public.refund_coach_game_video();

-- The game charge: skip the goalie when a coach already paid.
create or replace function public.consume_game_credit()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  acc public.goalie_access;
begin
  if new.billed_to is not null then
    if auth.uid() is null or public.is_admin() then
      return new; -- a coach already paid for this game
    end if;
    new.billed_to := null; -- only an admin / the server can say a coach paid
  end if;

  select * into acc from public.goalie_access where user_id = new.user_id for update;
  if not found or acc.plan is distinct from 'pay_per_game' or acc.status <> 'active' then
    return new; -- comp / legacy plans: unlimited
  end if;

  if acc.game_credits <= 0 and not is_admin() then
    raise exception 'You have no games left. Buy more games to add this one.' using errcode = 'P0001';
  end if;

  update public.goalie_access
     set game_credits = game_credits - 1, updated_at = now()
   where user_id = new.user_id;

  return new;
end;
$function$;
