import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'call_transport.dart';
import 'notification_service.dart';

/// Real WebRTC 1-to-1 calls (audio + video).
///
/// Signaling (v0.1.0) rides the personal always-on [CallTransport] —
/// each user listens on `calls-{uid}` for signals addressed to them.
/// Before v0.1.0 the callee never opened any call channel, so
/// incoming calls could not ring at all (fixed here).
///
/// Flow:
///   caller: createPc -> getUserMedia -> offer -> ...
///   callee: offer -> (ring UI) -> accept -> getUserMedia -> answer
///   both  : trickle ICE, hangup = 'bye', occupied callee = 'busy'
///
/// Genuinely implemented: offer/answer, ICE, mute, speaker, camera
/// switch, ICE-restart recovery, hangup, ring timeout, busy.
/// Group calls live in [GroupCallService] (mesh, v0.1.0).
class CallService {
  final NotificationService notifications;
  final SupabaseClient client;
  final CallTransport transport;

  webrtc.RTCPeerConnection? _pc;
  webrtc.MediaStream? _localStream;
  Map<String, dynamic>? _pendingOffer;

  String? activeCallId;
  String? activePeerId;
  bool isVideo = false;
  bool muted = false;
  bool speakerOn = true;

  final _stateCtrl = StreamController<CallUiState>.broadcast();
  final _remoteCtrl = StreamController<webrtc.MediaStream>.broadcast();
  Stream<CallUiState> get state => _stateCtrl.stream;
  Stream<webrtc.MediaStream> get remoteStream => _remoteCtrl.stream;
  webrtc.MediaStream? get localStream => _localStream;
  CallUiState get current => _current;
  CallUiState _current = CallUiState.idle;

  Timer? _ringTimeout;
  final List<Map<String, dynamic>> _pendingCandidates = [];

  static bool get enabled => AppConfig.enableCalls;

  CallService(this.client, this.notifications, this.transport);

  Future<void> sendSignal(String event, Map<String, dynamic> payload) async {
    final peer = activePeerId;
    if (peer == null) return;
    await transport.send(peer, 'p2p', event, {
      'call_id': activeCallId,
      ...payload,
    });
  }

  // ==================================================================
  // Outgoing
  // ==================================================================
  Future<void> startCall({
    required String callId,
    required String peerUserId,
    required bool video,
    String? myName,
  }) async {
    if (!enabled) return;
    activeCallId = callId;
    activePeerId = peerUserId;
    isVideo = video;
    muted = false;
    _setState(CallUiState.outgoing);

    try {
      await transport.start();
      await _createPc();
      await _attachLocalMedia(video);
      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': video ? 1 : 0,
      });
      await _pc!.setLocalDescription(offer);
      await sendSignal('offer', {
        'sdp': offer.sdp,
        'video': video,
        if (myName != null && myName.trim().isNotEmpty) 'from_name': myName,
      });

      _ringTimeout?.cancel();
      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (_current == CallUiState.outgoing) {
          hangUp(markStatus: 'missed');
        }
      });
    } catch (e, st) {
      AppLogger.e('call', 'startCall failed', e, st);
      await hangUp(markStatus: 'missed');
    }
  }

  // ==================================================================
  // Incoming (dispatched by AppServices from the CallTransport)
  // ==================================================================
  /// Entry point for every signal arriving on my personal channel.
  /// Signals are filtered (`to == me`) by the transport; this method
  /// filters the 1:1 scope and ignores group-scope events.
  Future<void> handleSignal(Map<String, dynamic> msg) async {
    if (!enabled) return;
    if (msg['scope'] != 'p2p') return;
    final event = msg['event'] as String?;
    // p2p payloads carry the peer id at top level ('from').
    final p = Map<String, dynamic>.of(msg)
      ..remove('to')
      ..remove('scope');
    switch (event) {
      case 'offer':
        await _onOffer(p);
        break;
      case 'answer':
        try {
          await _pc?.setRemoteDescription(
              webrtc.RTCSessionDescription(p['sdp'] as String, 'answer'));
          _ringTimeout?.cancel();
          _setState(CallUiState.active);
        } catch (e) {
          AppLogger.w('call', 'answer apply failed', e);
        }
        break;
      case 'candidate':
        if (_pc != null) {
          await _addCandidate(p);
        } else {
          _pendingCandidates.add(p);
        }
        break;
      case 'bye':
        await _cleanup();
        _setState(CallUiState.idle);
        break;
      case 'busy':
        // Callee is on another call — honest immediate end, no 45 s wait.
        await _cleanup();
        _setState(CallUiState.idle);
        break;
      case 'renegotiate':
        // ICE-restart recovery: peer re-offered; answer to complete it.
        try {
          final pc = _pc;
          if (pc == null) break;
          await pc.setRemoteDescription(
              webrtc.RTCSessionDescription(p['sdp'] as String, 'offer'));
          final ans = await pc.createAnswer();
          await pc.setLocalDescription(ans);
          await sendSignal('renegotiate_answer', {'sdp': ans.sdp});
        } catch (e) {
          AppLogger.w('call', 'renegotiate failed', e);
        }
        break;
      case 'renegotiate_answer':
        try {
          await _pc?.setRemoteDescription(
              webrtc.RTCSessionDescription(p['sdp'] as String, 'answer'));
        } catch (e) {
          AppLogger.w('call', 'renegotiate answer failed', e);
        }
        break;
    }
  }

  Future<void> _onOffer(Map<String, dynamic> p) async {
    if (_pc != null) {
      // Occupied — tell the caller immediately instead of silence.
      final from = p['from'] as String?;
      if (from != null) {
        await transport.send(from, 'p2p', 'busy', {'call_id': p['call_id']});
      }
      return;
    }
    activeCallId = p['call_id'] as String?;
    activePeerId = p['from'] as String?;
    isVideo = p['video'] == true;
    _pendingOffer = p;
    _setState(CallUiState.incoming);
    await notifications.showIncomingCall(
      callerName: (p['from_name'] as String?)?.trim().isNotEmpty == true
          ? p['from_name'] as String
          : 'مكالمة واردة',
      video: isVideo,
    );
  }

  Future<void> acceptCall() async {
    if (_pc != null || _pendingOffer == null) return;
    _setState(CallUiState.active);
    try {
      await _createPc();
      await _attachLocalMedia(isVideo);
      final offer = _pendingOffer!;
      await _pc!.setRemoteDescription(
          webrtc.RTCSessionDescription(offer['sdp'] as String, 'offer'));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await sendSignal('answer', {'sdp': answer.sdp});
      // Flush ICE candidates that arrived before the pc existed.
      for (final c in _pendingCandidates) {
        await _addCandidate(c);
      }
      _pendingCandidates.clear();
    } catch (e, st) {
      AppLogger.e('call', 'accept failed', e, st);
      await hangUp(markStatus: 'missed');
    }
  }

  Future<void> declineCall() async {
    await sendSignal('bye', {});
    await _cleanup();
    _setState(CallUiState.idle);
  }

  Future<void> _addCandidate(Map<String, dynamic> p) async {
    try {
      await _pc?.addCandidate(webrtc.RTCIceCandidate(
        p['candidate'] as String?,
        p['sdpMid'] as String?,
        (p['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (e) {
      AppLogger.w('call', 'candidate failed', e);
    }
  }

  // ==================================================================
  // Peer connection
  // ==================================================================
  Future<void> _createPc() async {
    // STUN always; TURN (restrictive NATs) injected at build time via
    // --dart-define (AppConfig) — credentials never live in Git.
    if (AppConfig.turnConfigured) {
      AppLogger.i('call', 'ice: STUN + TURN');
    } else {
      AppLogger.i('call', 'ice: STUN only');
    }
    final pc = await webrtc.createPeerConnection({
      'iceServers': AppConfig.iceServers,
    });
    pc.onIceCandidate = (candidate) {
      sendSignal('candidate', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteCtrl.add(event.streams.first);
      }
    };
    pc.onConnectionState = (state) {
      AppLogger.i('call', 'pc: $state');
      if (state == webrtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _restartIce();
      }
    };
    _pc = pc;
  }

  Future<void> _attachLocalMedia(bool video) async {
    final stream = await webrtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video':
          video ? {'facingMode': 'user', 'width': 1280, 'height': 720} : false,
    });
    _localStream = stream;
    for (final track in stream.getTracks()) {
      await _pc!.addTrack(track, stream);
    }
  }

  Future<void> _restartIce() async {
    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      await sendSignal('renegotiate', {'sdp': offer.sdp});
    } catch (e) {
      AppLogger.w('call', 'ice restart failed', e);
    }
  }

  // ==================================================================
  // Controls
  // ==================================================================
  Future<void> toggleMute() async {
    muted = !muted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await webrtc.Helper.setSpeakerphoneOn(speakerOn);
  }

  Future<void> switchCamera() async {
    if (!isVideo) return;
    final tracks = _localStream?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    await webrtc.Helper.switchCamera(tracks.first);
  }

  Future<void> hangUp({String markStatus = 'ended'}) async {
    await sendSignal('bye', {});
    final peer = activePeerId;
    await _cleanup();
    if (peer != null) await transport.dropPeer(peer);
    _setState(CallUiState.idle);
  }

  Future<void> _cleanup() async {
    _ringTimeout?.cancel();
    try {
      _localStream?.getTracks().forEach((t) {
        t.stop();
      });
      await _pc?.close();
    } catch (_) {}
    _localStream = null;
    _pc = null;
    _pendingOffer = null;
    activeCallId = null;
    activePeerId = null;
    _pendingCandidates.clear();
  }

  void _setState(CallUiState s) {
    _current = s;
    _stateCtrl.add(s);
  }

  Future<void> dispose() async {
    await _cleanup();
    await _remoteCtrl.close();
    await _stateCtrl.close();
  }
}

enum CallUiState { idle, outgoing, incoming, active }
