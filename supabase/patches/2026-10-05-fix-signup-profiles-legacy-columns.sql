-- ============================================================
-- DRS NEXORA — رقعة إصلاح التسجيل (2026-10-05)
-- المشكلة: كل تسجيل جديد يفشل بخطأ 23502
--   "null value in column \"public_key\" of relation \"profiles\"
--    violates not-null constraint"
-- السبب: قاعدة البيانات الحية ما زالت تحمل أعمدة legacy من مخطط v4
--   القديم في جدول profiles (مثل public_key NOT NULL)، بينما مشغّل
--   إنشاء الحساب on_auth_user_created يُدخل أعمدة v0.1.0 فقط.
-- الإصلاح: إبقاء أعمدة v0.1.0 حصراً وإسقاط كل بقايا v4 (قابل للتشغيل
--   المتكرر بلا أذى — إسقاط عميلة غير موجودة عملية محايدة).
-- التشغيل: لوحة Supabase → SQL Editor → لصق هذا الملف كاملاً → Run
-- ============================================================

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
    raise notice 'dropped legacy column: %', c.column_name;
  end loop;
end $$;

-- تحقق فوري: يجب أن يُظهر هذا الاستعلام أعمدة v0.1.0 السبعة فقط
select column_name, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles'
order by ordinal_position;
