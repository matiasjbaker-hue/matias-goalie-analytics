-- A goalie whose coach covers their games can upload film themselves and the
-- upload uses one of the COACH's games. No more topping goalies up by hand.
--
--  * coach_covering(goalie): the coach (if any) who covers this goalie: an
--    active assignment that is not "goalie_pays_own", whose coach has a game
--    left (or isn't limited to a count).
--  * coach_sponsor_game_video(): when the goalie uploads a NEW game, take one
--    game from that coach and mark the upload paid_by_coach, exactly like a
--    coach upload. Admin approval then bills the coach (Games.billed_to), and
--    deleting an unapproved upload returns the game to the coach.
--  * Paywall policy: a goalie covered by their coach can upload even without
--    their own access row.
--  * my_coach_cover(): lets the goalie's upload page say whose games it uses.
-- If the coach is out of games, nothing changes: the goalie's own games apply.

create or replace function public.coach_covering(p_goalie uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select a.coach_id
    from public.coach_goalie_assignments a
    left join public.goalie_access c on c.user_id = a.coach_id
   where a.goalie_id = p_goalie
     and a.active
     and not coalesce(a.goalie_pays_own, false)
     and (c.user_id is null
          or c.plan is distinct from 'pay_per_game'
          or c.status <> 'active'
          or c.game_credits > 0)
   order by a.id
   limit 1;
$$;

create or replace function public.my_coach_cover()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare cov uuid; nm text; gl integer;
begin
  if auth.uid() is null then return null; end if;
  cov := public.coach_covering(auth.uid());
  if cov is null then return null; end if;
  select full_name into nm from public.profiles where id = cov;
  select case when plan = 'pay_per_game' and status = 'active' then game_credits end
    into gl from public.goalie_access where user_id = cov;
  return jsonb_build_object('coach_name', nm, 'games_left', gl);
end;
$$;

revoke all on function public.my_coach_cover() from public;
grant execute on function public.my_coach_cover() to authenticated;

create or replace function public.coach_sponsor_game_video()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  acc public.goalie_access; caller uuid := auth.uid(); is_part boolean := false; own_pays boolean := false;
  cov uuid; cov_counted boolean := false;
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

  -- The goalie uploads their own new game and their coach covers it.
  if caller = new.user_id then
    if not is_part and new.game_id is null and new.requested_game is not null then
      cov := public.coach_covering(caller);
      if cov is not null then
        select * into acc from public.goalie_access where user_id = cov for update;
        cov_counted := found and acc.plan = 'pay_per_game' and acc.status = 'active';
        if cov_counted and acc.game_credits <= 0 then
          cov := null; -- ran out a moment ago: the goalie's own games apply
        end if;
        if cov is not null then
          if cov_counted then
            perform set_config('app.credit_reason', 'Goalie upload (coach covers)', true);
            perform set_config('app.credit_other', caller::text, true);
            update public.goalie_access set game_credits = game_credits - 1, updated_at = now() where user_id = cov;
          end if;
          new.paid_by_coach := cov;
        end if;
      end if;
    end if;
    return new;
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

drop policy if exists "Paywall: goalie must have access" on public.game_videos;
create policy "Paywall: goalie must have access" on public.game_videos
  as restrictive for all
  using (public.is_admin() or public.has_access(user_id) or public.coach_covering(user_id) is not null)
  with check (public.is_admin() or public.has_access(user_id) or public.coach_covering(user_id) is not null);
