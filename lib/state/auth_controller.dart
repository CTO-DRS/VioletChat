import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import '../data/models/models.dart';
import 'app_services.dart';

/// Authentication + post-login bootstrap + security status.
class AuthController extends ChangeNotifier {
  final AppServices services;
  AuthController(this.services);

  bool booting = false;
  String? bootError;
  Profile? me;
  bool identityRepaired = false;

  bool get signedIn => services.auth.isSignedIn;

  /// Run after a session exists: keys, profile, services.
  Future<void> bootstrap() async {
    if (booting || !signedIn) return;
    booting = true;
    bootError = null;
    notifyListeners();
    try {
      await services.onSignedIn();
      me = await services.profiles.getMyProfile();
      identityRepaired = false;
      AppLogger.i('auth', 'bootstrap complete');
    } catch (e) {
      bootError = 'تعذر تجهيز الحساب — تحقق من الاتصال وأعد المحاولة';
      AppLogger.e('auth', 'bootstrap failed', e);
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  Future<void> signUp(String email, String password, String username) async {
    await services.auth.signUp(email, password, username);
  }

  Future<void> signIn(String email, String password) async {
    await services.auth.signIn(email, password);
  }

  Future<void> signOut() async {
    await services.onSignedOut();
    await services.auth.signOut();
    me = null;
    notifyListeners();
  }

  /// Security status for the Security screen.
  Future<SecurityStatus> securityStatus() async {
    final ok =
        await services.keys.verifyLocalIdentityMatchesServer(services.identity);
    return SecurityStatus(
      deviceId: services.identity.deviceId,
      identityMatch: ok,
      protocol: AppConfig.protocolName,
      deviceCount: (await services.profiles.listDevices()).length,
    );
  }

  Future<void> refreshProfile() async {
    me = await services.profiles.getMyProfile();
    notifyListeners();
  }
}

class SecurityStatus {
  final String deviceId;
  final bool identityMatch;
  final String protocol;
  final int deviceCount;

  const SecurityStatus({
    required this.deviceId,
    required this.identityMatch,
    required this.protocol,
    required this.deviceCount,
  });
}
