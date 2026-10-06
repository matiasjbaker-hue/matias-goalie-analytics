-- ============================================================
-- Read-only security checks for the GoalieIQ database
-- ============================================================
-- Paste into Supabase -> SQL Editor and run. Nothing here changes data.
-- The row-level security (RLS) policies live in the database, not in
-- this repo, so they can only be reviewed from there.

-- 1. Every table the browser can reach must have RLS switched on.
--    Any row with rls_enabled = false is readable/writable by anyone
--    holding the public (publishable) key -- which is everyone.
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relrowsecurity, c.relname;

-- 2. Every policy, per table. Look for:
--    - goalie_access / game_credit tables: NO insert/update/delete
--      policy for "authenticated" users (only the server, using the
--      service key, may grant paid access or credits);
--    - profiles: an UPDATE policy that lets a user write their own row
--      is fine only together with the role guard trigger in
--      migrations/20261006_ai_clip_tagging.sql;
--    - any policy whose USING / WITH CHECK is just "true".
select tablename, policyname, cmd, roles, qual as using_expr, with_check
from pg_policies
where schemaname = 'public'
order by tablename, cmd, policyname;

-- 3. Functions that run with the owner's rights (SECURITY DEFINER) and
--    that the public API can call. Each should check auth.uid() /
--    is_admin() itself before doing anything sensitive.
select p.proname as function_name,
       p.prosecdef as security_definer,
       has_function_privilege('anon', p.oid, 'execute') as anon_can_call,
       has_function_privilege('authenticated', p.oid, 'execute') as signed_in_can_call
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosecdef
order by p.proname;

-- 4. Video rows that share a file path, or point outside their owner's
--    folder. Rows in an admin's folder are older admin-uploaded clips
--    and are expected; anything else deserves a look.
select storage_path, array_agg(id) as row_ids, array_agg(distinct user_id) as owners
from public.game_videos
group by storage_path
having count(*) > 1;

select v.id, v.user_id, v.status, v.storage_path, p.role as folder_owner_role
from public.game_videos v
left join public.profiles p on p.id::text = split_part(v.storage_path, '/', 1)
where split_part(v.storage_path, '/', 1) <> v.user_id::text
order by p.role nulls first, v.id;
