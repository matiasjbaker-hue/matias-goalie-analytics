-- A coach (or the goalie themselves) can add extra files to a game film
-- request they just uploaded: Part 2, Part 3 ...
--
-- Until now the guard reset parent_video_id to null on every non-admin
-- insert, so only an admin could attach an extra file. Now a non-admin
-- insert keeps parent_video_id when ALL of these hold:
--   * the caller is the goalie, or a coach assigned to that goalie
--   * the parent request exists, is the same goalie's, is a first file
--     (not itself a part) and isn't a clip
--   * the parent request hasn't been picked up for review yet
--     (review_status = 'received')
-- Extra files never cost a game: coach_sponsor_game_video only reserves
-- a game for a first file (parent_video_id is null).

create or replace function public.guard_video_review_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  keep_parent bigint := null;
begin
  if coalesce(auth.role(), '') = 'service_role' or coalesce(public.is_admin(), false) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.parent_video_id is not null
       and (auth.uid() = new.user_id or public.is_my_goalie(new.user_id))
       and exists (
         select 1 from public.game_videos p
          where p.id = new.parent_video_id
            and p.user_id = new.user_id
            and p.parent_video_id is null
            and p.status is distinct from 'clip'
            and coalesce(p.review_status, 'received') = 'received'
       ) then
      keep_parent := new.parent_video_id;
    end if;

    new.review_status := 'received';
    new.admin_note := null;
    new.reviewed_by := null;
    new.approved_at := null;
    new.scan_cursor := 0;
    new.scan_progress := 0;
    new.parent_video_id := keep_parent;
    return new;
  end if;

  if new.review_status is distinct from old.review_status
     or new.admin_note is distinct from old.admin_note
     or new.reviewed_by is distinct from old.reviewed_by
     or new.approved_at is distinct from old.approved_at
     or new.period_marks is distinct from old.period_marks
     or new.scan_cursor is distinct from old.scan_cursor
     or new.scan_progress is distinct from old.scan_progress
     or new.parent_video_id is distinct from old.parent_video_id then
    raise exception 'Only an admin can change a video''s review.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- The coach-sponsor trigger runs BEFORE the guard above, so it has to
-- decide "is this a genuine extra file?" with the same test, otherwise a
-- fake parent id would skip the charge and then be cleared by the guard.
create or replace function public.coach_sponsor_game_video()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  acc public.goalie_access;
  caller uuid := auth.uid();
  is_part boolean := false;
begin
  if tg_op = 'UPDATE' then
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

  if new.parent_video_id is not null then
    select exists (
      select 1 from public.game_videos p
       where p.id = new.parent_video_id
         and p.user_id = new.user_id
         and p.parent_video_id is null
         and p.status is distinct from 'clip'
         and coalesce(p.review_status, 'received') = 'received'
    ) into is_part;
  end if;

  if not is_part
     and new.user_id is distinct from caller
     and public.is_my_goalie(new.user_id)
     and new.game_id is null
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
