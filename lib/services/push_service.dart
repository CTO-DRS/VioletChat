import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';

/// FCM data payload keys — MINIMAL metadata only.
///
/// SECURITY: encrypted message content NEVER travels through FCM.
/// Payload carries routing metadata (chat id + whether it is a group);
/// everything else is fetched and decrypted locally after the tap.
class PushService {
  PushService._();

  static bool _initialized = false;
  static StreamSubscription<String>? _tokenRefreshSub;
  static StreamSubscription<RemoteMessage>? _backgroundTapSub;

  /// v0.1.0: invoked when the user opens the app from an FCM
  /// notification (background tap or cold start). Set by the app
  /// shell; receives the chat_id from the data payload.
  static void Function(String chatId)? onOpenChat;

  /// Whether FCM is usable on this build (google-services.json present).
  static bool get enabled => AppConfig.enableSystemPush;

  /// Initialise Firebase (Android: values injected by the
  /// google-services plugin). Never throws — on failure system push is
  /// simply unavailable and in-app notifications keep working.
  static Future<bool> ensureInitialized() async {
    if (!enabled) return false;
    if (_initialized) return true;
    try {
      await Firebase.initializeApp();
      _initialized = true;
      return true;
    } catch (e) {
      AppLogger.w('push', 'Firebase init unavailable');
      return false;
    }
  }

  /// Register the device token for the signed-in user.
  static Future<void> register(String userId, dynamic client) async {
    if (!await ensureInitialized()) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(provisional: true);

      // Show notifications while running when a token/data message
      // arrives in the foreground? NO — realtime already surfaces
      // in-app notifications; FCM data messages are consumed silently
      // in the foreground and only used to notify while killed/background.

      final token = await messaging.getToken();
      if (token != null) {
        await _upsertToken(client, token, userId);
      }

      _tokenRefreshSub ??= messaging.onTokenRefresh
          .listen((t) => _upsertToken(client, t, userId));

      // Message received while the app is OPEN: ignore (realtime covers
      // it; duplicates would be double notifications).
      FirebaseMessaging.onMessage.listen((m) async {});

      // v0.1.0: app opened from a background/killed notification tap
      // → deep-link into the chat carried by the data payload.
      _backgroundTapSub ??=
          FirebaseMessaging.onMessageOpenedApp.listen((m) async {
        final chatId = m.data['chat_id'] as String?;
        if (chatId != null && chatId.isNotEmpty) {
          onOpenChat?.call(chatId);
        }
      });

      // Cold start from a terminated-state notification tap.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      final initialChatId = initial?.data['chat_id'] as String?;
      if (initialChatId != null && initialChatId.isNotEmpty) {
        // Delayed slightly: the navigator/controller graph may not be
        // ready in the same tick; openChatById fails soft when the
        // chats are not loaded yet.
        Future.delayed(const Duration(seconds: 2),
            () => onOpenChat?.call(initialChatId));
      }
    } catch (e) {
      AppLogger.w('push', 'token registration failed (continuing)');
    }
  }

  /// Remove this device's token row on sign-out (fail-soft).
  static Future<void> deregister(String? token, dynamic client) async {
    if (!enabled || !_initialized) return;
    try {
      final t = token ?? await FirebaseMessaging.instance.getToken();
      if (t != null && client != null) {
        await client.from('push_tokens').delete().eq('token', t);
      }
      _tokenRefreshSub?.cancel();
      _tokenRefreshSub = null;
    } catch (e) {
      AppLogger.w('push', 'token deregistration failed (continuing)');
    }
  }

  static Future<void> _upsertToken(
      dynamic client, String token, String userId) async {
    try {
      await client.from('push_tokens').upsert({
        'token': token,
        'user_id': userId,
        'platform': 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      // Table may not exist yet server-side (owner applies schema) —
      // honest fail-soft: in-app notifications still work.
      AppLogger.w('push', 'token upsert failed (continuing)');
    }
  }
}

/// Background / terminated message entry point (data-only messages).
///
/// Must stay a TOP-LEVEL function: runs in a separate isolate with NO
/// access to the services graph. Shows a PRIVACY-SAFE local
/// notification: generic text only — no content is in the payload by
/// design, and no settings/session are read here.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase may not be initialized in this isolate yet.
  try {
    await Firebase.initializeApp();
  } catch (_) {
    return;
  }

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher')));

  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'drs_messages',
      'رسائل Violet Chat',
      channelDescription: 'إشعارات الرسائل والمحادثات الجديدة',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
    ),
  );

  final isGroup = message.data['is_group'] == 'true';
  await plugin.show(
    message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
    'Violet Chat',
    isGroup ? 'رسالة جديدة في المجموعة' : 'رسالة جديدة',
    details,
  );
}
