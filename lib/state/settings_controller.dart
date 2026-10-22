import 'package:flutter/material.dart';

import '../data/models/models.dart';
import '../services/device_security_service.dart';
import 'app_services.dart';

/// User settings + theme mode.
class SettingsController extends ChangeNotifier {
  final AppServices services;
  SettingsController(this.services);

  UserSettings settings = const UserSettings();
  ThemeMode themeMode = ThemeMode.dark;

  Future<void> load() async {
    settings = await services.profiles.getSettings();
    _applyThemeMode();
    services.notifications.settings = settings;
    _syncPresence();
    await _applyDevicePrivacy();
    notifyListeners();
  }

  Future<void> update(UserSettings next) async {
    settings = next;
    _applyThemeMode();
    services.notifications.settings = next;
    _syncPresence();
    await _applyDevicePrivacy();
    notifyListeners();
    try {
      await services.profiles.saveSettings(next);
    } catch (_) {
      // keep local value; will retry on next load
    }
  }

  /// v0.1.0: resolved three-way theme (dark / light / system) from
  /// settings.theme_mode; legacy dark_mode boolean is the fallback
  /// for rows written before v0.1.0.
  void _applyThemeMode() {
    switch (settings.resolvedThemeMode) {
      case 'light':
        themeMode = ThemeMode.light;
        break;
      case 'system':
        themeMode = ThemeMode.system;
        break;
      default:
        themeMode = ThemeMode.dark;
    }
  }

  /// OS-level privacy surfaces (v0.1.0) ride on the same settings
  /// object: FLAG_SECURE follows `blockScreenshots`. The app-lock
  /// gate reads `settings.appLock` on every lifecycle change — nothing
  /// to apply here, so it is intentionally not touched in this method.
  Future<void> _applyDevicePrivacy() async {
    await DeviceSecurityService.applyScreenshotBlock(settings.blockScreenshots);
  }

  /// Heartbeat follows the privacy toggle: with showPresence off the
  /// server would drop every beat anyway — we simply stop sending.
  void _syncPresence() {
    if (settings.showPresence) {
      services.presence.start();
    } else {
      services.presence.stop();
    }
  }
}
