# نتائج البناء والاختبارات — Violet Chat v0.1.0

> كل الأرقام أدناه **حقيقية من سجلات GitHub Actions** (روابط التشغيل
> مرفقة) — لا تقديرات ولا افتراضات. آخر تحديث: 2026-10-22.

## سجل التشغيلات (قصة البناء الصادقة)

| # | Run | النتيجة | السبب الحقيقي |
|---|-----|---------|----------------|
| 1 | 39716056378 | ❌ فوري بلا خطوات | استنفاد دقائق Actions للمستودعات الخاصة («spending limit») → الحل: مستودع عام + أسرار CI |
| 2 | 39716526131 | ❌ Unit tests | خطأ ترجمة: `Timestamp` بلا استيراد cloud_firestore في ملف اختبار |
| 3 | 39716857841 | ❌ Build APK | خطأ ترجمة: مسارات نسبية خاطئة في violet_auth_controller (`../services/`) — الاختبارات لم تلتقطه لأنها تستورد الخدمات مباشرة → أُضيفت خطوة analyze إلزامية |
| 4 | 39718139070 | ❌ Static analysis | `Positioned` لا يقبل start/end → `PositionedDirectional` (RTL صحيح) |
| 5 | **39718403304** | ✅ **نجاح كامل** | — |

## النتائج النهائية (run 39718403304)

### التحليل الساكن
- `flutter analyze --no-fatal-infos` → نجاح (خطآن أُصلحا، 4 infos تلميحية قديمة لا تفشل البناء).

### الاختبارات
- **`flutter test` → 85/85 ناجحة** (🎉 85 tests passed):
  - التشفير (X3DH/Double Ratchet/الهوية) — اختبارات المرحلة السابقة كاملة.
  - طبقة هوية Violet الجديدة: validators، خرائط الأخطاء عربي/إنجليزي،
    حمولة users/{uid} (لا كلمة مرور)، وضع legacy، جلسة Violet.
  - الواجهة: شاشة المصادقة بلا أخطاء، smoke، الإعدادات، المكالمات الجماعية.
- الحدود الموثقة: التدفقات الحية مقابل Firebase تحتاج تفعيل
  Authentication/Firestore من Console (docs/FIREBASE_SETUP.md) —
  الاختبارات الحية للمنطق النقي، والتكامل السحابي سيرافق التفعيل.

### البيئة
- Flutter **3.35.1** stable • JDK 17 (Temurin) • NDK 26.1.10909125 •
  CMake 3.22.1 • build-tools 34.0.0 • ubuntu-latest.

### البناء
- `flutter build apk --release` (universal: android-arm + android-arm64) ✓
- `flutter build apk --release --split-per-abi` ✓

### الحزم المنتجة + حارس التوقيع

| الحزمة | الحجم | SHA-256 |
|--------|-------|---------|
| app-universal-release.apk | 37M | `b0b69803789216e952de0fba8f2120d39d113c51fe11ef1ed89343ac27d7ad5a` |
| app-arm64-v8a-release.apk | 25M | `31f453f7e0963d9d17b357a8f816fb0c4f1976a8070bd0147d90f7026780a527` |
| app-armeabi-v7a-release.apk | 23M | `6aacbaa21946974b305f5a7a5059601e5927ad6e147d032f3c8a0985c8666cad` |

- **aapt badging**: `package: name='com.drs.nexora' versionCode='7'
  versionName='0.1.0' compileSdkVersion='35'`
- **application-label: 'Violet Chat'** ✓
- **حارس التوقيع**: الشهادة على الحزم الثلاث =
  `ae74add09a58f8063ab45e18c1b99e9e1352acf2f46af67789d74f097e44fa6b`
  = هوية الإنتاج الحالية (نفس سلسلة مفاتيح الإصدارات السابقة →
  التثبيت فوقها كتحديث يعمل).
- التوقيع مُصدر في CI من الأسرار (لا مفتاح في المستودع).
