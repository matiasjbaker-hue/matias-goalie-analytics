-- ============================================================
-- Feedback drawn on a shot's video ("Mark up")
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste the whole
-- file -> Run. Safe to re-run.
--
-- An admin, or a coach assigned to the goalie, can pause a shot's clip
-- and draw or write on the frame. Each markup is one row: the moment in
-- the video it belongs to, and the drawing as JSON (strokes, circles,
-- arrows and text, positions stored as 0-1 of the video frame so they
-- line up at any size). The goalie can see it but not change it.

create table if not exists public.shot_annotations (
  id          bigint generated always as identity primary key,
  shot_id     bigint not null,
  goalie_id   uuid   not null references auth.users(id) on delete cascade,
  author_id   uuid   not null default auth.uid() references auth.users(id) on delete cascade,
  author_name text,
  video_time  numeric not null,
  items       jsonb  not null default '[]'::jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists shot_annotations_shot_idx
  on public.shot_annotations (shot_id);

create index if not exists shot_annotations_goalie_idx
  on public.shot_annotations (goalie_id);

alter table public.shot_annotations enable row level security;

drop policy if exists "View markups on my shots or my goalies" on public.shot_annotations;
create policy "View markups on my shots or my goalies"
  on public.shot_annotations for select
  using (goalie_id = auth.uid() or public.is_admin() or public.is_my_goalie(goalie_id));

drop policy if exists "Admin or assigned coach can add markups" on public.shot_annotations;
create policy "Admin or assigned coach can add markups"
  on public.shot_annotations for insert
  with check (
    author_id = auth.uid()
    and (public.is_admin() or public.is_my_goalie(goalie_id))
  );

drop policy if exists "Author or admin can change markups" on public.shot_annotations;
create policy "Author or admin can change markups"
  on public.shot_annotations for update
  using (author_id = auth.uid() or public.is_admin())
  with check (author_id = auth.uid() or public.is_admin());

drop policy if exists "Author or admin can delete markups" on public.shot_annotations;
create policy "Author or admin can delete markups"
  on public.shot_annotations for delete
  using (author_id = auth.uid() or public.is_admin());
