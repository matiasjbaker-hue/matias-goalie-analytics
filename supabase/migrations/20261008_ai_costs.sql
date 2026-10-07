-- ============================================================
-- AI cost ledger: what each video's AI work cost, per call
-- ============================================================
-- Run once in Supabase: Dashboard -> SQL Editor -> paste -> Run.
-- Safe to re-run.
--
-- The server (api/video/analyze-clip.js) writes one row per AI call,
-- priced from the token counts Anthropic returns with every answer, so
-- a video's cost is known the moment its AI work finishes (Anthropic's
-- own console only totals costs per day). Only the server writes rows
-- (service key); only admins can read them. Goalies never see costs.

create table if not exists public.ai_usage (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  game_video_id      bigint references public.game_videos(id) on delete set null,
  requested_by       uuid,
  kind               text not null,          -- detect, tag, detect-batch
  model              text,
  batch              boolean not null default false,
  batch_id           text unique,            -- a batch is only ever logged once
  input_tokens       integer not null default 0,
  output_tokens      integer not null default 0,
  cache_read_tokens  integer not null default 0,
  cache_write_tokens integer not null default 0,
  usd                numeric(12, 6)          -- null when the model's price isn't known
);

create index if not exists ai_usage_video_idx on public.ai_usage (game_video_id);
create index if not exists ai_usage_created_idx on public.ai_usage (created_at);

alter table public.ai_usage enable row level security;

drop policy if exists "admin reads ai usage" on public.ai_usage;
create policy "admin reads ai usage"
  on public.ai_usage for select
  to authenticated
  using (coalesce(public.is_admin(), false));

-- This project doesn't grant new tables automatically.
grant select on public.ai_usage to authenticated;
grant all on public.ai_usage to service_role;
grant usage, select on sequence public.ai_usage_id_seq to service_role;

notify pgrst, 'reload schema';
