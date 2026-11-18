-- Remove a request's first file (Part 1) while keeping its other files.
-- The next file becomes the request: it inherits the game, jersey colour,
-- coach payment and note, and the remaining files are re-parented to it.
-- Admin only. Returns the removed file's storage path so the API can
-- delete it from R2. Shots published from the removed file keep their stats
-- but lose the link to the film.
create or replace function public.promote_next_video_part(p_root bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.game_videos;
  nxt public.game_videos;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can do this.' using errcode = '42501';
  end if;

  select * into r from public.game_videos where id = p_root for update;
  if not found then raise exception 'Video not found.'; end if;
  if r.parent_video_id is not null then raise exception 'That file is not the first file of a request.'; end if;

  select * into nxt from public.game_videos
   where parent_video_id = p_root and status is distinct from 'clip'
   order by part_order nulls last, created_at, id
   limit 1;
  if not found then raise exception 'This request has no other file to promote.'; end if;

  -- Stop the delete from refunding a coach whose request lives on.
  update public.game_videos set paid_by_coach = null where id = r.id;

  update public.game_videos set
    parent_video_id = null,
    part_order = null,
    game_id = coalesce(nxt.game_id, r.game_id),
    requested_game = coalesce(r.requested_game, nxt.requested_game),
    team_jersey_color = coalesce(nxt.team_jersey_color, r.team_jersey_color),
    paid_by_coach = r.paid_by_coach,
    admin_note = coalesce(nxt.admin_note, r.admin_note)
  where id = nxt.id;

  -- clips cut from the removed file go with it
  delete from public.game_videos where parent_video_id = r.id and status = 'clip';
  update public.game_videos set parent_video_id = nxt.id where parent_video_id = r.id and id <> nxt.id;

  update public."Shots" set game_video_id = null, clip_start_seconds = null, clip_end_seconds = null
   where game_video_id = r.id;

  delete from public.game_videos where id = r.id;

  return jsonb_build_object('newRootId', nxt.id, 'storagePath', r.storage_path);
end;
$$;
revoke all on function public.promote_next_video_part(bigint) from public, anon;
grant execute on function public.promote_next_video_part(bigint) to authenticated;
