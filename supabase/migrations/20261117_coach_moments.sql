-- Coach moments: a coach (or admin) flags a moment in a goalie's game film,
-- cuts a clip of it and adds feedback (the same drawing / voice markup used
-- on shots). The goalie sees it straight away; the coach and admin too.
create table if not exists public.coach_moments (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  goalie_id uuid not null references auth.users(id) on delete cascade,
  game_id bigint,
  game_video_id bigint references public.game_videos(id) on delete cascade, -- the full film it was flagged on
  author_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  author_name text,
  t_seconds numeric not null,
  title text,
  clip_start_seconds numeric,
  clip_end_seconds numeric,
  clip_video_id bigint references public.game_videos(id) on delete set null -- the cut clip (game_videos, status "clip")
);
create index if not exists coach_moments_video_idx on public.coach_moments (game_video_id);
create index if not exists coach_moments_goalie_idx on public.coach_moments (goalie_id);
alter table public.coach_moments enable row level security;

drop policy if exists "View my moments or my goalies" on public.coach_moments;
create policy "View my moments or my goalies" on public.coach_moments for select
  using (goalie_id = auth.uid() or public.is_admin() or public.is_my_goalie(goalie_id));
drop policy if exists "Admin or assigned coach adds moments" on public.coach_moments;
create policy "Admin or assigned coach adds moments" on public.coach_moments for insert
  with check (author_id = auth.uid() and (public.is_admin() or public.is_my_goalie(goalie_id)));
drop policy if exists "Author or admin changes moments" on public.coach_moments;
create policy "Author or admin changes moments" on public.coach_moments for update
  using (author_id = auth.uid() or public.is_admin()) with check (author_id = auth.uid() or public.is_admin());
drop policy if exists "Author or admin deletes moments" on public.coach_moments;
create policy "Author or admin deletes moments" on public.coach_moments for delete
  using (author_id = auth.uid() or public.is_admin());
grant select, insert, update, delete on public.coach_moments to authenticated;

-- Feedback markup can hang off a moment instead of a shot.
alter table public.shot_annotations
  add column if not exists moment_id bigint references public.coach_moments(id) on delete cascade;
create index if not exists shot_annotations_moment_idx on public.shot_annotations (moment_id) where moment_id is not null;
