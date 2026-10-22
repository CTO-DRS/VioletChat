import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';

/// Presence — heartbeat while signed in + online queries for peers.
///
/// Privacy model (enforced server-side, not here):
///   * visibility requires a shared chat AND my show_presence setting;
///   * "online" = a fresh heartbeat (server window, see schema).
/// This service only (a) beats on a timer and (b) asks the server who
/// is online. When the app is backgrounded Dart timers pause, which is
/// exactly the desired semantic: an inactive user stops appearing
/// online within one window.
class PresenceService {
  final SupabaseClient client;
  Timer? _beatTimer;
  bool _running = false;

  PresenceService(this.client);

  /// Start (or restart) the heartbeat loop. Safe to call repeatedly.
  void start() {
    stop();
    _running = true;
    unawaited(beat());
    _beatTimer = Timer.periodic(
      const Duration(seconds: AppConfig.presenceHeartbeatSecs),
      (_) => unawaited(beat()),
    );
  }

  void stop() {
    _running = false;
    _beatTimer?.cancel();
    _beatTimer = null;
  }

  bool get running => _running;

  /// One heartbeat. Failures are swallowed: presence is non-critical,
  /// the next tick retries, and offline the RPC call simply fails.
  Future<void> beat() async {
    if (client.auth.currentUser == null) return;
    try {
      await client.rpc('presence_heartbeat');
    } catch (_) {
      // offline / transient — retried on the next tick
    }
  }

  /// Which of [userIds] are currently online (fresh heartbeats only,
  /// and only users the server decides we may see). Returns an empty
  /// set on any error — the caller must treat absence as "unknown",
  /// never as a promise of visibility.
  Future<Set<String>> onlineUsers(List<String> userIds) async {
    if (userIds.isEmpty) return {};
    try {
      final res = await client
          .rpc('get_presence', params: {'p_user_ids': userIds}) as List;
      return res
          .map((e) => (e as Map<String, dynamic>)['user_id'] as String)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// v0.1.0: last-seen timestamps (30-day window, privacy honoured
  /// server-side exactly like [onlineUsers]). Absent users are either
  /// offline >30 days, hidden by their settings, or share no chat.
  Future<Map<String, DateTime>> lastSeenUsers(List<String> userIds) async {
    if (userIds.isEmpty) return {};
    try {
      final res = await client
          .rpc('get_last_seen', params: {'p_user_ids': userIds}) as List;
      final out = <String, DateTime>{};
      for (final e in res) {
        final m = e as Map<String, dynamic>;
        final uid = m['user_id'] as String?;
        final ts = DateTime.tryParse('${m['last_seen_at']}');
        if (uid != null && ts != null) out[uid] = ts;
      }
      return out;
    } catch (_) {
      return {};
    }
  }
}
