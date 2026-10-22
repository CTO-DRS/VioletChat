# Violet Chat — فايلويت شات

**تطبيق مراسلة Android بهوية بنفسجية، مشفّر طرف-لطرف** — مبني بـ
Flutter + Firebase Authentication + Cloud Firestore + Supabase (نقل
المراسلة)، باسم مركزي واحد (`AppConfig.appName = "Violet Chat"` /
`فايلويت شات`).

> Violet Chat هو تحويل الهوية والتطوير القاعدي لتطبيق مراسلة مشفرة
> قائم (DRS NEXORA سابقاً) — بلا حذف أي ميزة قائمة. منذ **v0.1.2**
> هوية الحزمة هي `com.drs.violetchat` مطابقةً لتسجيل Firebase الرسمي
> (مشروع `violetchat-cea68` — ووثّق أثر ذلك على التثبيت في
> CHANGELOG v0.1.2). الإصدار الحالي: **v0.1.6** (versionCode 13).

---

## الحالة الصادقة للميزات

| الميزة | الحالة |
|---|---|
| هوية Violet Chat (اسم/شاشات/إشعارات) | VERIFIED (كود + مسار CI) |
| حسابات Violet — Firebase Auth (إنشاء/دخول/خروج/استعادة) | IMPLEMENTED — التفعيل السحابي يتطلب خطوة Console (FIREBASE_SETUP.md) |
| ملف المستخدم Firestore `users/{uid}` | IMPLEMENTED — قواعد `firestore.rules` مقصورة على المالك |
| تدفق الحساب القائم (Supabase) كوضع احتياطي | VERIFIED (كشف تلقائي وقت التشغيل) |
| هوية تشفير لكل جهاز (IK/SPK/OPK) | VERIFIED (اختبارات آلية) |
| X3DH + Double Ratchet | VERIFIED (اختبارات آلية: FS، إعادة الإرسال، خارج الترتيب) |
| التشفير الثنائي طرف-لطرف | VERIFIED (اختبارات) — NOT VERIFIED ميدانياً |
| المجموعات + تدوير المفاتيح | IMPLEMENTED — NOT VERIFIED ميدانياً |
| رسائل نصية + وسائط مشفرة | IMPLEMENTED — NOT VERIFIED ميدانياً |
| مكالمات WebRTC ثنائية + جماعية (mesh ≤ 8) | IMPLEMENTED — NOT VERIFIED ميدانياً |
| أوفلاين + مزامنة | IMPLEMENTED — NOT VERIFIED ميدانياً |
| Realtime + مؤشر الكتابة + حضور «متصل الآن» | IMPLEMENTED — NOT VERIFIED ميدانياً |
| إشعارات محلية | IMPLEMENTED |
| إشعارات نظام عند التطبيق مغلق | عميل FCM مدمج — الإرسال من الخادم يتطلب مفتاح المالك |
| قفل حيوي اختياري (بصمة/وجه) | IMPLEMENTED |
| بناء APK + اختبارات | آلي عبر GitHub Actions (workflow في هذا المستودع) |

لا واجهات وهمية: ما لم يُنفذ كاملاً موثق بحالته الحقيقية.

---

## البدء السريع (من مستودع نظيف)

```bash
# 1) المتطلبات: JDK 17 + Flutter 3.35.1 + Android SDK (compileSdk 35, NDK 26.1.10909125)
flutter pub get
flutter test                 # اختبارات التشفير والهوية والواجهة
flutter run                  # تشغيل مباشر
flutter build apk --release  # بناء الإصدار
```

- إعدادات Supabase العامة مضبوطة مسبقاً في `lib/core/config/app_config.dart`
  (قيم **عامة بالتصميم** — لا سر حقيقي في الكود).
- Firebase: `android/app/google-services.json` جاهز (مشروع FCM القائم)؛
  تفعيل **Authentication** و**Firestore** خطوتان يدويتان موثقتان حرفياً
  في `docs/FIREBASE_SETUP.md` مع قواعد `firestore.rules` الجاهزة.
- التوقيع: من أسرار CI (`ANDROID_KEYSTORE_B64` + `ANDROID_KEY_PROPERTIES`)
  — لا مفتاح توقيع في المستودع إطلاقاً؛ المالك يضبطها من
  Settings → Secrets → Actions مرة واحدة.

## طبقة هوية Violet (v0.1.0)

- `lib/services/violet_auth_service.dart` — Firebase Auth + تحقق نقي +
  خرائط أخطاء عربي/إنجليزي (كلمة المرور لا تُخزّن في أي مكان محلي).
- `lib/services/violet_profile_service.dart` — `users/{uid}` بمعاملة
  آمنة غير مدمّرة.
- `lib/state/violet_auth_controller.dart` — التدفقات + جسر جلسة
  المراسلة (نفس البيانات في الذاكرة فقط) + منع الإرسال المزدوج.
- `lib/features/auth/violet_auth_screen.dart` — شاشة «Violet Glass».

## هيكل المستودع

```
lib/
├── core/          config, constants, errors, logging, storage (sqlite), utils
├── crypto/        primitives, x3dh, double_ratchet, group_keys, identity, envelope
├── data/          models + repositories
├── services/      violet identity, auth, sessions, message crypto, sync, realtime…
├── state/         controllers (Provider) — violet_auth_controller + القائمة
├── features/      auth (Violet Glass), chats, messages, groups, profile, calls…
├── routing/       named routes
└── theme/         «Violet Glass» design system (داكن/فاتح، RTL)

android/           مشروع أندرويد كامل (gradle, توقيع, أذونات, قنوات إشعارات)
firestore.rules    قواعد Firestore الآمنة (مقصورة على المالك)
supabase/          schema + patches — المراسلة السحابية
test/              اختبارات التشفير والهوية والواجهة
docs/              FIREBASE_SETUP, ARCHITECTURE, SECURITY, BUILD, CHANGELOG…
```

## الأمان باختصار

- بيانات اعتماد Violet يديرها **Firebase Authentication** — لا كلمة
  مرور في Firestore ولا SharedPreferences ولا ملفات محلية.
- مفاتيح التشفير الخاصة **لا تخرج من الهاتف** (Keystore عبر
  flutter_secure_storage).
- جلسات Double Ratchet لكل جهاز نظير: FS + حماية إعادة + مفاتيح
  رسالة منفصلة. المجموعات بمفاتيح متناوبة عند أي تغيير عضوية.
- Firestore: قواعد صارمة owner-only (لا قاعدة عامة إطلاقاً). Supabase:
  RLS على كل جدول.
- الخادم يرى نصاً مشفراً + توجيهاً دنيا فقط. التفاصيل: `docs/SECURITY.md`.

## المستودعات ذات الصلة

- **هذا المستودع**: مصدر Violet Chat (عام — البناء والاختبارات
  مجانية عبر Actions، والإصدارات قابلة للتنزيل العلني).
- `CTO-DRS/nexora-verify`: موقع التحقق العام + مرآة التحميل (ترث من
  المرحلة السابقة وتبقى صالحة للتنزيلات).

---

## English (short)

**Violet Chat** — an end-to-end encrypted Android messenger (Flutter)
with a premium dark-violet glass identity. Firebase Authentication
handles credentials (email/password sign-up, sign-in, logout, password
reset), Cloud Firestore stores `users/{uid}` profiles behind
owner-only security rules, and the X3DH + Double Ratchet messaging
core is fully preserved. Requires manual Firebase console enablement
(see `docs/FIREBASE_SETUP.md`); until then the app transparently falls
back to the legacy auth flow. Build: JDK 17 + Flutter 3.35.1,
`flutter test` then `flutter build apk --release`.

License: pending owner decision (no license file shipped by default).
