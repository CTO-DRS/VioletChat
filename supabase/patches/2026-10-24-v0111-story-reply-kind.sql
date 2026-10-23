-- v0.1.11 — ردود الحالات: رسالة kind='storyReply' تُرسل داخل محادثة
-- مباشرة مع مؤلف الحالة. الحمولة الداخلية مشفرة E2E وتحمل:
--   kind: 'storyReply'
--   text: نص الرد
--   storyRef: معرف الحالة (uuid عمومي على violet_stories) — داخل التشفير
-- الخادم لا يرى نص الرد ولا محتوى الحالة؛ يرى النوع فقط كأي رسالة.
-- (تعديل الاستطلاعات لا يحتاج رقعة: messages_guard يسمح للمرسل بتحديث
--  body/edited_at أصلاً — نفس مسار تعديل الرسائل النصية.)
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','media','system','poll','pollVote','storyReply'));
