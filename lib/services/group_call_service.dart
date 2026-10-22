import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'call_transport.dart';
import 'group_call_mesh.dart';
import 'notification_service.dart';

/// Group calls (v0.1.0) — real WebRTC MESH over the personal
/// signaling transport ([CallTransport]).
///
/// Signaling per pair (deterministic, glare-free — see
/// [GroupCallMesh]):
///   invite : initiator → every group member (personal channels)
///   join   : joiner → every member; incumbents answer `present`
///   offer  : joiner → each incumbent (simultaneous joins: smaller id)
///   answer : incumbent → joiner; trickle ICE both ways
///   leave  : participant → its peers;  end : initiator → all members
///
/// Honest boundaries (documented in FINAL_AUDIT):
/// - group calls write NO calls-table history rows (the schema assumes
///   exactly two participants) — live calling only;
/// - mesh suits small groups ([AppConfig.groupCallMaxPeers] cap);
/// - incoming group invites ring while the app is in the foreground
///   (the transport is a session-time channel, like 1:1 after v0.1.0).
class GroupCallService {
  final SupabaseClient client;
  final CallTransport transport;
  final NotificationService notifications;

  GroupCallUiState state = GroupCallUiState.idle;
  String? activeCallId;
  String? activeChatId;
  bool isVideo = false;
  bool muted = false;
  bool speakerOn = true;
  bool iAmInitiator = false;

  GroupCallMesh mesh = GroupCallMesh('');

  final _stateCtrl = StreamController<GroupCallUiState>.broadcast();
  final _peersCtrl =
      StreamController<Map<String, webrtc.MediaStream?>>.broadcast();
  Stream<GroupCallUiState> get stateStream => _stateCtrl.stream;

  /// Snapshot: peerId -> remote media (null until the track arrives).
  Stream<Map<String, webrtc.MediaStream?>> get peersStream => _peersCtrl.stream;
  Map<String, webrtc.MediaStream?> peers = {};

  webrtc.MediaStream? localStream;

  static bool get enabled => AppConfig.enableGroupCalls;

  // WebRTC + signaling plumbing.
  final Map<String, webrtc.RTCPeerConnection> _pcs = {};
  final Map<String, List<Map<String, dynamic>>> _pendingCandidates = {};
  final Map<String, Timer> _answerTimers = {};
  Timer? _ringTimer;
  Timer? _aloneTimer;

  GroupCallService(this.client, this.notifications, this.transport);

  String get myId => client.auth.currentUser!.id;
  bool get _busy => state != GroupCallUiState.idle;

  // ==================================================================
  // Outgoing — start a call from a group chat
  // ==================================================================
  Future<void> startCall({
    required String chatId,
    required String chatName,
    required bool video,
    required List<String> memberIds,
    required String myName,
  }) async {
    if (!enabled || _busy) return;
    final targets = memberIds.where((m) => m != myId).toSet().toList();
    if (targets.isEmpty) return;

    _lastMembers = targets;
    activeChatId = chatId;
    isVideo = video;
    muted = false;
    iAmInitiator = true;
    mesh = GroupCallMesh(myId);
    activeCallId = _uuid();
    _setState(GroupCallUiState.ringing);

    try {
      await transport.start();
      await _getMedia(video);
      for (final m in targets) {
        await transport.send(m, 'group', 'group-invite', {
          'call_id': activeCallId,
          'chat_id': chatId,
          'chat_name': chatName,
          'video': video,
          'from_name': myName,
        });
      }
      _ringTimer?.cancel();
      _ringTimer = Timer(const Duration(seconds: 45), () {
        if (state == GroupCallUiState.ringing) {
          AppLogger.i('gcall', 'no one joined in 45s — ending');
          _endLocal();
        }
      });
    } catch (e, st) {
      AppLogger.e('gcall', 'start failed', e, st);
      await _endLocal();
    }
  }

  // ==================================================================
  // Incoming
  // ==================================================================
  Future<void> handleSignal(Map<String, dynamic> msg) async {
    if (!enabled) return;
    if (msg['scope'] != 'group') return;
    final event = msg['event'] as String?;
    final from = msg['from'] as String?;
    if (from == null || from == myId) return;

    switch (event) {
      case 'group-invite':
        await _onInvite(msg, from);
        break;
      case 'group-join':
        await _onJoin(msg, from);
        break;
      case 'group-present':
        if (!_busy) return;
        if (mesh.onPresent(from)) {
          await _offerTo(from);
        }
        break;
      case 'group-offer':
        await _onOffer(msg, from);
        break;
      case 'group-answer':
        await _onAnswer(msg, from);
        break;
      case 'group-candidate':
        await _addCandidate(from, msg);
        break;
      case 'group-leave':
        if (!_busy) return;
        await _dropPeer(from);
        break;
      case 'group-end':
        if (!_busy) return;
        if (msg['call_id'] == activeCallId || iAmInitiator == false) {
          await _endLocal(fromEnded: true);
        }
        break;
    }
  }

  Future<void> _onInvite(Map<String, dynamic> msg, String from) async {
    if (_busy) return; // occupied — silent ignore (no history rows either)
    // A group I'm not a member of cannot reach this channel
    // (targets come from real member lists on the initiator side).
    activeCallId = msg['call_id'] as String?;
    activeChatId = msg['chat_id'] as String?;
    isVideo = msg['video'] == true;
    iAmInitiator = false;
    mesh = GroupCallMesh(myId);
    _setState(GroupCallUiState.ringing);
    await notifications.showIncomingCall(
      callerName: (msg['chat_name'] as String?)?.trim().isNotEmpty == true
          ? 'مكالمة جماعية — ${msg['chat_name']}'
          : 'مكالمة جماعية واردة',
      video: isVideo,
    );
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      if (state == GroupCallUiState.ringing && !iAmInitiator) {
        _setState(GroupCallUiState.idle); // missed — just stop ringing
        _cleanupAll();
      }
    });
  }

  Future<void> _onJoin(Map<String, dynamic> msg, String joiner) async {
    if (!_busy || msg['call_id'] != activeCallId) return;
    if (iAmInitiator && state == GroupCallUiState.ringing) {
      _ringTimer?.cancel();
      _setState(GroupCallUiState.active);
    }
    if (mesh.shouldReplyPresent(joiner)) {
      await transport
          .send(joiner, 'group', 'group-present', {'call_id': activeCallId});
      // The joiner will offer me — nothing else to do yet.
    } else if (mesh.shouldOfferToSimultaneousJoiner(joiner)) {
      await _offerTo(joiner);
    }
    _cancelAloneTimer();
  }

  // ==================================================================
  // Accept / decline / leave
  // ==================================================================
  Future<void> acceptCall({required List<String> memberIds}) async {
    if (!_busy || iAmInitiator || mesh.collecting) return;
    _ringTimer?.cancel();
    mesh.beginJoin();
    _setState(GroupCallUiState.active);
    try {
      await transport.start();
      await _getMedia(isVideo);
      // Tell everyone (dedupe happens at the receivers) that I joined.
      for (final m in memberIds.where((m) => m != myId).toSet()) {
        await transport
            .send(m, 'group', 'group-join', {'call_id': activeCallId});
      }
      _lastMembers = memberIds.where((m) => m != myId).toSet().toList();
      // Give incumbents a window to answer with presents, then offer
      // to everyone discovered so far. Late presents are handled in
      // handleSignal (immediate offer on new discovery).
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      for (final peer in mesh.peers.toList()) {
        await _offerTo(peer);
      }
      mesh.endJoin();
      // Nobody else in the call? Leave after a grace period.
      _armAloneTimer();
    } catch (e, st) {
      AppLogger.e('gcall', 'accept failed', e, st);
      await _endLocal();
    }
  }

  Future<void> declineCall() async {
    if (!_busy) return;
    // Silent decline — no history rows exist to update, the initiator
    // simply never sees us (the same trust model as 1:1 'bye').
    if (!iAmInitiator) {
      _ringTimer?.cancel();
      _cleanupAll();
      _setState(GroupCallUiState.idle);
    }
  }

  Future<void> leave() => _endLocal();

  Future<void> _endLocal({bool fromEnded = false}) async {
    if (!_busy) return;
    final wasInitiator = iAmInitiator;
    final peersSnapshot = mesh.peers.toList();
    // Announce departure.
    for (final p in peersSnapshot) {
      await transport
          .send(p, 'group', 'group-leave', {'call_id': activeCallId});
    }
    if (wasInitiator) {
      final members = _lastMembers;
      for (final m in members.where((m) => m != myId)) {
        await transport
            .send(m, 'group', 'group-end', {'call_id': activeCallId});
      }
    }
    await _cleanupAll();
    _setState(GroupCallUiState.idle);
  }

  List<String> _lastMembers = const [];

  /// Remember the member list for the `group-end` fan-out.
  void rememberMembers(List<String> ids) => _lastMembers = ids;

  // ==================================================================
  // WebRTC per-peer plumbing
  // ==================================================================
  Future<void> _getMedia(bool video) async {
    localStream = await webrtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video':
          video ? {'facingMode': 'user', 'width': 1280, 'height': 720} : false,
    });
    _snapshot();
  }

  Future<void> _offerTo(String peerId) async {
    try {
      if (_pcs.containsKey(peerId)) return; // already negotiating/connected
      mesh.trackPeer(peerId);
      final pc = await _createPc(peerId);
      for (final track in localStream!.getTracks()) {
        await pc.addTrack(track, localStream!);
      }
      final offer = await pc.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': isVideo ? 1 : 0,
      });
      await pc.setLocalDescription(offer);
      await transport.send(peerId, 'group', 'group-offer', {
        'call_id': activeCallId,
        'sdp': offer.sdp,
        'video': isVideo,
      });
      // If the peer never answers, tear this pair down.
      _answerTimers[peerId]?.cancel();
      _answerTimers[peerId] = Timer(const Duration(seconds: 25), () {
        if (_pcs[peerId]?.connectionState !=
            webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          AppLogger.w('gcall', 'peer $peerId never answered — dropping');
          _dropPeer(peerId);
        }
      });
    } catch (e) {
      AppLogger.w('gcall', 'offer to peer failed', e);
    }
  }

  Future<void> _onOffer(Map<String, dynamic> msg, String from) async {
    if (!_busy || msg['call_id'] != activeCallId) return;
    try {
      _ringTimer?.cancel();
      mesh.trackPeer(from);
      var pc = _pcs[from];
      if (pc == null) {
        pc = await _createPc(from);
        for (final track in localStream!.getTracks()) {
          await pc.addTrack(track, localStream!);
        }
      }
      await pc.setRemoteDescription(
          webrtc.RTCSessionDescription(msg['sdp'] as String, 'offer'));
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await transport.send(from, 'group', 'group-answer',
          {'call_id': activeCallId, 'sdp': answer.sdp});
      for (final c in _pendingCandidates.remove(from) ?? const []) {
        await _addCandidate(from, c);
      }
      _snapshot();
      _cancelAloneTimer();
    } catch (e) {
      AppLogger.w('gcall', 'offer handling failed', e);
    }
  }

  Future<void> _onAnswer(Map<String, dynamic> msg, String from) async {
    if (!_busy || msg['call_id'] != activeCallId) return;
    try {
      final pc = _pcs[from];
      if (pc == null) return;
      await pc.setRemoteDescription(
          webrtc.RTCSessionDescription(msg['sdp'] as String, 'answer'));
      _answerTimers.remove(from)?.cancel();
      for (final c in _pendingCandidates.remove(from) ?? const []) {
        await _addCandidate(from, c);
      }
      _snapshot();
    } catch (e) {
      AppLogger.w('gcall', 'answer handling failed', e);
    }
  }

  Future<webrtc.RTCPeerConnection> _createPc(String peerId) async {
    final pc = await webrtc.createPeerConnection({
      'iceServers': AppConfig.iceServers,
    });
    pc.onIceCandidate = (candidate) {
      transport.send(peerId, 'group', 'group-candidate', {
        'call_id': activeCallId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        peers[peerId] = event.streams.first;
        _snapshot();
      }
    };
    pc.onConnectionState = (s) {
      AppLogger.i('gcall', 'pc($peerId): $s');
      if (s == webrtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _dropPeer(peerId);
      }
    };
    _pcs[peerId] = pc;
    return pc;
  }

  Future<void> _addCandidate(String from, Map<String, dynamic> p) async {
    final pc = _pcs[from];
    try {
      if (pc == null) {
        (_pendingCandidates[from] ??= []).add(p);
        return;
      }
      await pc.addCandidate(webrtc.RTCIceCandidate(
        p['candidate'] as String?,
        p['sdpMid'] as String?,
        (p['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (e) {
      AppLogger.w('gcall', 'candidate failed', e);
    }
  }

  Future<void> _dropPeer(String peerId) async {
    mesh.untrackPeer(peerId);
    _answerTimers.remove(peerId)?.cancel();
    final pc = _pcs.remove(peerId);
    try {
      await pc?.close();
    } catch (_) {}
    peers.remove(peerId);
    _snapshot();
    _armAloneTimer();
  }

  // ==================================================================
  // Controls
  // ==================================================================
  Future<void> toggleMute() async {
    muted = !muted;
    localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await webrtc.Helper.setSpeakerphoneOn(speakerOn);
  }

  Future<void> switchCamera() async {
    if (!isVideo) return;
    final tracks = localStream?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    await webrtc.Helper.switchCamera(tracks.first);
  }

  // ==================================================================
  // Lifecycle
  // ==================================================================
  void _armAloneTimer() {
    _aloneTimer?.cancel();
    if (state == GroupCallUiState.active && mesh.isAlone && !iAmInitiator) {
      _aloneTimer = Timer(const Duration(seconds: 12), () {
        if (mesh.isAlone && state == GroupCallUiState.active) {
          AppLogger.i('gcall', 'alone after peers left — ending');
          _endLocal();
        }
      });
    }
  }

  void _cancelAloneTimer() {
    _aloneTimer?.cancel();
    _aloneTimer = null;
  }

  Future<void> _cleanupAll() async {
    _ringTimer?.cancel();
    _cancelAloneTimer();
    for (final t in _answerTimers.values) {
      t.cancel();
    }
    _answerTimers.clear();
    for (final pc in _pcs.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _pcs.clear();
    _pendingCandidates.clear();
    try {
      localStream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
    localStream = null;
    peers.clear();
    mesh.reset();
    activeCallId = null;
    activeChatId = null;
    iAmInitiator = false;
    _lastMembers = const [];
    _snapshot();
  }

  void _setState(GroupCallUiState s) {
    state = s;
    _stateCtrl.add(s);
  }

  void _snapshot() {
    _peersCtrl.add(Map<String, webrtc.MediaStream?>.of(peers));
  }

  String _uuid() {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final r = (DateTime.now().microsecondsSinceEpoch * 7919)
        .toRadixString(36)
        .padLeft(11, '0');
    return 'g$t$r'.substring(0, 24);
  }

  Future<void> dispose() async {
    await _cleanupAll();
    await _stateCtrl.close();
    await _peersCtrl.close();
  }
}

enum GroupCallUiState { idle, ringing, active }
