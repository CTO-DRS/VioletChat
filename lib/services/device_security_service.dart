import 'dart:async';

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../core/logging/app_logger.dart';

/// Device-level privacy surface (v0.1.0):
///  - FLAG_SECURE (block screenshots / screen-record / recents preview)
///    via a tiny native MethodChannel on MainActivity.
///  - Biometric app lock (local_auth) with fail-safe semantics: every
///    native call is guarded — an error NEVER locks the user out and
///    NEVER crashes the app; the feature simply stays unavailable.
///
/// Both capabilities are opt-in from the privacy settings and are
/// synced through the UserSettings JSONB (no server schema change).
class DeviceSecurityService {
  DeviceSecurityService._();

  static const MethodChannel _channel =
      MethodChannel('com.drs.nexora/security');
  static final LocalAuthentication _localAuth = LocalAuthentication();

  /// Cached availability, refreshed lazily on the settings screen.
  static bool? _biometricsAvailable;

  // ------------------------------------------------------------------
  // FLAG_SECURE — screenshot blocking
  // ------------------------------------------------------------------

  /// Apply the current preference at boot and on every change.
  /// Native errors are swallowed on purpose (old WebView-less devices,
  /// platform channel racing teardown, tests): privacy is best-effort
  /// at the OS level, never a crash.
  static Future<void> applyScreenshotBlock(bool block) async {
    try {
      await _channel.invokeMethod<bool>(block ? 'setSecure' : 'clearSecure');
    } on PlatformException catch (e) {
      AppLogger.w('device_security', 'FLAG_SECURE failed', e);
    } on MissingPluginException {
      // Running in a test / unsupported embedding — ignore silently.
    } catch (e) {
      AppLogger.w('device_security', 'FLAG_SECURE channel error', e);
    }
  }

  // ------------------------------------------------------------------
  // Biometric app lock
  // ------------------------------------------------------------------

  /// True when the device has enrolled biometric hardware we can use.
  /// Result is cached so the settings screen stays snappy.
  static Future<bool> biometricsAvailable() async {
    final cached = _biometricsAvailable;
    if (cached != null) return cached;
    bool available = false;
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final enrolled = await _localAuth.isDeviceSupported();
      available = canCheck && enrolled;
    } catch (_) {
      available = false;
    }
    _biometricsAvailable = available;
    return available;
  }

  /// Prompt the OS biometric dialog. Returns true ONLY on explicit
  /// success — any error/timeout/cancel returns false (gate stays
  /// locked but the user can retry; nothing throws).
  static Future<bool> authenticate() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'افتح Violet Chat للمتابعة',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } catch (e) {
      AppLogger.w('device_security', 'biometric auth failed', e);
      return false;
    }
  }

  /// Tests only.
  static void debugResetCache() => _biometricsAvailable = null;
}
