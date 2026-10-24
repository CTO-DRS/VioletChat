import 'dart:async';
import 'dart:convert';

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
/// **Authenticated signals (fix: audit 2026-10-25)** — the old trust
/// model ("channel names are unguessable UUIDs") was false: a channel
/// name is `calls-{uid}` where uid is the PUBLIC id on `profiles`.
/// Anyone knowing a uid could join the victim's channel and forge
/// `offer` / `ring` / `group-end` signals (the `from` field is client-
/// stamped and was trusted blindly). Now every signal carries:
///   `spk` : sender device Ed25519 signing public key (b64)
///   `sig` : Ed25519 over the canonical signal bytes
/// and the receiver verifies BOTH:
///   1. `spk` is one of the signing keys published by the claimed
///      sender's devices (`devices` table — public to authenticated
///      clients), so an attacker cannot substitute a fresh keypair;
///   2. the signature is valid, so the sender owns that device key.
/// Unauthenticated/undecryptable signals are logged and DROPPED.
/// Backward compatibility: peers on older builds send unsigned
/// signals — they are dropped; both sides need the updated build for
/// calls (same coupling as any protocol change in v0.1.x).
///
/// Privacy note: payloads carry call coordination metadata only
/// (ids, call id, SDP, ICE) — never message content.
class CallTransport {
  final SupabaseClient client;
  CallTransport(this.client);

  // ----------------------------------------------------------------
  // Authentication hooks (wired by AppServices) — REQUIRED for the
  // receive path. When unset, every incoming signal is rejected:
  // secure-by-default beats silent spoofability.
  // ----------------------------------------------------------------

  /// Signs the canonical signal bytes with THIS device's Ed25519 key.
  Future<String> Function(List<int> message)? signer;
  Future<String> Function()? signingKeyProvider;

  /// Returns the signing public keys published by [userId]'s devices
  /// (server truth), or null when lookup failed. Implementations
  /// should cache — the transport also caches per session.
  Future<List<String>?> Function(String userId)? peerSigningKeys;

  /// Verified per-peer signing keys cache (uid -> allowed spk set).
  final Map<String, Set<String>> _peerKeysCache = {};
  final Map<String, DateTime> _lastKeyRefresh = {};

  static const Set<String> _reservedKeys = {'to', 'from', 'scope', 'event'};
  static const Set<String> _authKeys = {'spk', 'sig'};

  /// Canonical byte string that both sides sign/verify: the four base
  /// fields first, then the remaining payload keys in wire order,
  /// EXCLUDING the two auth fields themselves.
  static String canonical(Map<String, dynamic> p) => jsonEncode({
        'to': p['to'],
        'from': p['from'],
        'scope': p['scope'],
        'event': p['event'],
        for (final e in p.entries)
          if (!_reservedKeys.contains(e.key) && !_authKeys.contains(e.key))
            e.key: e.value,
      });

  RealtimeChannel? _rx;
  bool _starting = false;

  /// Cached per-peer send channels (peer id -> channel on
  /// 'calls-{peerId}'); reused for the whole session, dropped on stop.
  final Map<String, RealtimeChannel> _tx = {};

  /// Set by the owner (AppServices) — dispatches a signal that passed
  /// the `to == myId` filter AND the signature check to the 1:1 and
  /// group call services.
  void Function(Map<String, dynamic> msg)? onSignal;

  String get myId => client.auth.currentUser?.id ?? '';

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
              // FIX (audit 2026-10-25): verify BEFORE dispatch — the
              // old code passed any payload straight to the services.
              unawaited(_verifyAndDispatch(p));
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

  Future<void> _verifyAndDispatch(Map<String, dynamic> p) async {
    final from = p['from'] as String?;
    final sig = p['sig'] as String?;
    final spk = p['spk'] as String?;
    if (from == null || from.isEmpty || sig == null || spk == null) {
      AppLogger.w('callsig',
          'dropped unauthenticated signal (missing spk/sig/from)');
      return;
    }
    if (from == myId) return; // self-echo — ignore

    // 1) The claimed signing key must be published by the claimed user.
    var allowed = _peerKeysCache[from];
    if (allowed == null) {
      final keys = peerSigningKeys != null ? await peerSigningKeys!(from) : null;
      if (keys == null || keys.isEmpty) {
        AppLogger.w('callsig', 'no published signing keys for peer '
            '${from.substring(0, from.length.clamp(0, 8))} — dropped');
        return;
      }
      allowed = keys.toSet();
      _peerKeysCache[from] = allowed;
    }
    if (!allowed.contains(spk)) {
      // One bounded refresh — the peer may have re-registered a device
      // (reinstall). Throttled to once per 5 s per peer so a spammer
      // cannot turn this into a DB query amplifier.
      final last = _lastKeyRefresh[from];
      if (last == null ||
          DateTime.now().difference(last) > const Duration(seconds: 5)) {
        _lastKeyRefresh[from] = DateTime.now();
        final keys2 =
            peerSigningKeys != null ? await peerSigningKeys!(from) : null;
        if (keys2 != null && keys2.contains(spk)) {
          allowed = keys2.toSet();
          _peerKeysCache[from] = allowed;
        }
      }
    }
    if (!allowed.contains(spk)) {
      AppLogger.w('callsig', 'signing key not published by sender — dropped');
      return;
    }

    // 2) The signature must verify over the canonical bytes.
    try {
      final ok = await _verifySig(spk, canonical(p), sig);
      if (!ok) {
        AppLogger.w('callsig', 'bad signal signature — dropped');
        return;
      }
    } catch (e) {
      AppLogger.w('callsig', 'signature verification error — dropped', e);
      return;
    }

    onSignal?.call(p);
  }

  Future<bool> _verifySig(
      String spkB64, String canonicalStr, String sigB64) async {
    // Delegate to the injected verifier when provided (keeps crypto
    // deps out of the transport for tests).
    return verifier != null
        ? await verifier!(spkB64, utf8.encode(canonicalStr), sigB64)
        : false;
  }

  /// Ed25519 verification hook: (signingPubB64, message, sigB64) -> ok.
  /// Required for the receive path; without it every signal is dropped
  /// (secure-by-default).
  Future<bool> Function(String signingPubB64, List<int> message,
      String signatureB64)? verifier;

  /// Send one signal to [toPeerId]'s personal channel. Send channels
  /// are cached per peer and reused for the whole call. Every signal
  /// is stamped with `from` (my user id) and AUTHENTICATED with this
  /// device's Ed25519 signing key (`spk` + `sig`).
  Future<void> send(
    String toPeerId,
    String scope,
    String event,
    Map<String, dynamic> payload,
  ) async {
    try {
      if (myId.isEmpty) return; // signed out — nothing to send
      final base = <String, dynamic>{
        'to': toPeerId,
        'from': myId,
        'scope': scope,
        'event': event,
        ...payload,
      };
      final ch = _txChannel(toPeerId);
      Map<String, dynamic> wire = base;
      if (signer != null && signingKeyProvider != null) {
        try {
          final spk = await signingKeyProvider!();
          final sig = await signer!(utf8.encode(canonical(base)));
          wire = {...base, 'spk': spk, 'sig': sig};
        } catch (e) {
          // Signing failed: sending unsigned would be dropped by the
          // peer anyway — surface the failure locally and skip.
          AppLogger.w('callsig', 'signal signing failed — not sent', e);
          return;
        }
      }
      await ch.sendBroadcastMessage(event: 'signal', payload: wire);
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

  /// Forget a peer's cached signing keys (e.g. peer re-registered a
  /// device and its key set changed).
  void invalidatePeerKeys(String userId) => _peerKeysCache.remove(userId);

  Future<void> stop() async {
    for (final peerId in List<String>.of(_tx.keys)) {
      await dropPeer(peerId);
    }
    _peerKeysCache.clear();
    final rx = _rx;
    _rx = null;
    if (rx != null) {
      try {
        await client.removeChannel(rx);
      } catch (_) {}
    }
  }
}
