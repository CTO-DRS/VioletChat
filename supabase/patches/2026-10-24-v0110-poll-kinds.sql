-- v0.1.10 — توسيع قيد kind لقبول الاستطلاعات المشفرة:
--   poll     = رسالة الاستطلاع (السؤال والخيارات داخل التشفير)
--   pollVote = رصيص مشفر واحد (reply_to يشير إلى صف الاستطلاع)
-- طبّقت حياً في 2026-10-24 عبر scripts/patch_messages_kind.py.
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','media','system','poll','pollVote'));
