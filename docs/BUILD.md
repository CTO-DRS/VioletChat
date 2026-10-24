# BUILD — DRS NEXORA

## الطريقة 1 (الموصى بها): البناء السحابي التلقائي
كل push إلى `main` يشغّل `android-ci.yml`:
1. `flutter analyze` (الأخطاء والتحذيرات تفشل البناء)
2. `flutter test`
3. `flutter build apk --release` بتوقيع keystore مشفر في Secrets
4. نشر APK إلى GitHub Release + Artifacts

الحمولة الناتجة قابلة للتثبيت مباشرة ("مصادر غير معروفة").

## الطريقة 2: محلياً
```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# الناتج: build/app/outputs/flutter-apk/app-release.apk
# أصغر لكل معمارية:
flutter build apk --release --split-per-abi
# arm64: app-arm64-v8a-release.apk (~38MB) — الأغلبية الحالية من الهواتف
```
المتطلبات: Flutter 3.27.x (Dart 3.6)، JDK 17، Android SDK 35.

### TURN للمكالمات (اختياري — وقت البناء فقط)
المكالمات تعمل بـ STUN على الشبكات المتساهلة. خلف NAT صارم يلزم خادم
TURN، وتُحقن بياناته وقت البناء — **لا تُكتب في الكود ولا Git أبداً**:
```bash
flutter build apk --release \
  --dart-define=TURN_URL=turn:turn.example.com:3478 \
  --dart-define=TURN_USERNAME=myuser \
  --dart-define=TURN_CREDENTIAL=mysecret
```
عند إسقاط المتغيرات يُبنى التطبيق بلا TURN (STUN فقط) — لا فشل ولا
أزرار وهمية. في CI أضفها كـ Repo Secrets عند الحاجة.

### ذاكرة البناء (gradle.properties)
الضبط الحالي (`-Xmx1536m`, metaspace 512m, workers 1, **Kotlin in-process**)
مُتحقَّق منه على آلة **3.9GB RAM بلا swap** — الذروة الكلية (Gradle + Dart
AOT + النظام) تبقى داخل الذاكرة الفعلية، ويبقى ضبطًا آمنًا على CI الأكبر.
طلب ذاكرة أعلى من RAM المتاح يقتل الـ daemon (OOM) ويفشل البناء.
ملاحظة: يلزم JDK كامل (Temurin 17) — JRE بدون `jlink` يفشل في
`JdkImageTransform`.

## الطريقة 3: FlutLab
1. استورد المشروع من GitHub أو ارفع ملفات المشروع.
2. FlutLab يكفيه `lib/` و`pubspec.yaml` و`android/` — المجلد الأخير
   موجود كاملاً في المستودع فلا يولّد شيئاً من تلقاء نفسه.
3. Build → APK.

## التوقيع
- **الوضع الحالي (محدّث — تصحيح ادعاء قديم)**: المستودع **عام** ولا
  يحتوي أي ملف keystore — لا `nexora-release.jks` ولا
  `android/key.properties` (تم التحقق آلياً من كامل تاريخ Git).
  التوقيع يعتمد حصراً على GitHub Actions Secrets:
  - `ANDROID_KEYSTORE_B64` — keystore الإصدار بترميز base64
  - `ANDROID_KEY_PROPERTIES` — محتوى key.properties (store/key كلمة
    المرور + alias)
  ويكتبهما الـ workflow إلى القرص وقت البناء فقط، ثم يتحقق من بصمة
  شهادة SHA-256 قبل نشر أي إصدار (build-release.yml).
  SHA-256 الشهادة المنشورة:
  `AE:74:AD:D0:9A:58:F8:06:3A:B4:5E:18:C1:B9:9E:9E:13:52:AC:F2:F4:6A:F6:77:89:D7:4F:09:7E:44:FA:6B`
- بناء محلي بلا Secrets: Gradle يسقط إلى مفتاح debug (مناسب للاختبار
  فقط، عمداً موثق في app/build.gradle).
- لتوليد keystore خاص بك (لا ترفعه للمستودع إطلاقاً):
```bash
keytool -genkeypair -v -keystore nexora-release.jks -alias nexora \
  -keyalg RSA -keysize 2048 -validity 10000
```
ثم أنشئ `android/key.properties` محلياً:
```
storeFile=nexora-release.jks
storePassword=...
keyAlias=nexora
keyPassword=...
```

## الإعدادات
`lib/core/config/app_config.dart`:
- `supabaseUrl` + `supabasePublishableKey` (مضبوطة مسبقاً؛ عامة بالتصميم).
- `enableCalls` (مكالمات ثنائية)، `enableGroupCalls` (غير منفذة — لا
  تفتحها قبل التنفيذ الفعلي)، `enableSystemPush` (FCM — مُفعّل منذ بداية المشروع، مسامح إذا غاب المجسّم).

## أذونات Android
INTERNET, ACCESS_NETWORK_STATE, RECORD_AUDIO, CAMERA, POST_NOTIFICATIONS,
READ_MEDIA_IMAGES/VIDEO, VIBRATE, WAKE_LOCK, BLUETOOTH_CONNECT,
FOREGROUND_SERVICE(_MICROPHONE/_CAMERA) — جميعها في AndroidManifest مع
قنوات إشعار (رسائل/مكالمات) وdeep link للدعوات `drsnexora://invite/…`.

## FCM — الإشعارات النظامية (خطوات المالك، مرة واحدة)
تكامل العميل جاهز ومبني. لتفعيل الإيصال الكامل للتطبيق المغلق:

1. **تطبيق SQL**: شغّل قسم `push_tokens` من `supabase/schema.sql`
   (القسم 18) في Supabase SQL Editor.
2. **مفتاح حساب الخدمة**: Firebase Console → Project settings →
   Service accounts → Generate new private key (JSON).
3. **الأسرار**:
   ```
   supabase secrets set FIREBASE_SERVICE_ACCOUNT='<محتوى JSON كاملًا>'
   supabase secrets set PUSH_WEBHOOK_SECRET='<نص عشوائي طويل>'
   ```
4. **النشر**: `supabase functions deploy push-dispatch`
5. **Webhook**: Supabase Dashboard → Database → Webhooks → جدول
   `messages` → حدث INSERT → POST إلى رابط الدالة مع الهيدر
   `x-webhook-secret` بنفس قيمة السر.
