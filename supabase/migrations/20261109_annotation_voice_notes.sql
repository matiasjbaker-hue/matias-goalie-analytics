-- Voice notes on Mark up feedback.
-- A coach or admin can record a voice note while marking up a frame. The
-- audio goes in the private 'voice-notes' bucket under <goalie id>/<file>,
-- and the markup row remembers it in audio_path. The goalie, their coaches
-- and admins can listen (signed links); only the goalie's coach or an admin
-- can upload; the author or an admin can delete.
-- (Applied to prod as annotation_voice_notes.)

alter table public.shot_annotations add column if not exists audio_path text;

insert into storage.buckets (id, name, public, file_size_limit)
values ('voice-notes', 'voice-notes', false, 15728640)
on conflict (id) do nothing;

-- policies: see the apply_migration "annotation_voice_notes" in Supabase:
--   upload  -> folder is a uuid and (is_admin() or is_my_goalie(folder))
--   listen  -> folder = auth.uid() or is_admin() or is_my_goalie(folder)
--   delete  -> owner = auth.uid() or is_admin()
