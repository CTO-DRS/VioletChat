-- ============================================================
-- v0.1.10 — Stories (حالات الأصدقاء المشفرة)
-- استطلاعات الرأي لا تحتاج جداول جديدة (رسائل kind=poll/pollVote
-- مشفرة E2E عبر مسار messages القائم).
--
-- الحالات تحتاج 3 جداول:
--   violet_stories       الصف الرئيسي (المحتوى المشفر jsonb)
--   violet_story_wraps   مفتاح الحالة مغلفاً لكل جهاز صديق
--   violet_story_views   إيصالات المشاهدة (بيانات وصفية كما الإيصالات)
-- + تعريف «الصديق» على الخادم = محادثة مباشرة قائمة بين الطرفين
-- + سياسات تخزين لمسار media/stories/{authorId}/{file}.enc
-- + تقوية سياسات media القائمة ضد مسارات غير uuid (السلاست cast)
-- ============================================================

-- 1) دالة الصداقة: محادثة مباشرة نشطة بيني وبين الطرف الآخر
create or replace function public.is_direct_friend(other uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from chats c
    join chat_members a on a.chat_id = c.id and a.user_id = auth.uid()
                        and a.left_at is null
    join chat_members b on b.chat_id = c.id and b.user_id = other
                        and b.left_at is null
    where c.type = 'direct'
      and c.deleted_at is null
  );
$$;

-- 2) جداول الحالات
create table if not exists violet_stories (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references profiles(id) on delete cascade,
  body jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);
create index if not exists idx_stories_author on violet_stories(author_id, created_at desc);
create index if not exists idx_stories_expiry on violet_stories(expires_at);

create table if not exists violet_story_wraps (
  story_id uuid not null references violet_stories(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  device_id text not null,
  wrapped text not null,
  nonce text not null,
  primary key (story_id, user_id, device_id)
);
create index if not exists idx_story_wraps_user on violet_story_wraps(user_id);

create table if not exists violet_story_views (
  story_id uuid not null references violet_stories(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, user_id)
);

-- 3) RLS
alter table violet_stories enable row level security;
alter table violet_story_wraps enable row level security;
alter table violet_story_views enable row level security;

drop policy if exists stories_insert_own on violet_stories;
create policy stories_insert_own on violet_stories
  for insert to authenticated
  with check (author_id = auth.uid());

drop policy if exists stories_select_ring on violet_stories;
create policy stories_select_ring on violet_stories
  for select to authenticated
  using (author_id = auth.uid() or public.is_direct_friend(author_id));

drop policy if exists stories_delete_own on violet_stories;
create policy stories_delete_own on violet_stories
  for delete to authenticated
  using (author_id = auth.uid());

drop policy if exists story_wraps_insert_own_story on violet_story_wraps;
create policy story_wraps_insert_own_story on violet_story_wraps
  for insert to authenticated
  with check (
    exists (select 1 from violet_stories s
            where s.id = story_id and s.author_id = auth.uid())
  );

drop policy if exists story_wraps_select_mine on violet_story_wraps;
create policy story_wraps_select_mine on violet_story_wraps
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists story_views_insert_own on violet_story_views;
create policy story_views_insert_own on violet_story_views
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists story_views_select on violet_story_views;
create policy story_views_select on violet_story_views
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from violet_stories s
               where s.id = story_id and s.author_id = auth.uid())
  );

-- 4) دالة استخراج chatId من مسار الوسائط بأمان (null للمسارات غير المطابقة)
create or replace function public.media_chat_id(p_name text)
returns uuid
language sql
immutable
as $$
  select case
    when p_name ~ '^media/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/'
    then (split_part(p_name, '/', 2))::uuid
  end;
$$;

-- 5) تقوية سياسات media القائمة (تجنب فشل cast على مسارات stories/)
drop policy if exists media_select_member on storage.objects;
create policy media_select_member on storage.objects
  for select to authenticated
  using (
    bucket_id = 'media'
    and public.media_chat_id(name) is not null
    and public.is_chat_member(public.media_chat_id(name), auth.uid())
  );

drop policy if exists media_insert_member on storage.objects;
create policy media_insert_member on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'media'
    and split_part(name, '/', 3) = auth.uid()::text
    and public.media_chat_id(name) is not null
    and public.is_chat_member(public.media_chat_id(name), auth.uid())
  );

drop policy if exists media_delete_owner on storage.objects;
create policy media_delete_owner on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'media'
    and split_part(name, '/', 3) = auth.uid()::text
  );

-- 6) سياسات وسائط الحالات: media/stories/{authorId}/{file}.enc
drop policy if exists media_story_insert_own on storage.objects;
create policy media_story_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'media'
    and name like 'stories/' || auth.uid()::text || '/%'
  );

drop policy if exists media_story_select_ring on storage.objects;
create policy media_story_select_ring on storage.objects
  for select to authenticated
  using (
    bucket_id = 'media'
    and (
      name like 'stories/' || auth.uid()::text || '/%'
      or (
        name ~ '^stories/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/'
        and public.is_direct_friend((split_part(name, '/', 3))::uuid)
      )
    )
  );

drop policy if exists media_story_delete_own on storage.objects;
create policy media_story_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'media'
    and name like 'stories/' || auth.uid()::text || '/%'
  );

-- 7) تنظيف دوري للحالات المنتهية (استدعاء انتهازي من العميل)
create or replace function public.purge_expired_stories()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted int;
begin
  delete from violet_stories where expires_at <= now();
  get diagnostics deleted = row_count;
  return deleted;
end;
$$;
