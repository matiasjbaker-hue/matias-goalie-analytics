-- A coach can upload game film for a goalie they're actively assigned to.
-- The film and its request row belong to the goalie (user_id = the
-- goalie), so it shows in their account and the admin review queue like
-- any other upload. Admins and goalies keep exactly what they had.
-- The restrictive "Paywall" policy still applies on top of this.
drop policy if exists "Insert own game_videos, admin for anyone" on public.game_videos;
drop policy if exists "Insert own game_videos, admin or assigned coach" on public.game_videos;

create policy "Insert own game_videos, admin or assigned coach"
  on public.game_videos
  for insert
  with check (
    user_id = auth.uid()
    or public.is_admin()
    or public.is_my_goalie(user_id)
  );
