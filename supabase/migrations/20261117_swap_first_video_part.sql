-- Lets an admin reorder a request's files including Part 1: the chosen
-- extra file (the one right after Part 1) becomes the request and the old
-- Part 1 becomes an extra file. Request-level fields move with the request;
-- file-level data (shots, drafts, clips, YOLO state, period marks) stays on
-- its own file. Admin only.
create or replace function public.swap_first_video_part(p_root bigint, p_part bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.game_videos;
  p public.game_videos;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can do this.' using errcode = '42501';
  end if;

  select * into r from public.game_videos where id = p_root for update;
  if not found then raise exception 'Video not found.'; end if;
  if r.parent_video_id is not null then raise exception 'That file is not the first file of a request.'; end if;

  select * into p from public.game_videos where id = p_part for update;
  if not found or p.parent_video_id is distinct from r.id or p.status = 'clip' then
    raise exception 'That file is not an extra file of this request.';
  end if;

  -- keep the coach payment on the request through the swap
  update public.game_videos set paid_by_coach = null where id in (r.id, p.id);

  -- the chosen file becomes the request
  update public.game_videos set
    parent_video_id = null,
    part_order = null,
    game_id = r.game_id,
    requested_game = r.requested_game,
    team_jersey_color = r.team_jersey_color,
    admin_note = r.admin_note,
    paid_by_coach = r.paid_by_coach
  where id = p.id;

  -- other extra files follow the new request (clips stay with their file)
  update public.game_videos set parent_video_id = p.id
   where parent_video_id = r.id and id <> p.id and status is distinct from 'clip';

  -- the old Part 1 becomes the extra file right after the new Part 1
  update public.game_videos set
    parent_video_id = p.id,
    part_order = 0,
    requested_game = null,
    admin_note = null
  where id = r.id;

  -- number the extra files 0..n with the old Part 1 first
  update public.game_videos g set part_order = o.n
    from (
      select id, row_number() over (order by (id = r.id) desc, part_order nulls last, created_at, id) - 1 as n
        from public.game_videos
       where parent_video_id = p.id and status is distinct from 'clip'
    ) o
   where g.id = o.id;

  return jsonb_build_object('newRootId', p.id);
end;
$$;
revoke all on function public.swap_first_video_part(bigint, bigint) from public, anon;
grant execute on function public.swap_first_video_part(bigint, bigint) to authenticated;
