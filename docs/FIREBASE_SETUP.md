# إعداد Firebase لتطبيق Violet Chat

## الحالة الفعلية (مُتحقَّق منها بتاريخ 2026-10-22 عبر REST API)

مشروع Firebase **`drs-nexora`** موجود مسبقاً (أنشئ أصلاً لتكامل دفع FCM)،
و`google-services.json` الموجود في `android/app/` مسجّل لحزمة
`com.drs.nexora` — نفس `applicationId` الحالي، فلا حاجة لمشروع جديد
ولا لتسجيل حزمة جديدة.

الفحص الحي أظهر:

| المكوّن | الحالة |
|---------|--------|
| المشروع + مفتاح Android | موجود (`1:1045783358683:android:60113803…`) |
| **Authentication — Email/Password** | **غير مفعّل** (`CONFIGURATION_NOT_FOUND`) |
| **Cloud Firestore** | **غير مُنشأ** (`NOT_FOUND: database does not exist`) |
| Cloud Messaging (FCM) | مُهيأ ويستقبل الرموز من التطبيق |

> التطبيق مصمم لهاتين الحالتين: قبل التفعيل يعمل بتدفق الحساب القائم
> (Supabase)، وبعد التفعيل تُعرض هوية Violet كاملة تلقائياً — لا يلزم
> أي إعادة بناء (الكود يكتشف التوفر عند كل إقلاع).

## خطوات التفعيل اليدوية (مرة واحدة — من حساب مالك المشروع)

### 1) تفعيل Email/Password
1. [console.firebase.google.com](https://console.firebase.google.com) → مشروع **drs-nexora**
2. Build → **Authentication** → Get started
3. تبويب Sign-in method → **Email/Password** → Enable → Save
4. (اختياري الآن) Email enumeration protection: الإعداد الافتراضي جيد.

### 2) إنشاء Firestore
1. Build → **Firestore Database** → Create database
2. الموقع الأقرب (مثلاً `eur3` أوروبا — لا يمكن تغييره لاحقاً)
3. ابدأ في **الوضع المقفل** ثم الصق قواعد الملف `firestore.rules`
   من جذر المستودع (أو انشرها بـ `firebase deploy --only firestore:rules`
   بعد `firebase init`).

### 3) التحقق من التفعيل (بلا هاتف)
```bash
KEY="AIzaSy…current_key من google-services.json"
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"probe-your-address@gmail.com","password":"xProbeViolet#2026","returnSecureToken":false}'
```
- `200` → مفعّل (احذف الحساب التجريبي من Console → Authentication → Users)
- `OPERATION_NOT_ALLOWED` / `CONFIGURATION_NOT_FOUND` → أعد الخطوة 1
- Firestore: `GET https://firestore.googleapis.com/v1/projects/drs-nexora/databases/(default)/documents/users` → أي استجابة غير «does not exist» تعني أنه مُنشأ.

### 4) تطبيق يفتح بعد التفعيل مباشرة
لا شيء إضافي — أعد فتح التطبيق: شاشة Violet الزجاجية ستظهر تدفقات
Firebase (إنشاء حساب/دخول/استعادة) والملف يُنشأ في `users/{uid}`.

## تفعيل زر «المتابعة عبر Google» (v0.1.1 — خطوات إلزامية)

زر Google موجود الآن على شاشة الهوية. **قبل إتمام الخطوات أدناه سيرد
الزر برسالة واضحة** (DEVELOPER_ERROR مُترجَم) — لأن ملف
`google-services.json` الحالي لا يحتوي أي `oauth_client` (متحقق من
الملف نفسه)، وبصمة توقيع APK غير مسجلة على المشروع.

### الخطوات (من حساب مالك المشروع — 3 دقائق)

1. **إضافة بصمة التوقيع**:
   - افتح https://console.firebase.google.com → مشروع **drs-nexora**
   - ⚙️ **Project settings** → **Your apps** → تطبيق Android
     `com.drs.nexora` → **Add fingerprint**
   - الصق بصمة **SHA-1** لتوقيع الإنتاج (مستخرجة من `nexora-release.jks` —
     نفس التوقيع المستخدم في كل الإصدارات المنشورة):

     ```
     92:4D:6C:62:09:7E:C8:9E:99:7D:A0:69:40:FA:C9:61:AD:EB:37:6B
     ```

   - وأضف أيضاً بصمة **SHA-256** (تُستخدم لاحقاً لـApp Check):

     ```
     AE:74:AD:D0:9A:58:F8:06:3A:B4:5E:18:C1:B9:9E:9E:13:52:AC:F2:F4:6A:F6:77:89:D7:4F:09:7E:44:FA:6B
     ```

2. **تمكين مزوّد Google**:
   - **Authentication** → **Sign-in method** → **Add new provider**
   - اختر **Google** → اضغط **Enable** → اختر بريد الدعم (project
     support email) → **Save**

3. **إعادة تنزيل google-services.json** (خطوة حاسمة — لا تُتخطَّ):
   - بعد إضافة البصمة، من Project settings → Your apps → Android →
     **Download google-services.json** (سيحوي الآن `oauth_client`
     بحزمة `com.drs.nexora`)
   - استبدل به الملف `android/app/google-services.json` في المستودع
     (أو أرسله لصاحب الوصول ليبني الإصدار القادم) — **بدون هذه الخطوة
     يبقى الزر يرد برسالة «غير مفعّل» لأن المورد `default_web_client_id`
     يُولَّد عند البناء من هذا الملف**

4. **البناء**: أي إصدار قادم (v0.1.2 فأعلى) يُبنى بعد استبدال الملف —
   الزر يعمل بعدها مباشرة: منتقي حسابات Google → جلسة Firebase →
   ملف Firestore → جلسة مراسلة بمفتاح مشفر على الجهاز.

### كيف يعمل التدفق داخلياً (للاطلاع)

- الحصول على رموز Google ثم `GoogleAuthProvider.credential` →
  `FirebaseAuth.signInWithCredential` (لا كلمات مرور نهائياً).
- حساب Google بلا كلمة مرور بينما نظام المراسلة يتطلب واحدة: يُولَّد
  مفتاح عشوائي مشفر (40 حرفاً) مرة واحدة، يُنشئ جلسة المراسلة، ويُحفظ
  في **تخزين الجهاز المشفر** (Android Keystore عبر
  `flutter_secure_storage`) — لا يدخل Firestore ولا أي سجل، وليس
  كلمة مرور اختارها المستخدم. إعادة الدخول لاحقاً على نفس الجهاز
  تلقائية بلا أي إدخال.
- حالات حواف موثقة: مستخدم قديم بنفس البريد على نظام المراسلة ←
  رسالة توجيه إلى «حساب مراسلة قائم»؛ إلغاء منتقي الحسابات ← صمت
  تام؛ فقدان المفتاح (إعادة تثبيت) ← نفس رسالة التوجيه.

## سياسة أمان الملفات والقواعد

- `google-services.json` = **إعداد عميل علني بطبيعته** (مضمن في كل APK
  منشور أصلاً) — ليس سراً ولا بديلاً عن القواعد. الحماية الحقيقية هي
  `firestore.rules` (مقصورة على المالك) وعلى Supabase RLS (قائمة).
  المستودع **عام** والملف متتبع عمداً وفق هذه السياسة الموثقة.
- **مفاتيح توقيع APK** لا تعيش في المستودع إطلاقاً: تُحقن في CI من
  الأسرار `ANDROID_KEYSTORE_B64` + `ANDROID_KEY_PROPERTIES` (المالك
  يضبطها مرة واحدة من Settings → Secrets → Actions)، وحارس التوقيع
  في الـworkflow يمنع نشر أي حزمة خارج هوية الإنتاج.
- **ممنوع منعاً باتاً**: وضع `service_role` أو مفاتيح إدارية في كود
  التطبيق أو المستودع. مفاتيح الخادم (مثل Firebase service account
  لاستدعاء FCM من الخادم) تبقى عند المالك وحده (موثق في BUILD.md).

## حدود v0.1.0 الموثقة بصدق

- استعادة كلمة المرور على Firebase لا تغيّر تلقائياً كلمة جلسة
  المراسلة (النظامان منفصلان): بعد الاستعادة، عند الدخول أول مرة
  سيطلب التطبيق «حساب مراسلة قائم» أو إعادة تعيين على النظام القديم
  إن اختلفت — التحسين المؤجل: مزامنة موحدة في v0.1.1.
- إنشاء الملف في Firestore يتطلب تفعيل الخطوة 1 و2 قبل أن ينجح فعلياً.
