-- ============================================================
-- DRS NEXORA — Database Schema v0.1.0
-- Production schema: identity keys, prekeys, canonical chats,
-- versioned group keys, message receipts, read marks (private
-- unread state), reactions, hides, blocks, invites, calls,
-- presence, hardened RLS + storage policies.
--
-- IDEMPOTENT: safe to run repeatedly on an existing database.
-- Applies cleanly over the old "motkamel v4" schema (old tables
-- are migrated or replaced; data in old columns is not read).
-- ============================================================

-- ------------------------------------------------------------
-- 0) Extensions + legacy function cleanup
--    (old v4 functions with incompatible signatures must be dropped
--     before CREATE OR REPLACE can change their return type)
-- ------------------------------------------------------------
create extension if not exists pgcrypto;

drop function if exists public.get_unread_counts();
drop function if exists public.mark_chat_read(uuid);

-- v4 legacy columns: dead weight from the motkamel era. No v0.1.0 code
-- reads or writes them; dropping keeps the live table honest.
alter table public.messages drop column if exists content;
alter table public.messages drop column if exists nonce;
alter table public.messages drop column if exists mac;

-- v4 legacy columns on profiles are FATAL for signup: the
-- on_auth_user_created trigger inserts only v0.1.0 columns, so any
-- leftover v4 NOT NULL column (e.g. public_key) aborts every
-- signup with 23502 (null value violates not-null constraint).
-- Whitelist-drop: keep exactly the v0.1.0 columns, drop the rest.
do $$
declare c record;
begin
  for c in
    select column_name from information_schema.columns
    where table_schema = 'public'
      and table_name = 'profiles'
      and column_name not in
        ('id', 'username', 'display_name', 'avatar_path',
         'bio', 'created_at', 'updated_at')
  loop
    execute format('alter table public.profiles drop column %I', c.column_name);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 1) profiles
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text not null default '',
  avatar_path text,
  bio text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- migrate columns from the old v4 layout if present
alter table public.profiles add column if not exists display_name text not null default '';
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists bio text not null default '';
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

create unique index if not exists profiles_username_unique
  on public.profiles (lower(username));

-- auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'username', ''),
             split_part(new.email, '@', 1)) ||
      case when exists (
        select 1 from public.profiles p
        where p.username = coalesce(nullif(new.raw_user_meta_data->>'username',''),
                 split_part(new.email, '@', 1))
      ) then '_' || substr(new.id::text, 1, 4) else '' end,
    coalesce(new.raw_user_meta_data->>'username', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- 2) devices + prekeys  (crypto identity layer)
-- ------------------------------------------------------------
create table if not exists public.devices (
  device_id text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_name text not null default 'device',
  platform text not null default 'android',
  identity_key text not null,          -- X25519 IK pub (b64)
  signing_key text not null,           -- Ed25519 pub (b64)
  signed_prekey text not null,         -- X25519 SPK pub (b64)
  signed_prekey_sig text not null,     -- Ed25519 sig over SPK
  signed_prekey_id int not null,
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index if not exists devices_user_idx on public.devices (user_id);

create table if not exists public.one_time_prekeys (
  device_id text not null references public.devices(device_id) on delete cascade,
  opk_id int not null,
  public_key text not null,
  created_at timestamptz not null default now(),
  consumed_at timestamptz,
  primary key (device_id, opk_id)
);

-- ------------------------------------------------------------
-- 3) chats  (direct + groups, canonical pair)
-- ------------------------------------------------------------
create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'direct'
    check (type in ('direct', 'group')),
  user_a uuid references public.profiles(id) on delete cascade,
  user_b uuid references public.profiles(id) on delete cascade,
  name text not null default '',
  description text not null default '',
  avatar_path text,
  created_by uuid references public.profiles(id) on delete set null,
  invite_code text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz,
  deleted_at timestamptz,
  check (type = 'group' or (user_a is not null and user_b is not null))
);

-- migrate from the old v4 layout (is_group boolean)
-- NOTE: all new columns must exist before the data migration below
-- runs (create table above is skipped when the old table exists).
alter table public.chats add column if not exists type text not null default 'direct';
alter table public.chats add column if not exists name text not null default '';
alter table public.chats add column if not exists description text not null default '';
alter table public.chats add column if not exists avatar_path text;
alter table public.chats add column if not exists invite_code text;
alter table public.chats add column if not exists updated_at timestamptz not null default now();
alter table public.chats add column if not exists last_message_at timestamptz;
alter table public.chats add column if not exists deleted_at timestamptz;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_name = 'chats' and column_name = 'is_group'
  ) then
    update public.chats
       set type = case when is_group then 'group' else 'direct' end,
           name = coalesce(group_name, '')
     where type = 'direct';
  end if;
end $$;

do $$
begin
  alter table public.chats
    add constraint chats_type_check check (type in ('direct','group'));
exception when duplicate_object then null;
end $$;

-- canonical pair: exactly ONE direct chat per unordered pair
create unique index if not exists chats_direct_pair_unique
  on public.chats (user_a, user_b)
  where type = 'direct';

create index if not exists chats_user_a_idx on public.chats (user_a);
create index if not exists chats_user_b_idx on public.chats (user_b);

-- ------------------------------------------------------------
-- 4) chat_members
-- ------------------------------------------------------------
create table if not exists public.chat_members (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member'
    check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  added_by uuid references public.profiles(id) on delete set null,
  muted_until timestamptz,
  notifications_enabled boolean not null default true,
  -- v0.1.0 per-member chat state (my own view of a chat)
  pinned_at timestamptz,
  archived_at timestamptz,
  primary key (chat_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members (user_id);

-- upgrade columns for databases coming from the old v4 layout
alter table public.chat_members add column if not exists left_at timestamptz;
alter table public.chat_members add column if not exists added_by uuid references public.profiles(id) on delete set null;
alter table public.chat_members add column if not exists muted_until timestamptz;
alter table public.chat_members add column if not exists notifications_enabled boolean not null default true;
alter table public.chat_members add column if not exists pinned_at timestamptz;
alter table public.chat_members add column if not exists archived_at timestamptz;

-- ------------------------------------------------------------
-- 5) group key versions + wraps
-- ------------------------------------------------------------
create table if not exists public.group_key_versions (
  chat_id uuid not null references public.chats(id) on delete cascade,
  version int not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (chat_id, version)
);

create table if not exists public.group_key_wraps (
  chat_id uuid not null references public.chats(id) on delete cascade,
  version int not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_id text not null,
  wrapped_by uuid not null references public.profiles(id) on delete cascade,
  wrapped text not null,
  nonce text not null,
  created_at timestamptz not null default now(),
  primary key (chat_id, version, user_id, device_id)
);

-- ------------------------------------------------------------
-- 6) messages
-- ------------------------------------------------------------
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  sender_device_id text not null default '',
  client_msg_id text not null,
  kind text not null default 'text' check (kind in ('text','media','system','poll','pollVote')),
  body jsonb not null default '{}'::jsonb,
  reply_to uuid references public.messages(id) on delete set null,
  forwarded_from text,
  pinned_at timestamptz,
  edited_at timestamptz,
  deleted_for_all_at timestamptz,
  created_at timestamptz not null default now()
);

-- migrate old columns -> ignore (old ciphertext columns stay unused)
alter table public.messages add column if not exists sender_device_id text not null default '';
alter table public.messages add column if not exists client_msg_id text not null default '';
alter table public.messages add column if not exists kind text not null default 'text';
alter table public.messages add column if not exists body jsonb not null default '{}'::jsonb;
alter table public.messages add column if not exists reply_to uuid references public.messages(id) on delete set null;
alter table public.messages add column if not exists forwarded_from text;
alter table public.messages add column if not exists pinned_at timestamptz;
alter table public.messages add column if not exists edited_at timestamptz;
alter table public.messages add column if not exists deleted_for_all_at timestamptz;

-- idempotent sends: one server row per (sender, client_msg_id)
create unique index if not exists messages_client_msg_unique
  on public.messages (sender_id, client_msg_id);

create index if not exists messages_chat_created_idx
  on public.messages (chat_id, created_at desc);

-- keep chats.last_message_at fresh
create or replace function public.touch_chat_last_message()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  update public.chats set last_message_at = new.created_at
  where id = new.chat_id and (last_message_at is null or last_message_at < new.created_at);
  return new;
end;
$$;

drop trigger if exists messages_touch_chat on public.messages;
create trigger messages_touch_chat
  after insert on public.messages
  for each row execute function public.touch_chat_last_message();

-- ------------------------------------------------------------
-- 7) receipts / reactions / hides
-- ------------------------------------------------------------
create table if not exists public.message_receipts (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  delivered_at timestamptz,
  read_at timestamptz,
  primary key (message_id, user_id)
);
create index if not exists receipts_message_idx on public.message_receipts (message_id);

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (char_length(emoji) <= 8),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create table if not exists public.message_hides (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

-- ------------------------------------------------------------
-- 8) blocks / settings / join requests / calls
-- ------------------------------------------------------------
create table if not exists public.blocked_users (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table if not exists public.user_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.join_requests (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(),
  handled_by uuid references public.profiles(id) on delete set null,
  unique (chat_id, user_id)
);

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  type text not null default 'audio' check (type in ('audio','video')),
  status text not null default 'ringing'
    check (status in ('ringing','active','ended','missed','declined')),
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  duration_sec int not null default 0
);
create index if not exists calls_participants_idx
  on public.calls (caller_id, created_at desc);
create index if not exists calls_callee_idx
  on public.calls (callee_id, created_at desc);

-- ------------------------------------------------------------
-- 9) Membership helpers (security definer — used by every policy)
-- ------------------------------------------------------------
create or replace function public.is_chat_member(p_chat_id uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.chat_members cm
    where cm.chat_id = p_chat_id
      and cm.user_id = p_user
      and cm.left_at is null
  );
$$;

create or replace function public.is_chat_admin(p_chat_id uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.chat_members cm
    where cm.chat_id = p_chat_id
      and cm.user_id = p_user
      and cm.left_at is null
      and cm.role in ('owner', 'admin')
  );
$$;

create or replace function public.is_blocked_by(p_blocker uuid, p_target uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.blocked_users
    where blocker_id = p_blocker and blocked_id = p_target
  );
$$;

grant execute on function
  public.is_chat_member(uuid, uuid),
  public.is_chat_admin(uuid, uuid)
to authenticated;

-- ============================================================
-- 10) RPCs — chats
-- ============================================================

-- Race-safe direct chat: canonical pair + unique index + ON CONFLICT.
create or replace function public.get_or_create_direct_chat(p_other uuid)
returns json language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  lo uuid; hi uuid;
  cid uuid;
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if p_other = me then raise exception 'cannot chat with yourself'; end if;

  lo := least(me, p_other);
  hi := greatest(me, p_other);

  insert into public.chats (type, user_a, user_b, created_by)
  values ('direct', lo, hi, lo)
  -- the conflict target MUST carry the index predicate: the unique
  -- index above is PARTIAL (where type='direct'), and PostgreSQL
  -- cannot infer a partial index from a bare column list (42P10).
  on conflict (user_a, user_b) where type = 'direct'
  do update set updated_at = now()
  returning id into cid;

  if cid is null then
    select id into cid from public.chats
    where type = 'direct' and user_a = lo and user_b = hi limit 1;
  end if;

  -- ensure both member rows exist
  insert into public.chat_members (chat_id, user_id, role)
  values (cid, lo, 'member'), (cid, hi, 'member')
  on conflict (chat_id, user_id) do update set left_at = null;

  return json_build_object('chat_id', cid);
end;
$$;

-- Chats list for the current user (the app has called this RPC since
-- v0.1.0 — added to the canonical schema in v0.1.0 cycle 0-ح; it was
-- previously missing from EVERY schema version, so the chats list
-- silently never loaded from the server).
-- Row shape matches lib/data/models/models.dart Chat.fromJson.
create or replace function public.get_my_chats()
returns json language sql stable security definer set search_path = public
as $$
  select coalesce(json_agg(s.*), '[]'::json)
  from (
    select
      c.id,
      c.type,
      case when c.type = 'direct' then to_jsonb(p) end as peer,
      c.name,
      c.description,
      c.avatar_path,
      c.created_by,
      c.invite_code,
      my.role as my_role,
      my.pinned_at as my_pinned_at,
      my.muted_until as my_muted_until,
      my.archived_at as my_archived_at,
      c.created_at,
      c.last_message_at
    from public.chats c
    join public.chat_members my
      on my.chat_id = c.id
     and my.user_id = auth.uid()
     and my.left_at is null
    left join public.chat_members other
      on other.chat_id = c.id
     and c.type = 'direct'
     and other.user_id <> auth.uid()
     and other.left_at is null
    left join public.profiles p on p.id = other.user_id
    where c.deleted_at is null
    order by coalesce(c.last_message_at, c.updated_at, c.created_at) desc
  ) s;
$$;

-- v0.1.0: flip MY OWN per-chat flags (pin / mute / archive).
-- SECURITY DEFINER because chat_members deliberately has no UPDATE
-- policy; a member may only touch their own row. Tri-state args:
-- true = set, false = clear, null = leave unchanged.
create or replace function public.set_chat_flags(
  p_chat_id uuid,
  p_pinned boolean default null,
  p_muted boolean default null,
  p_archived boolean default null)
returns void language plpgsql security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if not exists (
    select 1 from public.chat_members
    where chat_id = p_chat_id and user_id = me and left_at is null
  ) then
    raise exception 'not a member';
  end if;
  update public.chat_members set
    pinned_at = case p_pinned
                  when true  then now()
                  when false then null
                  else pinned_at end,
    muted_until = case p_muted
                  when true  then now() + interval '3650 days'
                  when false then null
                  else muted_until end,
    archived_at = case p_archived
                  when true  then now()
                  when false then null
                  else archived_at end
  where chat_id = p_chat_id and user_id = me;
end;
$$;

create or replace function public.create_group(p_name text, p_description text default null)
returns json language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  cid uuid;
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if p_name is null or length(btrim(p_name)) < 2
     or length(btrim(p_name)) > 60 then
    raise exception 'invalid group name';
  end if;

  insert into public.chats (type, name, description, created_by)
  values ('group', btrim(p_name), coalesce(p_description, ''), me)
  returning id into cid;

  insert into public.chat_members (chat_id, user_id, role)
  values (cid, me, 'owner');

  return json_build_object('chat_id', cid);
end;
$$;

create or replace function public.update_group_info(
  p_chat_id uuid, p_name text default null,
  p_description text default null, p_avatar_path text default null)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_chat_admin(p_chat_id, auth.uid()) then
    raise exception 'admin only';
  end if;
  update public.chats set
    name = coalesce(p_name, name),
    description = coalesce(p_description, description),
    avatar_path = coalesce(p_avatar_path, avatar_path),
    updated_at = now()
  where id = p_chat_id;
end;
$$;

create or replace function public.group_add_members(
  p_chat_id uuid, p_user_ids uuid[])
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); uid uuid;
begin
  if not public.is_chat_admin(p_chat_id, me) then
    raise exception 'admin only';
  end if;
  if (select count(*) from public.chat_members
      where chat_id = p_chat_id and left_at is null) > 200 then
    raise exception 'group full (max 200)';
  end if;
  foreach uid in array p_user_ids loop
    insert into public.chat_members (chat_id, user_id, role, added_by)
    values (p_chat_id, uid, 'member', me)
    on conflict (chat_id, user_id) do update set left_at = null, added_by = me;
  end loop;
  -- members must receive the CURRENT key version wraps? No — the admin
  -- rotates to a NEW version after adding; the new member gets the new
  -- key only (old messages stay unreadable to them).
  insert into public.messages (chat_id, sender_id, sender_device_id, client_msg_id, kind, body)
  select p_chat_id, me, '', gen_random_uuid()::text, 'system',
         jsonb_build_object('v',1,'t','s','sd','','sys','أضاف عضواً جديدًا للمجموعة')
  where exists (select 1 from unnest(p_user_ids));
end;
$$;

create or replace function public.group_remove_member(p_chat_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if not public.is_chat_admin(p_chat_id, me) then
    raise exception 'admin only';
  end if;
  if p_user_id = me then raise exception 'use group_leave'; end if;
  delete from public.chat_members
  where chat_id = p_chat_id and user_id = p_user_id;
end;
$$;

create or replace function public.group_leave(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if exists (select 1 from public.chat_members
             where chat_id = p_chat_id and user_id = me and role = 'owner')
     and (select count(*) from public.chat_members
          where chat_id = p_chat_id and left_at is null) > 1 then
    raise exception 'transfer ownership before leaving';
  end if;
  delete from public.chat_members
  where chat_id = p_chat_id and user_id = me;
end;
$$;

create or replace function public.group_set_role(
  p_chat_id uuid, p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if p_role not in ('owner','admin','member') then
    raise exception 'invalid role';
  end if;
  if not exists (select 1 from public.chat_members
                 where chat_id = p_chat_id and user_id = auth.uid()
                   and role = 'owner') then
    raise exception 'owner only';
  end if;
  update public.chat_members set role = p_role
  where chat_id = p_chat_id and user_id = p_user_id;
end;
$$;

create or replace function public.group_delete(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  delete from public.chats
  where id = p_chat_id and created_by = auth.uid();
  if not found then raise exception 'owner only'; end if;
end;
$$;

-- group key rotation
create or replace function public.group_start_key_version(p_chat_id uuid)
returns int language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); v int;
begin
  if not public.is_chat_admin(p_chat_id, me) then
    raise exception 'admin only';
  end if;
  select coalesce(max(version), 0) + 1 into v
  from public.group_key_versions where chat_id = p_chat_id;
  insert into public.group_key_versions (chat_id, version, created_by)
  values (p_chat_id, v, me);
  return v;
end;
$$;

create or replace function public.group_publish_wraps(
  p_chat_id uuid, p_version int, p_wraps jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); w jsonb;
  latest int;
begin
  if not public.is_chat_admin(p_chat_id, me) then
    raise exception 'admin only';
  end if;
  select max(version) into latest from public.group_key_versions
  where chat_id = p_chat_id;
  if p_version <> latest then
    raise exception 'stale key version';
  end if;

  for w in select * from jsonb_array_elements(p_wraps) loop
    -- every wrapped target must be a CURRENT member
    if not public.is_chat_member(p_chat_id, (w->>'user_id')::uuid) then
      raise exception 'wrap target is not a current member';
    end if;
    insert into public.group_key_wraps
      (chat_id, version, user_id, device_id, wrapped_by, wrapped, nonce)
    values (p_chat_id, p_version, (w->>'user_id')::uuid,
            coalesce(w->>'device_id',''), me,
            w->>'wrapped', w->>'nonce')
    on conflict (chat_id, version, user_id, device_id) do nothing;
  end loop;
end;
$$;

-- invite links + join requests
create or replace function public.group_create_invite(p_chat_id uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare code text;
begin
  if not public.is_chat_admin(p_chat_id, auth.uid()) then
    raise exception 'admin only';
  end if;
  code := substr(replace(gen_random_uuid()::text,'-',''), 1, 10);
  update public.chats set invite_code = code, updated_at = now()
  where id = p_chat_id;
  return code;
end;
$$;

create or replace function public.group_join_by_invite(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); cid uuid;
begin
  select id into cid from public.chats
  where invite_code = p_code and type = 'group' and deleted_at is null;
  if cid is null then raise exception 'invalid invite'; end if;

  insert into public.chat_members (chat_id, user_id, role)
  values (cid, me, 'member')
  on conflict (chat_id, user_id) do update set left_at = null;
  return json_build_object('chat_id', cid);
end;
$$;

create or replace function public.group_respond_join_request(
  p_request_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.join_requests%rowtype; me uuid := auth.uid();
begin
  select * into r from public.join_requests where id = p_request_id;
  if not found then raise exception 'not found'; end if;
  if not public.is_chat_admin(r.chat_id, me) then
    raise exception 'admin only';
  end if;
  update public.join_requests
     set status = case when p_accept then 'accepted' else 'rejected' end,
         handled_by = me
   where id = p_request_id;
  if p_accept then
    insert into public.chat_members (chat_id, user_id, role, added_by)
    values (r.chat_id, r.user_id, 'member', me)
    on conflict (chat_id, user_id) do update set left_at = null;
  end if;
end;
$$;

-- ============================================================
-- 11) RPCs — devices / prekeys
-- ============================================================
create or replace function public.register_device(
  p_device_id text, p_device_name text, p_platform text, p_bundle jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  insert into public.devices
    (device_id, user_id, device_name, platform,
     identity_key, signing_key, signed_prekey, signed_prekey_sig, signed_prekey_id)
  values (p_device_id, auth.uid(), p_device_name, p_platform,
          p_bundle->>'identity_key', p_bundle->>'signing_key',
          p_bundle->>'signed_prekey', p_bundle->>'signed_prekey_sig',
          (p_bundle->>'signed_prekey_id')::int)
  on conflict (device_id) do update
    set device_name = excluded.device_name,
        platform = excluded.platform,
        identity_key = excluded.identity_key,
        signing_key = excluded.signing_key,
        signed_prekey = excluded.signed_prekey,
        signed_prekey_sig = excluded.signed_prekey_sig,
        signed_prekey_id = excluded.signed_prekey_id,
        last_active_at = now(),
        revoked_at = null;

  -- replace unconsumed one-time prekeys with the fresh batch
  delete from public.one_time_prekeys
  where device_id = p_device_id and consumed_at is null;

  insert into public.one_time_prekeys (device_id, opk_id, public_key)
  select p_device_id,
         (k->>'id')::int,
         k->>'key'
  from jsonb_array_elements(p_bundle->'one_time_prekeys') as k
  on conflict (device_id, opk_id) do nothing;
end;
$$;

create or replace function public.topup_one_time_prekeys(
  p_device_id text, p_one_time_prekeys jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.devices
                 where device_id = p_device_id and user_id = auth.uid()) then
    raise exception 'not your device';
  end if;
  delete from public.one_time_prekeys
  where device_id = p_device_id and consumed_at is null;
  insert into public.one_time_prekeys (device_id, opk_id, public_key)
  select p_device_id, (k->>'id')::int, k->>'key'
  from jsonb_array_elements(p_one_time_prekeys) as k
  on conflict (device_id, opk_id) do nothing;
end;
$$;

-- Fetch bundles for ALL active devices of a user; atomically claim
-- one unconsumed OPK per device (returned in the bundle).
-- Concurrency: FOR UPDATE SKIP LOCKED serialises claimers; the
-- UPDATE itself re-checks consumed_at so a stale snapshot can never
-- hand the same OPK to two sessions (race fixed in v0.1.0). If a device
-- has no unconsumed OPK left its bundle simply carries null OPK and
-- the X3DH initiator falls back to the signed-prekey-only flow.
create or replace function public.get_prekey_bundles(p_user_id uuid)
returns json language plpgsql volatile security definer
set search_path = public
as $$
declare result jsonb; me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;

  with locked as (
    select p.device_id, p.opk_id
    from public.one_time_prekeys p
    join public.devices d on d.device_id = p.device_id
    where d.user_id = p_user_id
      and d.revoked_at is null
      and p.consumed_at is null
    order by p.device_id, p.opk_id
    for update of p skip locked
  ), targets as (
    select distinct on (device_id) device_id, opk_id from locked
  ), claimed as (
    update public.one_time_prekeys p
       set consumed_at = now()
     where (p.device_id, p.opk_id) in (select device_id, opk_id from targets)
       and p.consumed_at is null
    returning p.device_id, p.opk_id, p.public_key
  )
  select coalesce(jsonb_agg(row), '[]'::jsonb) into result
  from (
    select jsonb_build_object(
      'device_id', d.device_id,
      'identity_key', d.identity_key,
      'signing_key', d.signing_key,
      'signed_prekey', d.signed_prekey,
      'signed_prekey_sig', d.signed_prekey_sig,
      'signed_prekey_id', d.signed_prekey_id,
      'one_time_prekey', c.public_key,
      'one_time_prekey_id', c.opk_id
    ) as row
    from public.devices d
    left join claimed c on c.device_id = d.device_id
    where d.user_id = p_user_id
      and d.revoked_at is null
  ) s;

  return result;
end;
$$;

create or replace function public.acknowledge_opk_consumed(
  p_device_id text, p_opk_id int)
returns void language sql security definer set search_path = public
as $$
  update public.one_time_prekeys set consumed_at = now()
  where device_id = p_device_id and opk_id = p_opk_id
    and exists (select 1 from public.devices
                where device_id = p_device_id and user_id = auth.uid());
$$;

-- ============================================================
-- 11b) Presence — last_seen heartbeat (privacy-first)
--      Online = heartbeat within the last 70 seconds.
--      Visibility requires: shared chat + target allows it.
--      RLS is ON with no direct policies: the table is reachable
--      exclusively through the two security definer RPCs below.
-- ============================================================
create table if not exists public.presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  last_seen_at timestamptz not null default now()
);
alter table public.presence enable row level security;

-- Heartbeat: records me as seen now, unless my settings hide
-- presence — in that case any stored row is removed immediately.
-- Opportunistically garbage-collects rows idle for over one hour.
create or replace function public.presence_heartbeat()
returns void language plpgsql security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if coalesce(
       (select (s.settings->>'show_presence')::boolean
          from public.user_settings s where s.user_id = me),
       true) is false then
    delete from public.presence where user_id = me;
    return;
  end if;
  insert into public.presence (user_id, last_seen_at)
  values (me, now())
  on conflict (user_id) do update set last_seen_at = now();
  -- v0.1.0: keep rows 30 days (was 1 hour) so last-seen survives
  -- going offline. get_presence() still only reports the fresh
  -- 70-second window as "online" — semantics unchanged there.
  delete from public.presence
   where last_seen_at < now() - interval '30 days';
end;
$$;

-- Query presence of other users. A row is returned only when:
--   * we share at least one chat with that user,
--   * the user has not disabled show_presence,
--   * the heartbeat is fresh (online window).
create or replace function public.get_presence(p_user_ids uuid[])
returns table (user_id uuid, last_seen_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select p.user_id, p.last_seen_at
  from public.presence p
  where p.user_id = any (p_user_ids)
    and p.user_id <> auth.uid()
    and p.last_seen_at > now() - interval '70 seconds'
    and exists (
      select 1 from public.chat_members mine
      join public.chat_members theirs
        on theirs.chat_id = mine.chat_id
       and theirs.user_id = p.user_id
       and theirs.left_at is null
      where mine.user_id = auth.uid()
        and mine.left_at is null
    )
    and coalesce(
      (select (s.settings->>'show_presence')::boolean
         from public.user_settings s where s.user_id = p.user_id),
      true)
$$;

-- v0.1.0: last-seen exposure — same admission rules as get_presence
-- (shared chat + target's show_presence setting), but reports up to
-- 30 days back so the chat header can show «آخر ظهور …».
create or replace function public.get_last_seen(p_user_ids uuid[])
returns table (user_id uuid, last_seen_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select p.user_id, p.last_seen_at
  from public.presence p
  where p.user_id = any (p_user_ids)
    and p.user_id <> auth.uid()
    and p.last_seen_at > now() - interval '30 days'
    and exists (
      select 1 from public.chat_members mine
      join public.chat_members theirs
        on theirs.chat_id = mine.chat_id
       and theirs.user_id = p.user_id
       and theirs.left_at is null
      where mine.user_id = auth.uid()
        and mine.left_at is null
    )
    and coalesce(
      (select (s.settings->>'show_presence')::boolean
         from public.user_settings s where s.user_id = p.user_id),
      true)
$$;

-- ============================================================
-- 12) RPCs — receipts / unread
-- ============================================================
create or replace function public.mark_messages_delivered(p_chat_id uuid)
returns void language sql security definer set search_path = public
as $$
  insert into public.message_receipts (message_id, user_id, delivered_at)
  select m.id, auth.uid(), now()
  from public.messages m
  where m.chat_id = p_chat_id
    and m.sender_id <> auth.uid()
    and public.is_chat_member(p_chat_id, auth.uid())
  on conflict (message_id, user_id)
  do update set delivered_at = coalesce(message_receipts.delivered_at, now());
$$;

-- read_marks: PRIVATE per-user read state. Drives unread counts and
-- is never visible to anyone else (SELECT-own policy below; writes
-- happen exclusively through mark_messages_read). Public read
-- receipts (message_receipts.read_at) are written only when my
-- read_receipts setting is ON — so the toggle is enforced
-- SERVER-SIDE and cannot be bypassed by a modified client.
create table if not exists public.read_marks (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);
alter table public.read_marks enable row level security;

drop policy if exists "read_marks: read own" on public.read_marks;
create policy "read_marks: read own" on public.read_marks
  for select to authenticated
  using (user_id = auth.uid());

-- no direct writes even if a future policy mistake happens
revoke insert, update, delete on public.read_marks from anon, authenticated;

create or replace function public.mark_messages_read(p_chat_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if not public.is_chat_member(p_chat_id, me) then
    return;
  end if;

  -- (1) private read mark — always, so my unread badge stays correct
  --     even with read receipts disabled.
  insert into public.read_marks (chat_id, user_id, last_read_at)
  values (p_chat_id, me, now())
  on conflict (chat_id, user_id)
  do update set last_read_at = now();

  -- (2) public read receipts — only when my settings allow it.
  if coalesce(
       (select (s.settings->>'read_receipts')::boolean
          from public.user_settings s where s.user_id = me),
       true) then
    insert into public.message_receipts (message_id, user_id, delivered_at, read_at)
    select m.id, me, now(), now()
    from public.messages m
    where m.chat_id = p_chat_id
      and m.sender_id <> me
    on conflict (message_id, user_id)
    do update set read_at = now(),
                  delivered_at = coalesce(message_receipts.delivered_at, now());
  end if;
end;
$$;

create or replace function public.get_unread_counts()
returns table (chat_id uuid, unread bigint)
language sql stable security definer set search_path = public
as $$
  select m.chat_id, count(*)::bigint
  from public.messages m
  left join public.read_marks rm
    on rm.chat_id = m.chat_id and rm.user_id = auth.uid()
  where public.is_chat_member(m.chat_id, auth.uid())
    and m.sender_id <> auth.uid()
    and m.deleted_for_all_at is null
    and m.created_at > coalesce(rm.last_read_at, to_timestamp(0))
  group by m.chat_id;
$$;

-- ============================================================
-- 13) RPCs — account
-- ============================================================
create or replace function public.delete_own_account()
returns void language plpgsql security definer set search_path = public, storage
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  -- best-effort storage cleanup for files I own
  delete from storage.objects
  where bucket_id in ('media','avatars')
    and (name like '%/' || me::text || '/%' or name like me::text || '/%');
  delete from auth.users where id = me;
end;
$$;

-- ============================================================
-- 14) Guards — message integrity + rate limiting
-- ============================================================
create or replace function public.messages_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    if new.chat_id is distinct from old.chat_id
       or new.sender_id is distinct from old.sender_id
       or new.client_msg_id is distinct from old.client_msg_id
       or new.kind is distinct from old.kind
       or new.created_at is distinct from old.created_at then
      raise exception 'immutable message fields';
    end if;

    -- only the sender may edit/delete/pin
    if (new.body is distinct from old.body
        or new.edited_at is distinct from old.edited_at
        or new.deleted_for_all_at is distinct from old.deleted_for_all_at
        or new.pinned_at is distinct from old.pinned_at)
       and auth.uid() <> old.sender_id then
      raise exception 'sender only';
    end if;

    -- after delete-for-everyone, nothing else changes
    if old.deleted_for_all_at is not null then
      raise exception 'message already deleted';
    end if;

    -- deletion must also blank the body
    if new.deleted_for_all_at is not null then
      new.body := '{"v":1,"t":"s","sd":"","sys":""}'::jsonb;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists messages_guard_trigger on public.messages;
create trigger messages_guard_trigger
  before update on public.messages
  for each row execute function public.messages_guard();

-- basic flood protection: 30 messages / minute / user
create or replace function public.enforce_message_rate()
returns trigger language plpgsql as $$
declare recent int;
begin
  select count(*) into recent from public.messages
  where sender_id = new.sender_id
    and created_at > now() - interval '60 seconds';
  if recent >= 30 then
    raise exception 'rate limit: too many messages';
  end if;
  return new;
end;
$$;

drop trigger if exists messages_rate_limit on public.messages;
create trigger messages_rate_limit
  before insert on public.messages
  for each row execute function public.enforce_message_rate();

-- ============================================================
-- 15) RLS — enable everywhere
-- ============================================================
alter table public.profiles enable row level security;
alter table public.devices enable row level security;
alter table public.one_time_prekeys enable row level security;
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.group_key_versions enable row level security;
alter table public.group_key_wraps enable row level security;
alter table public.messages enable row level security;
alter table public.message_receipts enable row level security;
alter table public.message_reactions enable row level security;
alter table public.message_hides enable row level security;
alter table public.blocked_users enable row level security;
alter table public.user_settings enable row level security;
alter table public.join_requests enable row level security;
alter table public.calls enable row level security;

-- ---------- profiles ----------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (true);

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (auth.uid() = id);

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

-- ---------- devices (public keys are public by design) ----------
drop policy if exists devices_select on public.devices;
create policy devices_select on public.devices
  for select to authenticated using (true);

drop policy if exists devices_write_self on public.devices;
create policy devices_write_self on public.devices
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists devices_update_self on public.devices;
create policy devices_update_self on public.devices
  for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists devices_delete_self on public.devices;
create policy devices_delete_self on public.devices
  for delete to authenticated using (auth.uid() = user_id);

-- ---------- one_time_prekeys ----------
drop policy if exists opk_select on public.one_time_prekeys;
create policy opk_select on public.one_time_prekeys
  for select to authenticated
  using (exists (select 1 from public.devices d
                 where d.device_id = device_id and d.user_id = auth.uid()));

drop policy if exists opk_write on public.one_time_prekeys;
create policy opk_write on public.one_time_prekeys
  for insert to authenticated
  with check (exists (select 1 from public.devices d
                 where d.device_id = device_id and d.user_id = auth.uid()));

drop policy if exists opk_update on public.one_time_prekeys;
create policy opk_update on public.one_time_prekeys
  for update to authenticated
  using (exists (select 1 from public.devices d
                 where d.device_id = device_id and d.user_id = auth.uid()));

-- ---------- chats ----------
drop policy if exists chats_select_members on public.chats;
create policy chats_select_members on public.chats
  for select to authenticated
  using (public.is_chat_member(id, auth.uid()));

drop policy if exists chats_delete_owner on public.chats;
create policy chats_delete_owner on public.chats
  for delete to authenticated using (created_by = auth.uid());

-- direct chat creation goes through get_or_create_direct_chat RPC;
-- groups through create_group RPC. No direct INSERT policy.

-- ---------- chat_members ----------
drop policy if exists members_select on public.chat_members;
create policy members_select on public.chat_members
  for select to authenticated
  using (public.is_chat_member(chat_id, auth.uid()));

-- membership writes go through SECURITY DEFINER RPCs (no direct policy)

-- ---------- group keys ----------
drop policy if exists gkv_select on public.group_key_versions;
create policy gkv_select on public.group_key_versions
  for select to authenticated
  using (public.is_chat_member(chat_id, auth.uid()));

drop policy if exists gkw_select_own on public.group_key_wraps;
create policy gkw_select_own on public.group_key_wraps
  for select to authenticated
  using (user_id = auth.uid());

-- ---------- messages ----------
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select to authenticated
  using (public.is_chat_member(chat_id, auth.uid()));

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.is_chat_member(chat_id, auth.uid())
    and sender_id = auth.uid()
    -- direct chats: the peer must not have blocked me
    and not exists (
      select 1 from public.chats c
      where c.id = chat_id and c.type = 'direct'
        and public.is_blocked_by(
              case when c.user_a = auth.uid() then c.user_b else c.user_a end,
              auth.uid())
    )
  );

drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages
  for update to authenticated
  using (public.is_chat_member(chat_id, auth.uid()) and sender_id = auth.uid())
  with check (sender_id = auth.uid());

drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages
  for delete to authenticated using (sender_id = auth.uid());

-- column-level guard for updates
revoke update on table public.messages from authenticated;
grant update (body, edited_at, deleted_for_all_at, pinned_at)
  on table public.messages to authenticated;

-- ---------- receipts ----------
drop policy if exists receipts_select on public.message_receipts;
create policy receipts_select on public.message_receipts
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.messages m
               where m.id = message_id and m.sender_id = auth.uid())
  );

drop policy if exists receipts_write_own on public.message_receipts;
create policy receipts_write_own on public.message_receipts
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists receipts_update_own on public.message_receipts;
create policy receipts_update_own on public.message_receipts
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- reactions ----------
drop policy if exists reactions_select on public.message_reactions;
create policy reactions_select on public.message_reactions
  for select to authenticated
  using (public.is_chat_member(chat_id, auth.uid()));

drop policy if exists reactions_write_own on public.message_reactions;
create policy reactions_write_own on public.message_reactions
  for insert to authenticated
  with check (user_id = auth.uid()
              and public.is_chat_member(chat_id, auth.uid()));

drop policy if exists reactions_update_own on public.message_reactions;
create policy reactions_update_own on public.message_reactions
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists reactions_delete_own on public.message_reactions;
create policy reactions_delete_own on public.message_reactions
  for delete to authenticated using (user_id = auth.uid());

-- ---------- hides ----------
drop policy if exists hides_all_own on public.message_hides;
create policy hides_all_own on public.message_hides
  for select to authenticated using (user_id = auth.uid());

drop policy if exists hides_insert_own on public.message_hides;
create policy hides_insert_own on public.message_hides
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists hides_delete_own on public.message_hides;
create policy hides_delete_own on public.message_hides
  for delete to authenticated using (user_id = auth.uid());

-- ---------- blocks ----------
drop policy if exists blocks_own on public.blocked_users;
create policy blocks_own on public.blocked_users
  for select to authenticated using (blocker_id = auth.uid());

drop policy if exists blocks_insert_own on public.blocked_users;
create policy blocks_insert_own on public.blocked_users
  for insert to authenticated with check (blocker_id = auth.uid());

drop policy if exists blocks_delete_own on public.blocked_users;
create policy blocks_delete_own on public.blocked_users
  for delete to authenticated using (blocker_id = auth.uid());

-- ---------- settings ----------
drop policy if exists settings_own on public.user_settings;
create policy settings_own on public.user_settings
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------- join requests ----------
drop policy if exists jreq_select on public.join_requests;
create policy jreq_select on public.join_requests
  for select to authenticated
  using (user_id = auth.uid()
         or public.is_chat_admin(chat_id, auth.uid()));

drop policy if exists jreq_insert_own on public.join_requests;
create policy jreq_insert_own on public.join_requests
  for insert to authenticated with check (user_id = auth.uid());

-- status changes go through the RPC

-- ---------- calls ----------
drop policy if exists calls_select on public.calls;
create policy calls_select on public.calls
  for select to authenticated
  using (caller_id = auth.uid() or callee_id = auth.uid());

drop policy if exists calls_insert_own on public.calls;
create policy calls_insert_own on public.calls
  for insert to authenticated
  with check (caller_id = auth.uid()
              and public.is_chat_member(chat_id, auth.uid()));

drop policy if exists calls_update_own on public.calls;
create policy calls_update_own on public.calls
  for update to authenticated
  using (caller_id = auth.uid() or callee_id = auth.uid())
  with check (caller_id = auth.uid() or callee_id = auth.uid());

grant execute on function
  public.get_or_create_direct_chat(uuid),
  public.get_my_chats(),
  public.create_group(text, text),
  public.update_group_info(uuid, text, text, text),
  public.group_add_members(uuid, uuid[]),
  public.group_remove_member(uuid, uuid),
  public.group_leave(uuid),
  public.group_set_role(uuid, uuid, text),
  public.group_delete(uuid),
  public.group_start_key_version(uuid),
  public.group_publish_wraps(uuid, int, jsonb),
  public.group_create_invite(uuid),
  public.group_join_by_invite(text),
  public.group_respond_join_request(uuid, boolean),
  public.register_device(text, text, text, jsonb),
  public.topup_one_time_prekeys(text, jsonb),
  public.get_prekey_bundles(uuid),
  public.acknowledge_opk_consumed(text, int),
  public.presence_heartbeat(),
  public.get_presence(uuid[]),
  public.mark_messages_delivered(uuid),
  public.mark_messages_read(uuid),
  public.get_unread_counts(),
  public.delete_own_account()
to authenticated;

-- ============================================================
-- 16) Storage — encrypted media + avatars
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 52428800)
on conflict (id) do update set file_size_limit = 52428800;

insert into storage.buckets (id, name, public, file_size_limit)
values ('avatars', 'avatars', false, 2097152)
on conflict (id) do update set file_size_limit = 2097152;

-- media: media/{chatId}/{userId}/{file}.enc
drop policy if exists media_select_member on storage.objects;
create policy media_select_member on storage.objects
  for select to authenticated
  using (
    bucket_id = 'media'
    and public.is_chat_member(
          (split_part(name, '/', 2))::uuid, auth.uid())
  );

drop policy if exists media_insert_member on storage.objects;
create policy media_insert_member on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'media'
    and split_part(name, '/', 3) = auth.uid()::text
    and public.is_chat_member(
          (split_part(name, '/', 2))::uuid, auth.uid())
  );

drop policy if exists media_delete_owner on storage.objects;
create policy media_delete_owner on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'media'
    and split_part(name, '/', 3) = auth.uid()::text
  );

-- avatars: avatars/{userId}/{file}
drop policy if exists avatars_select on storage.objects;
create policy avatars_select on storage.objects
  for select to authenticated using (bucket_id = 'avatars');

drop policy if exists avatars_write_own on storage.objects;
create policy avatars_write_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars'
              and split_part(name, '/', 2) = auth.uid()::text);

drop policy if exists avatars_delete_own on storage.objects;
create policy avatars_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars'
         and split_part(name, '/', 2) = auth.uid()::text);

-- ============================================================
-- 17) Realtime publication
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['messages','message_receipts','message_reactions',
                           'chats','chat_members','join_requests','calls'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ============================================================
-- 18) Push tokens (FCM) — v0.1.0
-- ============================================================
-- One row per device token. SECURITY: tokens belong to their user
-- only (RLS). The token itself is a routing address, not a secret,
-- but cross-user access is still denied server-side.
create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  platform   text not null default 'android',
  updated_at timestamptz not null default now()
);

create index if not exists idx_push_tokens_user on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_all_own on public.push_tokens;
create policy push_tokens_all_own on public.push_tokens
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update, delete on public.push_tokens to authenticated;

-- ============================================================
-- DRS NEXORA v0.1.0 — END
-- ============================================================

-- ------------------------------------------------------------
-- v0.1.0 (2026-10-08): disappearing messages + starred messages.
-- Canonical mirrors of supabase/patches/2026-10-08-v010-disappearing-stars.sql
-- (columns/trigger/RPCs/table/policies; get_my_chats above already
-- exposes c.disappear_ttl_seconds after this cycle).
-- ------------------------------------------------------------
alter table public.chats add column if not exists disappear_ttl_seconds bigint;
alter table public.messages add column if not exists expires_at timestamptz;
create index if not exists messages_expires_idx on public.messages (expires_at) where expires_at is not null;

create or replace function public.messages_expire_stamp() returns trigger language plpgsql set search_path = public as $$
declare ttl bigint;
begin
  if new.expires_at is not null then return new; end if;
  select c.disappear_ttl_seconds into ttl from public.chats c where c.id = new.chat_id;
  if ttl is not null and ttl > 0 then
    new.expires_at := coalesce(new.created_at, now()) + make_interval(secs => ttl);
  end if;
  return new;
end;
$$;
drop trigger if exists messages_expire_stamp_trg on public.messages;
create trigger messages_expire_stamp_trg before insert on public.messages for each row execute function public.messages_expire_stamp();

create or replace function public.set_disappear_ttl(p_chat_id uuid, p_ttl_seconds bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if not exists (select 1 from public.chat_members where chat_id = p_chat_id and user_id = me and left_at is null) then
    raise exception 'not a member';
  end if;
  if p_ttl_seconds is null or p_ttl_seconds <= 0 then
    update public.chats set disappear_ttl_seconds = null where id = p_chat_id;
  else
    if p_ttl_seconds < 60 then raise exception 'ttl too short'; end if;
    update public.chats set disappear_ttl_seconds = p_ttl_seconds where id = p_chat_id;
  end if;
end;
$$;

create or replace function public.purge_expired_messages(p_chat_id uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int := 0;
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if p_chat_id is not null then
    if not exists (select 1 from public.chat_members where chat_id = p_chat_id and user_id = me and left_at is null) then
      raise exception 'not a member';
    end if;
    delete from public.messages where chat_id = p_chat_id and expires_at is not null and expires_at <= now();
    get diagnostics n = row_count;
  else
    delete from public.messages m using public.chat_members cm
      where cm.chat_id = m.chat_id and cm.user_id = me and cm.left_at is null
        and m.expires_at is not null and m.expires_at <= now();
    get diagnostics n = row_count;
  end if;
  return n;
end;
$$;

create table if not exists public.message_stars (
  user_id uuid not null references public.profiles(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, message_id)
);
alter table public.message_stars enable row level security;
drop policy if exists "stars_select_own" on public.message_stars;
create policy "stars_select_own" on public.message_stars for select using (user_id = auth.uid());
drop policy if exists "stars_insert_own" on public.message_stars;
create policy "stars_insert_own" on public.message_stars for insert with check (
  user_id = auth.uid() and exists (
    select 1 from public.messages m
    join public.chat_members cm on cm.chat_id = m.chat_id and cm.user_id = auth.uid() and cm.left_at is null
    where m.id = message_id));
drop policy if exists "stars_delete_own" on public.message_stars;
create policy "stars_delete_own" on public.message_stars for delete using (user_id = auth.uid());

create or replace function public.get_starred_messages()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(s.*), '[]'::json) from (
    select m.id, m.chat_id, m.sender_id, m.sender_device_id, m.client_msg_id, m.kind, m.body,
           m.reply_to, m.forwarded_from, m.edited_at, m.deleted_for_all_at, m.created_at, m.expires_at
    from public.message_stars st
    join public.messages m on m.id = st.message_id
    join public.chat_members cm on cm.chat_id = m.chat_id and cm.user_id = auth.uid() and cm.left_at is null
    where st.user_id = auth.uid()
    order by m.created_at desc limit 500
  ) s;
$$;
