import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_bootstrap.dart';
import 'core/config/app_config.dart';
import 'core/logging/app_logger.dart';
import 'services/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Register the FCM background entry point FIRST (must be top-level,
  // before runApp). Safe even when google-services.json is absent.
  if (AppConfig.enableSystemPush) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  // Global safety nets — a crash must NEVER become a silent black
  // screen: it is logged (metadata only, per SECURITY.md) and the
  // bootstrap error screen surfaces a readable message to the user.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLogger.e('flutter', details.exceptionAsString(), details.exception,
        details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.e('platform', error.toString(), error, stack);
    return true;
  };

  // Render the branded screen IMMEDIATELY, then run every startup
  // step (backend init, local DB, crypto identity) with visible
  // progress and a readable, recoverable error screen on failure.
  runApp(const VioletBootstrap());
}
