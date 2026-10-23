/// ============================================================
/// Violet Chat — Central application configuration
/// ============================================================
/// APP_NAME is THE single source of truth for the app name.
/// Every user-visible string, the Android manifest (via Dart at
/// runtime and via CI placeholder), splash, about, settings,
/// notifications and documentation read from here.
///
/// NOTE: supabaseUrl + supabasePublishableKey are PUBLIC by design
/// (the publishable key is the modern replacement of the anon key).
/// No private/service_role secret may ever be placed in this file.
class AppConfig {
  AppConfig._();

  // ------------------------------------------------------------------
  // Identity — single source of truth for the product name (Violet Chat)
  // ------------------------------------------------------------------
  static const String appName = 'Violet Chat';
  static const String appNameAr = 'فايلويت شات';
  static const String appTagline = 'مراسلة مشفرة طرف-لطرف • خاصة بك 100%';
  // v0.1.2: هوية الحزمة صارت com.drs.violetchat لمطابقة تسجيل Firebase
  // الرسمي (مشروع violetchat-cea68 — المالك سجّل التطبيق بهذه الحزمة
  // وببصمة SHA-1 للإنتاج). ملاحظة: هذا يجعل التثبيت منتجاً منفصلاً عن
  // حزم com.drs.nexora القديمة (قرار موثق في CHANGELOG v0.1.2)،
  // بينما namespace Kotlin الداخلية بقيت com.drs.nexora بلا تغيير.
  static const String appId = 'com.drs.violetchat';
  // v0.1.2: تُعرض في الإعدادات («الإصدار …») — كانت عالقة على 0.1.0
  // في v0.1.1 (عيب عرض حقيقي مُصلَح الآن). تُرقّع مع pubspec.yaml.
  static const String appVersion = '0.1.10';

  // ------------------------------------------------------------------
  // Backend (public values — safe for client bundles)
  // ------------------------------------------------------------------
  static const String supabaseUrl = 'https://hnfdfzuyrphjcmgezoyh.supabase.co';
  static const String supabasePublishableKey =
      'sb_publishable_RB-Si7nJmcHUsx1n-Z4BXA_0A1WmNDx';

  // ------------------------------------------------------------------
  // Verification site (GitHub Pages, public repo CTO-DRS/nexora-verify).
  // Landing pages for auth emails: confirm signup + reset password.
  // Source of truth lives in /verification-site of this repo and is
  // deployed via scripts/deploy-verify-site.sh. These URLs MUST stay
  // whitelisted in Supabase Auth → URL Configuration → Redirect URLs
  // (full procedure: docs/EMAIL_SETUP.md).
  // ------------------------------------------------------------------
  static const String verifySiteBase =
      'https://cto-drs.github.io/nexora-verify';
  static const String emailConfirmRedirectUrl = '$verifySiteBase/confirm.html';
  static const String emailResetRedirectUrl = '$verifySiteBase/reset.html';

  // ------------------------------------------------------------------
  // Feature flags — features that are NOT fully implemented are
  // hidden behind these flags instead of showing fake UI.
  // ------------------------------------------------------------------
  static const bool enableCalls = true; // 1-to-1 WebRTC calls implemented

  // Group calls (v0.1.0): real WebRTC mesh over a per-chat broadcast
  // channel — incumbent peers each offer to a joining peer, trickle
  // ICE, independent leave. Honest boundary: group calls write NO
  // calls-table history rows (the schema assumes exactly two
  // participants) — live calling only, documented in FINAL_AUDIT.
  static const bool enableGroupCalls = true;
  // Max mesh peers we accept in one group call. Above this the call
  // button shows an honest snackbar instead of pretending mesh scales.
  static const int groupCallMaxPeers = 8;
  // System push (FCM): client integration complete — google-services.json
  // lives in android/app/ (public client config, no secrets). Data-only
  // payloads carry NO message content (privacy, see SECURITY.md).
  // Server-side dispatch requires the owner's Firebase service account
  // (documented in BUILD.md) — until deployed, killed-app push is not
  // delivered end-to-end.
  static const bool enableSystemPush = true;

  // ------------------------------------------------------------------
  // Violet identity layer (v0.1.0) — Firebase Auth + Cloud Firestore.
  // v0.1.2: المشروع الرسمي violetchat-cea68 (رقم 882476047601) عبر
  // google-services.json الجديدة — عميل OAuth بنبض SHA-1 للإنتاج +
  // عميل ويب يولّد default_web_client_id تلقائياً. التوفر يُكتشف وقت
  // التشغيل: عند غياب التهيئة/التسجيل في Console
  // يسقط التطبيق بأمان إلى تدفق المصادقة القائم (Supabase).
  // خطوات التفعيل اليدوية: docs/FIREBASE_SETUP.md، القواعد: firestore.rules.
  // ------------------------------------------------------------------
  static const bool enableVioletIdentity = true;

  // ------------------------------------------------------------------
  // Crypto protocol parameters
  // ------------------------------------------------------------------
  static const int prekeyBatchSize = 50;
  static const int maxSkippedMessageKeys = 100;
  static const int mediaMaxBytes = 50 * 1024 * 1024; // 50 MB
  // معرف بروتوكول التشفير يُبقى عمداً باسمه الأصلي: سلسلة توافق على
  // السلك بين الإصدارات والأجهزة، لا علامة تجارية — تغييره قد يكسر
  // التحقق بين أجهزة قديمة/جديدة إن استُعمل مطابقة صارمة.
  static const String protocolName = 'drs-nexora-e2ee-v1';

  // ------------------------------------------------------------------
  // Messaging
  // ------------------------------------------------------------------
  static const int pageSize = 30;
  static const int typingIndicatorTimeoutMs = 4000;

  // ------------------------------------------------------------------
  // Presence (متصل الآن)
  // Heartbeat cadence vs. server-side online window: the client beats
  // every 45s while signed in; the server treats a user as online for
  // 70s after the last beat. Visibility is enforced SERVER-SIDE
  // (shared chat + show_presence toggle) — the client cannot leak it.
  // ------------------------------------------------------------------
  static const int presenceHeartbeatSecs = 45;
  static const int presenceRefreshSecs = 60;

  // ------------------------------------------------------------------
  // ICE servers for WebRTC calls.
  // STUN is public by nature. TURN (needed behind restrictive NATs) is
  // injected at BUILD TIME — no credentials are ever stored in Git:
  //   flutter build apk --release \
  //     --dart-define=TURN_URL=turn:turn.example.com:3478 \
  //     --dart-define=TURN_USERNAME=myuser \
  //     --dart-define=TURN_CREDENTIAL=mysecret
  // When TURN_URL is omitted the app still builds and calls work on
  // permissive networks (STUN only).
  // ------------------------------------------------------------------
  static const String _stunUrl = 'stun:stun.l.google.com:19302';
  static const String _turnUrl = String.fromEnvironment('TURN_URL');
  static const String _turnUsername = String.fromEnvironment('TURN_USERNAME');
  static const String _turnCredential =
      String.fromEnvironment('TURN_CREDENTIAL');

  static bool get turnConfigured => _turnUrl.isNotEmpty;

  /// Server list handed to the WebRTC peer connection.
  static List<Map<String, dynamic>> get iceServers => [
        {'urls': _stunUrl},
        if (_turnUrl.isNotEmpty)
          {
            'urls': _turnUrl,
            if (_turnUsername.isNotEmpty) 'username': _turnUsername,
            if (_turnCredential.isNotEmpty) 'credential': _turnCredential,
          },
      ];
}
