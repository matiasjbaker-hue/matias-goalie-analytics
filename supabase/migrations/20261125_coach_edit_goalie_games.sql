-- Coaches can edit the games and shots of goalies they coach (active link),
-- the same way the goalie or an admin can. They still can't delete a game.

-- The paywall check is on the goalie's own access; a coach's goalies are
-- covered by the coach, so the link is enough.
alter policy "Paywall: goalie must have access" on "Games"
  using (is_admin() or has_access(user_id) or is_my_goalie(user_id))
  with check (is_admin() or has_access(user_id) or is_my_goalie(user_id));

alter policy "Paywall: goalie must have access" on "Shots"
  using (is_admin() or has_access(user_id) or is_my_goalie(user_id))
  with check (is_admin() or has_access(user_id) or is_my_goalie(user_id));

create policy "Coaches can update their goalies' games" on "Games"
  for update using (is_my_goalie(user_id)) with check (is_my_goalie(user_id));

create policy "Coaches can update their goalies' shots" on "Shots"
  for update using (is_my_goalie(user_id)) with check (is_my_goalie(user_id));

create policy "Coaches can add shots for their goalies" on "Shots"
  for insert with check (is_my_goalie(user_id));

create policy "Coaches can delete their goalies' shots" on "Shots"
  for delete using (is_my_goalie(user_id));
