import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/logging/app_logger.dart';

/// Personal always-on call-signaling transport (v0.1.0).
///
/// **Why this exists — a real bug it fixes**: before v0.1.0 the 1:1
/// callee never subscribed to any call channel (the only entry point,
/// `prepareIncoming`, had zero callers), so an incoming call could
/// never ring — the caller always timed out after 45 s. Field
/// verification was impossible in the build environment and the gap
/// slipped through as "NOT VERIFIED ميدانياً".
///
/// **Design**: each signed-in user keeps ONE broadcast channel open,
/// `calls-{myUserId}`, for the whole session. Every signal is sent to
/// the RECIPIENT's personal channel and carries `to` (recipient id),
/// `scope` ('p2p' | 'group'), `event` and the payload. A client
/// ignores anything on its own channel that is not addressed to it.
///
/// This works for 1:1 and for group mesh alike: mesh signaling is
/// always pairwise (offer/answer/ICE to one specific peer), so
/// targeting each peer's personal channel is sufficient — no group
/// broadcast channel is needed.
///
/// Privacy note: payloads carry call coordination metadata only
/// (ids, call id, SDP, ICE) — never message content. Channel names
/// are unguessable UUIDs, matching the pre-existing trust model of
/// the v0.1.0 pairwise call channels.
class CallTransport {
  final SupabaseClient client;
  CallTransport(this.client);

  RealtimeChannel? _rx;
  bool _starting = false;

  /// Cached per-peer send channels (peer id -> channel on
  /// 'calls-{peerId}'); reused for the whole session, dropped on stop.
  final Map<String, RealtimeChannel> _tx = {};

  /// Set by the owner (AppServices) — dispatches a signal that passed
  /// the `to == myId` filter to the 1:1 and group call services.
  void Function(Map<String, dynamic> msg)? onSignal;

  String get myId => client.auth.currentUser!.id;

  bool get isUp => _rx != null;

  /// Idempotent. Opens my personal channel and starts dispatching.
  Future<void> start() async {
    if (_rx != null || _starting) return;
    _starting = true;
    try {
      final ch = client.channel('calls-$myId');
      ch.onBroadcast(
          event: 'signal',
          callback: (payload) {
            try {
              final p = Map<String, dynamic>.from(payload as Map);
              if (p['to'] != myId) return; // not for me — ignore
              onSignal?.call(p);
            } catch (e) {
              AppLogger.w('callsig', 'bad signal payload', e);
            }
          });
      ch.subscribe();
      // Give the realtime socket a beat to attach before callers are
      // expected to reach us (best-effort — late attach is recovered
      // by re-sends/retries at the protocol level, ICE trickle).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      _rx = ch;
      AppLogger.i('callsig', 'personal call channel up');
    } catch (e, st) {
      AppLogger.e('callsig', 'start failed', e, st);
    } finally {
      _starting = false;
    }
  }

  /// Send one signal to [toPeerId]'s personal channel. Send channels
  /// are cached per peer and reused for the whole call. Every signal
  /// is stamped with `from` (my user id) — receivers rely on it to
  /// know who the peer is.
  Future<void> send(
    String toPeerId,
    String scope,
    String event,
    Map<String, dynamic> payload,
  ) async {
    try {
      final ch = _txChannel(toPeerId);
      await ch.sendBroadcastMessage(event: 'signal', payload: {
        'to': toPeerId,
        'from': myId,
        'scope': scope,
        'event': event,
        ...payload,
      });
    } catch (e) {
      AppLogger.w(
          'callsig', 'send $event to ${toPeerId.substring(0, 8)} failed', e);
    }
  }

  RealtimeChannel _txChannel(String peerId) {
    final existing = _tx[peerId];
    if (existing != null) return existing;
    final ch = client.channel('calls-$peerId');
    ch.subscribe();
    _tx[peerId] = ch;
    // A send channel needs a moment to attach before the first
    // broadcast is guaranteed to reach the peer's socket.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400)));
    return ch;
  }

  /// Drop the cached send channel for a peer (call ended).
  Future<void> dropPeer(String peerId) async {
    final ch = _tx.remove(peerId);
    if (ch != null) {
      try {
        await client.removeChannel(ch);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    for (final peerId in List<String>.of(_tx.keys)) {
      await dropPeer(peerId);
    }
    final rx = _rx;
    _rx = null;
    if (rx != null) {
      try {
        await client.removeChannel(rx);
      } catch (_) {}
    }
  }
}
