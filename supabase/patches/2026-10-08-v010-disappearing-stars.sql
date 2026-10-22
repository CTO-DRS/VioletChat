-- ============================================================
-- DRS NEXORA — v0.1.0 patch: Disappearing messages + Starred messages
-- (2026-10-08 — applied via Management API, see scripts/apply_v010_patch.py)
--
-- Contents:
--   1) chats.disappear_ttl_seconds      — per-chat TTL (null = off)
--   2) messages.expires_at              — stamped by trigger at INSERT
--                                         from the chat's current TTL
--   3) set_disappear_ttl(p_chat_id, p_ttl_seconds) — member-only RPC
--   4) purge_expired_messages(p_chat_id?) — member-only RPC; deletes
--      expired rows SERVER-SIDE (children cascade). Clients call this
--      on chat open / app start — opportunistic GC without pg_cron.
--   5) message_stars table + RLS        — per-user starred messages
--   6) get_starred_messages()           — my stars, membership-guarded
--   7) get_my_chats() gains disappear_ttl_seconds
--
-- IDEMPOTENT: safe to run repeatedly.
-- E2E NOTE: nothing here touches message content. TTL metadata is
-- timing-only (created_at is already server-visible); bodies stay
-- opaque ciphertext (messages.body).
-- ============================================================

-- ------------------------------------------------------------
-- 1) + 2) Columns
-- ------------------------------------------------------------
alter table public.chats add column if not exists disappear_ttl_seconds bigint;
alter table public.messages add column if not exists expires_at timestamptz;

create index if not exists messages_expires_idx
  on public.messages (expires_at)
  where expires_at is not null;

-- ------------------------------------------------------------
-- Trigger: stamp expires_at at INSERT time from the chat's TTL.
-- Column defaults are applied BEFORE a BEFORE-INSERT trigger runs,
-- so NEW.created_at is always set here.
-- Old rows keep whatever they had (null = no expiry).
-- ------------------------------------------------------------
create or replace function public.messages_expire_stamp()
returns trigger language plpgsql set search_path = public
as $$
declare ttl bigint;
begin
  if new.expires_at is not null then
    return new;
  end if;
  select c.disappear_ttl_seconds into ttl
    from public.chats c where c.id = new.chat_id;
  if ttl is not null and ttl > 0 then
    new.expires_at := coalesce(new.created_at, now()) + make_interval(secs => ttl);
  end if;
  return new;
end;
$$;

drop trigger if exists messages_expire_stamp_trg on public.messages;
create trigger messages_expire_stamp_trg
  before insert on public.messages
  for each row execute function public.messages_expire_stamp();

-- ------------------------------------------------------------
-- 3) Flip the chat's disappearing-messages TTL (any active member).
--    p_ttl_seconds null/0 = OFF; minimum 60s guards against nonsense.
-- ------------------------------------------------------------
create or replace function public.set_disappear_ttl(
  p_chat_id uuid,
  p_ttl_seconds bigint)
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
  if p_ttl_seconds is null or p_ttl_seconds <= 0 then
    update public.chats set disappear_ttl_seconds = null
      where id = p_chat_id;
  else
    if p_ttl_seconds < 60 then raise exception 'ttl too short'; end if;
    update public.chats set disappear_ttl_seconds = p_ttl_seconds
      where id = p_chat_id;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 4) Server-side GC for expired messages. message_reactions /
--    message_receipts / message_hides all reference messages
--    ON DELETE CASCADE, so deleting the message row is enough.
--    Returns the number of deleted messages.
-- ------------------------------------------------------------
create or replace function public.purge_expired_messages(
  p_chat_id uuid default null)
returns int language plpgsql security definer
set search_path = public
as $$
declare me uuid := auth.uid(); n int := 0;
begin
  if me is null then raise exception 'unauthenticated'; end if;
  if p_chat_id is not null then
    if not exists (
      select 1 from public.chat_members
      where chat_id = p_chat_id and user_id = me and left_at is null
    ) then
      raise exception 'not a member';
    end if;
    delete from public.messages
      where chat_id = p_chat_id
        and expires_at is not null
        and expires_at <= now();
    get diagnostics n = row_count;
  else
    delete from public.messages m
      using public.chat_members cm
      where cm.chat_id = m.chat_id
        and cm.user_id = me
        and cm.left_at is null
        and m.expires_at is not null
        and m.expires_at <= now();
    get diagnostics n = row_count;
  end if;
  return n;
end;
$$;

-- ------------------------------------------------------------
-- 5) Starred messages (per user). RLS: I see/toggle only my rows;
--    starring requires CURRENT membership of the message's chat.
-- ------------------------------------------------------------
create table if not exists public.message_stars (
  user_id uuid not null references public.profiles(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, message_id)
);

alter table public.message_stars enable row level security;

drop policy if exists "stars_select_own" on public.message_stars;
create policy "stars_select_own" on public.message_stars
  for select using (user_id = auth.uid());

drop policy if exists "stars_insert_own" on public.message_stars;
create policy "stars_insert_own" on public.message_stars
  for insert with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.messages m
      join public.chat_members cm
        on cm.chat_id = m.chat_id
       and cm.user_id = auth.uid()
       and cm.left_at is null
      where m.id = message_id
    )
  );

drop policy if exists "stars_delete_own" on public.message_stars;
create policy "stars_delete_own" on public.message_stars
  for delete using (user_id = auth.uid());

-- ------------------------------------------------------------
-- 6) My starred messages (row shape == fetchMessages select), still
--    guarded by CURRENT membership so leaving a chat hides its stars.
-- ------------------------------------------------------------
create or replace function public.get_starred_messages()
returns json language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(s.*), '[]'::json)
  from (
    select m.id, m.chat_id, m.sender_id, m.sender_device_id,
           m.client_msg_id, m.kind, m.body, m.reply_to,
           m.forwarded_from, m.edited_at, m.deleted_for_all_at,
           m.created_at, m.expires_at
    from public.message_stars st
    join public.messages m on m.id = st.message_id
    join public.chat_members cm
      on cm.chat_id = m.chat_id
     and cm.user_id = auth.uid()
     and cm.left_at is null
    where st.user_id = auth.uid()
    order by m.created_at desc
    limit 500
  ) s;
$$;

-- ------------------------------------------------------------
-- 7) get_my_chats: expose the chat's disappearing TTL (timing
--    metadata only — the UI renders the banner and filters locally).
-- ------------------------------------------------------------
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
      c.disappear_ttl_seconds as disappear_ttl_seconds,
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
