-- A new game takes its goalie's standard game length (profiles.game_length_minutes)
-- unless it says otherwise: they played a full game of that length, so GAA and
-- the other rate stats scale correctly without going back to edit.
--  * game_length empty  -> the goalie's standard length
--  * minutes_played empty and no length given -> a full game (that length)
create or replace function public.default_game_length()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  std integer;
begin
  select game_length_minutes into std from public.profiles where id = new.user_id;
  if std is null or std < 10 or std > 90 then
    return new;
  end if;
  if new.game_length is null then
    if new.minutes_played is null then
      new.minutes_played := std;
    end if;
    new.game_length := std;
  end if;
  return new;
end;
$function$;

drop trigger if exists default_game_length on public."Games";
create trigger default_game_length
  before insert on public."Games"
  for each row execute function public.default_game_length();
