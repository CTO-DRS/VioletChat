# DATABASE — DRS NEXORA v0.1.0

## الجداول (17)

| الجدول | الغرض | ملاحظات أمنية |
|---|---|---|
| profiles | الهوية العامة: username, display_name, bio, avatar | تحديث ذاتي فقط |
| devices | جهاز لكل صف: identity_key (X25519), signing_key (Ed25519), SPK+توقيعها | قراءة عامة للمصادحين (مفاتيح عامة)، كتابة ذاتية |
| one_time_prekeys | مفاتيح لمرة واحدة لكل جهاز | consumed_at ذرياً عبر RPC (SKIP LOCKED) |
| chats | direct/group | **قيد كانوني فريد** لزوج direct + RPC ذري |
| chat_members | عضوية + role(owner/admin/member) + left_at | كتابة عبر RPC فقط |
| group_key_versions | إصدارات مفاتيح المجموعة | إنشاء للمشرف |
| group_key_wraps | مفتاح مغلف لكل (عضو، جهاز) | قراءة **لصاحب التغليف فقط** |
| messages | النصوص المشفرة (body jsonb) | عمودية محدودة للتحديث + guard trigger |
| message_receipts | delivered/read لكل مستخدم | كتابة ذاتية، قراءة المرسل لرسائله |
| **read_marks** (جديد) | آخر لحظة قراءة خاصة لكل (chat, user) — أساس شارة غير المقروء | سياسة قراءة ذاتية فقط + revoke كتابة؛ تُكتب حصراً عبر RPC يفرض read_receipts للإيصال العام |
| **presence** (جديد) | نبضة آخر ظهور | RLS بلا سياسات — الوصول حصراً عبر RPCين يفرضان الخصوصية |
| message_reactions | تفاعلات | emoji ≤ 8 |
| message_hides | حذف عندي | ذاتي |
| blocked_users | حجب | يمنع إرسال رسائل جديدة عبر سياسة الإدراج |
| user_settings | إعدادات jsonb (+ show_presence/read_receipts) | ذاتي |
| join_requests | طلبات انضمام | دورة عبر RPC |
| calls | سجل المكالمات | أطرافها فقط |

## الدوال المهمة (29)
- `get_or_create_direct_chat(p_other)` — سباق-آمن: canonical pair +
  `ON CONFLICT` + إعادة قراءة. يستحيل إنشاء قوسين A↔B.
- `group_start_key_version` + `group_publish_wraps` — تدوير المفاتيح
  مع تحقق صارم: النسخة = آخر نسخة+1، كل هدف تغليف عضو حالي.
- `get_prekey_bundles(p_user)` — يعيد حزم كل الأجهزة ويستهلك OPK
  واحداً لكل جهاز ذرياً: `FOR UPDATE SKIP LOCKED` + إعادة فحص
  `consumed_at` (مضمّن).
- `mark_messages_delivered/read` — upsert دفعي للإيصالات؛ `read`
  يكتب read_marks دائماً (شارة غير المقروء) والإيصال العام فقط عند
  تفعيل إعداد read_receipts (مضمّن).
- `presence_heartbeat` / `get_presence` — حضور بخصوصية مفروضة من
  الخادم (مضمّن).
- `messages_guard` (trigger) — يمنع تعديل الحقول الثابتة، يقصر
  التعديل/الحذف/التثبيت على المرسل، ويفرغ النص عند الحذف عند الجميع.
- `enforce_message_rate` (trigger) — 30 رسالة/دقيقة كحد أقصى.
- `handle_new_user` (trigger) — إنشاء profile تلقائياً عند التسجيل.
- `delete_own_account()` — حذف الحساب + تنظيف تخزين (security definer).

## الفهارس الحرجة
- `chats_direct_pair_unique` — (user_a,user_b) where type='direct'
- `messages_client_msg_unique` — (sender_id, client_msg_id): إرسال
  idempotent (إعادة المحاولة لا تنشئ تكراراً)
- `messages_chat_created_idx` — ترقيم صفحات بالكيرسور

## الترقية من v4 (متكامل)
- المخطط idempotent: أعمدة جديدة عبر `ADD COLUMN IF NOT EXISTS`.
- بقايا v4 (`messages.content/nonce/mac`) تُحذف الآن نهائياً من
  القاعدة الحية عبر `DROP COLUMN IF EXISTS` (مضمّن) — كانت تُهمَل فقط.
- المشغل القديم `messages_guard_trigger` يُستبدل بالنسخة الجديدة.

## Realtime
جداول المنشور: messages, message_receipts, message_reactions, chats,
chat_members, join_requests, calls — RLS تُطبَّق على المستمعين.

## push_tokens (مضمّن)
| العمود | النوع | الوصف |
|---|---|---|
| token | text PK | توكن FCM للجهاز |
| user_id | uuid FK→auth.users | المالك (cascade) |
| platform | text | 'android' |
| updated_at | timestamptz | آخر تحديث |

- RLS: `push_tokens_all_own` — كل مستخدم يقرأ/يكتب توكناته فقط.
- الغرض: توجيه إشعارات FCM عبر دالة `push-dispatch` (data-only،
  بلا محتوى — انظر SECURITY.md).

## سجل الرقع على القاعدة الحية (حالة فعلية موثقة)
| التاريخ | الرقعة | الأثر |
|---|---|---|
| 2026-10-05 | `patches/2026-10-05-fix-signup-profiles-legacy-columns.sql` | إسقاط أعمدة profiles القديمة (v4) التي كانت تُسقط كل تسجيل (23502) — VERIFIED |
| 2026-10-07 | `patches/2026-10-07-fix-chat-opening-missing-server-objects.sql` (rev.2) | إصلاح «تعذر فتح المحادثة». السبب الجذري **مُثبت بجلسة حقيقية (VERIFIED)**: خطأ `42P10` — الفهرس الفريد `chats_direct_pair_unique` جزئي (`where type='direct'`) بينما هدف `ON CONFLICT` في جسم `get_or_create_direct_chat` كان بلا المسند، فلا يمكن لـ PostgreSQL استنتاج الفهرس الجزئي → كل فتح محادثة مباشرة يفشل خادمياً (نفس الخطأ الكامن كان في schema.sql وأُصلح فيه أيضاً). تضيف الرقعة أيضاً: دالة `get_my_chats` (شبح — يناديها التطبيق منذ بداية المشروع بلا تعريف في أي نسخة)، `presence_heartbeat`/`get_presence` + جداول `presence`/`read_marks`/`push_tokens` + RLS + grants. ملاحظة مصححة: `register_device`/`topup`/`ack` كانت **موجودة وسليمة** على الحي (فحص أولي صنّفها مفقودة بسبب معاملات غير مطابقة — PGRST202 يعود أيضاً عند عدم تطابق التوقيع). idempotent — آمنة لإعادة التشغيل. الرابط العام: https://cto-drs.github.io/nexora-verify/patch-chat-fix.sql |
| 2026-10-07 | **تطبيق الرقعة فعلياً (rev.2 + إصلاح json_agg)** | نُفّذت بواسطتنا عبر Management API برمز `sbp_` شخصي زوّد به المالك: 31 عبارة + `notify pgrst, 'reload schema'`. تصحيح أثناء التنفيذ: `json_agg(row)` → `json_agg(s.*)` في get_my_chats (صُحح في الرقعة وفي schema.sql). **التحقق الحي كامل**: فتح محادثة 200+chat_id، محادثاتي 200 بصف حقيقي، الحضور 204/200، غير المقروء 200، الإيصالات 204، push_tokens 201/200/204 |

**قاعدة عامة**: بعد أي تحديث لـ `schema.sql` يجب على المالك تشغيله
كاملاً في SQL Editor، أو تطبيق الرقع الجديدة من `supabase/patches/`.
