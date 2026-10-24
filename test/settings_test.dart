import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/core/config/app_config.dart';
import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/state/chat_controller.dart';

void main() {
  group('UserSettings — presence + receipts persistence', () {
    test('defaults: showPresence and readReceipts are ON', () {
      const s = UserSettings();
      expect(s.showPresence, isTrue);
      expect(s.readReceipts, isTrue);
    });

    test('JSON roundtrip preserves the new flags', () {
      const s = UserSettings(
        darkMode: false,
        readReceipts: false,
        showPresence: false,
      );
      final back = UserSettings.fromJson(s.toJson());
      expect(back.showPresence, isFalse);
      expect(back.readReceipts, isFalse);
      expect(back.darkMode, isFalse);
    });

    test('back-compat: settings saved before v0.1.0 lack show_presence', () {
      // Settings JSON written by a v0.1.0 client must not crash and must
      // default presence visibility to ON (same server-side default).
      final legacy = <String, dynamic>{
        'dark_mode': true,
        'notification_preview': false,
        'notification_sound': true,
        'notification_vibration': true,
        'read_receipts': true,
      };
      final s = UserSettings.fromJson(legacy);
      expect(s.showPresence, isTrue);
    });
  });

  group('UserSettings — v0.1.0 device privacy flags', () {
    test('defaults: appLock and blockScreenshots are OFF (opt-in)', () {
      const s = UserSettings();
      expect(s.appLock, isFalse);
      expect(s.blockScreenshots, isFalse);
    });

    test('JSON roundtrip preserves app_lock and block_screenshots', () {
      const s = UserSettings(appLock: true, blockScreenshots: true);
      final back = UserSettings.fromJson(s.toJson());
      expect(back.appLock, isTrue);
      expect(back.blockScreenshots, isTrue);
      // The other flags survive untouched too.
      expect(back.readReceipts, isTrue);
      expect(back.showPresence, isTrue);
    });

    test('back-compat: settings JSON from v0.1.0 lacks the new keys', () {
      // A JSONB blob written by a v0.1.0 client must not crash and must
      // default both device-privacy flags to OFF (never lock a user
      // out of a device that never opted in).
      final legacy = <String, dynamic>{
        'dark_mode': false,
        'read_receipts': false,
      };
      final s = UserSettings.fromJson(legacy);
      expect(s.appLock, isFalse);
      expect(s.blockScreenshots, isFalse);
      expect(s.darkMode, isFalse);
    });
  });

  group('UserSettings — v0.1.0 app-lock schedule', () {
    test('default grace is 0 (lock immediately — v0.1.0 behaviour)', () {
      const s = UserSettings(appLock: true);
      expect(s.appLockGraceSecs, 0);
    });

    test('JSON roundtrip preserves the grace window', () {
      const s = UserSettings(appLock: true, appLockGraceSecs: 60);
      final back = UserSettings.fromJson(s.toJson());
      expect(back.appLockGraceSecs, 60);
      const s5 = UserSettings(appLockGraceSecs: 300);
      expect(UserSettings.fromJson(s5.toJson()).appLockGraceSecs, 300);
    });

    test('back-compat: v0.1.0 settings lack the key → grace 0', () {
      final legacy = <String, dynamic>{'app_lock': true};
      expect(UserSettings.fromJson(legacy).appLockGraceSecs, 0);
    });

    test('defensive: unsupported values fall back to 0 (strictest)', () {
      for (final bad in ['nope', null, 15, 999, -60, 1.5]) {
        final s = UserSettings.fromJson({'app_lock_grace_secs': bad});
        expect(s.appLockGraceSecs, 0, reason: 'value: $bad');
      }
    });
  });

  group('ChatController.mergeWindow — v0.1.0 pagination fix', () {
    Message msg(String id, DateTime at) => Message(
          id: id,
          chatId: 'chat1',
          senderId: 'u1',
          senderDeviceId: 'd1',
          clientMsgId: 'c-$id',
          kind: 'text',
          text: 'hi $id',
          createdAt: at.toUtc().toIso8601String(),
          serverAt: at.toUtc().toIso8601String(),
        );

    test('window not larger than latest page -> latest page wins', () {
      final now = DateTime.now();
      final loaded = List.generate(
          10, (i) => msg('m$i', now.subtract(Duration(minutes: i))));
      final latest = loaded.take(10).toList();
      expect(ChatController.mergeWindow(loaded, latest), same(latest));
    });

    test('loaded history stays in front of the latest page (ascending)', () {
      final now = DateTime.now();
      // Latest page: 30 newest (ascending); loaded window additionally
      // holds 10 older messages the user scrolled through.
      final latest = List.generate(
          30, (i) => msg('n$i', now.subtract(Duration(minutes: i))));
      final older = List.generate(
          10, (i) => msg('o$i', now.subtract(Duration(minutes: 100 + i))));
      final merged = ChatController.mergeWindow([...latest, ...older], latest);
      expect(merged, hasLength(40));
      // Ascending display convention: older history first (top),
      // then the refreshed latest page (bottom = newest).
      expect(merged.take(10).map((m) => m.id), older.map((m) => m.id));
      expect(merged.skip(10).map((m) => m.id), latest.map((m) => m.id));
    });

    test('overlap ids dedupe — no duplicated rows after refresh', () {
      final now = DateTime.now();
      final latest = List.generate(
          5, (i) => msg('n$i', now.subtract(Duration(minutes: i))));
      final loaded = [
        msg('n0', now),
        msg('old1', now.subtract(const Duration(hours: 1))),
        msg('n2', now.subtract(const Duration(minutes: 2))),
      ];
      final merged = ChatController.mergeWindow(loaded, latest);
      final ids = merged.map((m) => m.id).toList();
      expect(ids, hasLength(6));
      expect(ids.where((id) => id == 'n0'), hasLength(1));
      expect(ids.where((id) => id == 'n2'), hasLength(1));
      expect(ids.contains('old1'), isTrue);
    });
  });

  group('AppConfig — ICE servers', () {
    test('without dart-defines: STUN only, TURN not configured', () {
      // `flutter test` runs with no --dart-define values, so this pins
      // the default path that ships when TURN is not provisioned.
      expect(AppConfig.turnConfigured, isFalse);
      expect(AppConfig.iceServers, hasLength(1));
      expect(
        (AppConfig.iceServers.single['urls'] as String).startsWith('stun:'),
        isTrue,
      );
    });
  });
}
