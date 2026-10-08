alter table public.profiles
  add column if not exists height_in integer,
  add column if not exists weight_lbs integer,
  add column if not exists catches text,
  add column if not exists level text,
  add column if not exists league text,
  add column if not exists birthplace text;

alter table public.profiles drop constraint if exists profiles_catches_check;
alter table public.profiles add constraint profiles_catches_check check (catches is null or catches in ('L','R'));
alter table public.profiles drop constraint if exists profiles_height_in_check;
alter table public.profiles add constraint profiles_height_in_check check (height_in is null or height_in between 36 and 96);
alter table public.profiles drop constraint if exists profiles_weight_lbs_check;
alter table public.profiles add constraint profiles_weight_lbs_check check (weight_lbs is null or weight_lbs between 40 and 400);
