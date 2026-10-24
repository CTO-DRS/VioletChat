-- v0.1.12 — الموقع المشفر + بطاقات جهات الاتصال المشفرة.
-- رسالتان جديدتان:
--   kind='location'  — الحمولة الداخلية المشفرة E2E تحمل:
--     kind: 'location', loc: {lat, lng, label?}
--   kind='contact'   — الحمولة الداخلية المشفرة E2E تحمل:
--     kind: 'contact', card: {username, name}
-- الخادم لا يرى الإحداثيات ولا الأسماء — النوع فقط كأي رسالة.
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','media','system','poll','pollVote','storyReply','location','contact'));
