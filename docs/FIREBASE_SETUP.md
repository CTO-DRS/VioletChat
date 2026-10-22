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
