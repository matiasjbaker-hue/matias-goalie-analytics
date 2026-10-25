-- ============================================================
-- Profile pictures and "how did you hear about us"
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste the whole
-- file -> Run. Safe to re-run.
--
--   avatar_url        a small square photo (resized in the browser to
--                     about 200px, stored as a data URL)
--   heard_from        the answer to "how did you hear about us" at signup
--   heard_from_other  the free text when they pick "Other"
--
-- The signup trigger now copies the answer from the signup form onto the
-- new profile. People can already update their own profile row, so no
-- new access rules are needed; the size limit keeps a photo small.

alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists heard_from text;
alter table public.profiles add column if not exists heard_from_other text;

alter table public.profiles drop constraint if exists profiles_avatar_size;
alter table public.profiles
  add constraint profiles_avatar_size
  check (avatar_url is null or (length(avatar_url) <= 60000 and avatar_url like 'data:image/%'));

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.profiles (id, full_name, role, heard_from, heard_from_other)
  values (
    new.id,
    new.raw_user_meta_data ->> 'name',
    'goalie',
    nullif(left(new.raw_user_meta_data ->> 'heard_from', 80), ''),
    nullif(left(new.raw_user_meta_data ->> 'heard_from_other', 200), '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
