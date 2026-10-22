import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import '../data/models/models.dart';

/// Local notifications driven by realtime events.
///
/// HONEST SCOPE (see SECURITY.md / FINAL_AUDIT.md):
///  - works: app foreground + background (Android process alive)
///  - NOT working when the app is fully killed: requires FCM and a
///    user-supplied google-services.json -> AppConfig.enableSystemPush
///    stays false and no fake "background push" is claimed.
///
/// Privacy: encrypted message CONTENT is only shown when the user
/// enables preview AND the payload decrypted successfully; otherwise
/// the notification is generic ("رسالة جديدة").
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  UserSettings settings = const UserSettings();
  bool _inited = false;

  /// v0.1.0: invoked when the user taps a message notification.
  /// Set by the app shell — receives the chatId embedded in the
  /// notification payload. Deep-links into the chat.
  void Function(String chatId)? onMessageTap;

  Future<void> init() async {
    if (_inited) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const init = InitializationSettings(android: androidInit);
    await _plugin.initialize(
      init,
      // v0.1.0: notification tap → deep-link into the chat.
      onDidReceiveNotificationResponse: (r) {
        final chatId = r.payload;
        if (chatId != null && chatId.isNotEmpty) {
          onMessageTap?.call(chatId);
        }
      },
    );
    _inited = true;

    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    _createChannels();
  }

  Future<void> _createChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'drs_messages',
        'رسائل Violet Chat',
        description: 'إشعارات الرسائل والمحادثات الجديدة',
        importance: Importance.high,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'drs_calls',
        'مكالمات Violet Chat',
        description: 'إشعارات المكالمات الواردة',
        importance: Importance.max,
        enableVibration: true,
      ),
    );
  }

  Future<void> showMessageNotification({
    required String chatTitle,
    required String? previewText,
    required bool isGroup,
    String? chatId,
  }) async {
    if (!_inited) await init();
    final body = (settings.notificationPreview && previewText != null)
        ? previewText
        : (isGroup ? 'رسالة جديدة في المجموعة' : 'رسالة جديدة');
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
    try {
      await _plugin.show(
        chatTitle.hashCode & 0x7fffffff,
        '${AppConfig.appName} • $chatTitle',
        body,
        details,
        // chatId travels as the payload — tapping deep-links.
        payload: chatId,
      );
    } catch (e) {
      AppLogger.w('notify', 'show failed', e);
    }
  }

  Future<void> showIncomingCall({
    required String callerName,
    required bool video,
  }) async {
    if (!_inited) await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'drs_calls',
        'مكالمات Violet Chat',
        channelDescription: 'إشعارات المكالمات الواردة',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
      ),
    );
    try {
      await _plugin.show(
        callerName.hashCode & 0x7fffffff,
        AppConfig.appName,
        video
            ? 'مكالمة فيديو واردة من $callerName'
            : 'مكالمة صوتية واردة من $callerName',
        details,
      );
    } catch (e) {
      AppLogger.w('notify', 'call notif failed', e);
    }
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}
