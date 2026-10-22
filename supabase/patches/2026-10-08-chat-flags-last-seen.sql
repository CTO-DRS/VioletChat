-- ============================================================
-- v0.1.0 patch — chat member flags (pin / mute / archive)
--                     + last-seen exposure
-- Date: 2026-10-08
-- Applied via Management API (scripts/apply_v570_patch.py).
-- Idempotent: safe to re-run.
--
-- 1) chat_members.pinned_at / archived_at — per-member chat state
--    (muted_until already exists since the v4 schema).
-- 2) set_chat_flags(p_chat_id, p_pinned, p_muted, p_archived) —
--    SECURITY DEFINER, because chat_members deliberately has NO
--    UPDATE policy (membership writes go through RPCs by design).
--    A member may only flip their OWN row.
-- 3) get_my_chats() — expose my_pinned_at / my_muted_until /
--    my_archived_at so the app can render pin/mute/archive states.
--    Old clients ignore the extra JSON keys (harmless).
-- 4) presence_heartbeat() — retention widened 1 hour -> 30 days so
--    "آخر ظهور" stays meaningful after a user goes offline.
--    get_presence() still filters to the 70-second online window,
--    so online-detection semantics are unchanged.
-- 5) get_last_seen(p_user_ids) — same privacy rules as get_presence
--    (shared chat + show_presence respected), 30-day window.
-- ============================================================

-- ---------- 1) columns ----------
alter table public.chat_members
  add column if not exists pinned_at timestamptz;
alter table public.chat_members
  add column if not exists archived_at timestamptz;

-- ---------- 2) set_chat_flags RPC ----------
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

  -- must be an ACTIVE member of this chat
  if not exists (
    select 1 from public.chat_members
    where chat_id = p_chat_id and user_id = me and left_at is null
  ) then
    raise exception 'not a member';
  end if;

  -- tri-state: true = set, false = clear, null = leave unchanged
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

-- ---------- 3) get_my_chats with my flags ----------
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

-- ---------- 4) presence retention: 1 hour -> 30 days ----------
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

-- ---------- 5) get_last_seen ----------
-- Same admission rules as get_presence (shared chat + target's
-- show_presence setting), but reports up to 30 days back.
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
