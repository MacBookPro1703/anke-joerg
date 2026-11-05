-- =====================================================================
-- Anke & Jörg – Datenbank-Schema für Supabase (einmal im SQL-Editor ausführen)
-- Kann gefahrlos mehrfach ausgeführt werden.
-- =====================================================================
create extension if not exists pgcrypto;

-- Räume (ein Raum = ihr beide) und Mitglieder (Geräte)
create table if not exists public.spaces (
  id uuid primary key default gen_random_uuid(),
  secret text not null unique default encode(gen_random_bytes(18), 'hex'),
  created_at timestamptz not null default now()
);
create table if not exists public.members (
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('je','anke')),
  created_at timestamptz not null default now(),
  primary key (space_id, user_id)
);

create or replace function public.is_member(s uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.members where space_id = s and user_id = auth.uid());
$$;

create or replace function public.create_space(p_role text) returns json
language plpgsql security definer set search_path = public as $$
declare sp public.spaces;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if p_role not in ('je','anke') then raise exception 'Ungültige Rolle'; end if;
  insert into public.spaces default values returning * into sp;
  insert into public.members (space_id, user_id, role) values (sp.id, auth.uid(), p_role);
  return json_build_object('space_id', sp.id, 'secret', sp.secret);
end $$;

create or replace function public.join_space(p_secret text, p_role text) returns json
language plpgsql security definer set search_path = public as $$
declare sp public.spaces;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if p_role not in ('je','anke') then raise exception 'Ungültige Rolle'; end if;
  select * into sp from public.spaces where secret = p_secret;
  if not found then raise exception 'Einladungslink ungültig'; end if;
  if not exists (select 1 from public.members where space_id = sp.id and user_id = auth.uid())
     and (select count(*) from public.members where space_id = sp.id) >= 10 then
    raise exception 'Zu viele Geräte in diesem Raum';
  end if;
  insert into public.members (space_id, user_id, role) values (sp.id, auth.uid(), p_role)
    on conflict (space_id, user_id) do update set role = excluded.role;
  return json_build_object('space_id', sp.id, 'secret', sp.secret);
end $$;

create or replace function public.space_secret(s uuid) returns text
language sql security definer stable set search_path = public as $$
  select secret from public.spaces where id = s and public.is_member(s);
$$;

-- Inhalte
create table if not exists public.profiles (
  space_id uuid not null references public.spaces(id) on delete cascade,
  role text not null check (role in ('je','anke')),
  nick text, emoji text, avatar_path text, sound text, bio text, link text, pronouns text,
  updated_at bigint,
  primary key (space_id, role)
);
create table if not exists public.posts (
  id text primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  author text not null, created_at bigint not null,
  text text, media_path text, media_type text, w int, h int, d real, bg text, challenge text,
  deleted boolean not null default false
);
create table if not exists public.reactions (
  post_id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  role text not null, at bigint, "on" boolean not null default true,
  primary key (post_id, role)
);
create table if not exists public.comments (
  id text primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  post_id text not null, author text not null, text text, created_at bigint not null,
  deleted boolean not null default false
);
create table if not exists public.stories (
  id text primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  author text not null, created_at bigint not null,
  text text, media_path text, media_type text, w int, h int, d real, bg text,
  deleted boolean not null default false
);
create table if not exists public.story_views (
  story_id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  role text not null, at bigint,
  primary key (story_id, role)
);
create table if not exists public.messages (
  id text primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  author text not null, text text, created_at bigint not null, read_at bigint,
  deleted boolean not null default false
);
create table if not exists public.pings (
  id text primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  from_role text not null, kind text not null, sound text,
  lat double precision, lng double precision, acc double precision,
  created_at bigint not null
);
create table if not exists public.push_subs (
  endpoint text primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  role text not null, sub jsonb not null,
  user_id uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists link text;
alter table public.profiles add column if not exists pronouns text;

-- Nur für die Edge Function (Service-Rolle), keine Policies = für Apps unsichtbar
create table if not exists public.app_keys (
  id text primary key, public_key text, private_key text, created_at timestamptz default now()
);

create index if not exists posts_space_idx on public.posts(space_id, created_at);
create index if not exists comments_post_idx on public.comments(post_id);
create index if not exists stories_space_idx on public.stories(space_id, created_at);
create index if not exists messages_space_idx on public.messages(space_id, created_at);
create index if not exists pings_space_idx on public.pings(space_id, created_at);

-- Row Level Security: nur Mitglieder des Raums
alter table public.spaces enable row level security;
alter table public.members enable row level security;
alter table public.app_keys enable row level security;

drop policy if exists "members read own space" on public.members;
create policy "members read own space" on public.members for select to authenticated using (public.is_member(space_id));

do $$
declare t text;
begin
  foreach t in array array['profiles','posts','reactions','comments','stories','story_views','messages','pings','push_subs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "space members" on public.%I', t);
    execute format('create policy "space members" on public.%I for all to authenticated using (public.is_member(space_id)) with check (public.is_member(space_id))', t);
    execute format('alter table public.%I replica identity full', t);
  end loop;
end $$;

-- Live-Abgleich (Realtime)
do $$
declare t text;
begin
  foreach t in array array['profiles','posts','reactions','comments','stories','story_views','messages','pings'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Fotos & Videos (privater Speicher, max. 50 MB je Datei)
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;

drop policy if exists "aj media read" on storage.objects;
drop policy if exists "aj media insert" on storage.objects;
drop policy if exists "aj media update" on storage.objects;
drop policy if exists "aj media delete" on storage.objects;
create policy "aj media read" on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "aj media insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "aj media update" on storage.objects for update to authenticated
  using (bucket_id = 'media' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "aj media delete" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and public.is_member(((storage.foldername(name))[1])::uuid));

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles, public.posts, public.reactions, public.comments, public.stories, public.story_views, public.messages, public.pings, public.push_subs to authenticated;
grant select on public.members to authenticated;
revoke all on public.app_keys from anon, authenticated;
grant execute on function public.create_space(text), public.join_space(text, text), public.space_secret(uuid), public.is_member(uuid) to authenticated;

select 'Anke & Jörg: Schema fertig ✔' as status;

-- 05.11.2026: Zusammengeführte Räume – Geräte wechseln automatisch in den gemeinsamen Raum
alter table public.spaces add column if not exists merged_into uuid;
create or replace function public.my_space() returns json
language sql security definer stable set search_path = public as $$
  select json_build_object('space_id', coalesce(s.merged_into, s.id), 'secret', (select x.secret from public.spaces x where x.id = coalesce(s.merged_into, s.id)))
  from public.members m join public.spaces s on s.id = m.space_id
  where m.user_id = auth.uid() order by m.created_at desc limit 1;
$$;
grant execute on function public.my_space() to authenticated;
