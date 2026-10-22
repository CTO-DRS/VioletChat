import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:provider/provider.dart';

import '../../data/models/models.dart';
import '../../services/group_call_service.dart';
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

/// شاشة المكالمة الجماعية (v0.1.0) — WebRTC mesh حقيقي:
/// شبكة مشاركين (فيديو أو صور رمزية للصوت)، كتم/سماعة/تبديل كاميرا.
/// حدود صادقة: بلا سجل مكالمات للاجتماعات، وحد أعلى للشبكة.
class GroupCallScreen extends StatefulWidget {
  final Chat chat;
  final bool outgoing;
  final bool video;
  final List<String> memberIds;

  const GroupCallScreen({
    super.key,
    required this.chat,
    required this.outgoing,
    required this.video,
    required this.memberIds,
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final Map<String, webrtc.RTCVideoRenderer> _remoteRenderers = {};

  StreamSubscription<GroupCallUiState>? _stateSub;
  StreamSubscription<Map<String, webrtc.MediaStream?>>? _peersSub;
  Timer? _tickTimer;
  final Stopwatch _activeSw = Stopwatch();

  GroupCallUiState _state = GroupCallUiState.idle;
  bool _finished = false;
  bool _muted = false;
  bool _speakerOn = true;
  String? _fatalError;

  final Map<String, String> _names = {};

  AppServices get _services => context.read<AppServices>();
  GroupCallService get _call => _services.groupCall;

  bool get _isVideo => widget.video;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Capture before any async gap (BuildContext across awaits).
    final myName = context.read<AuthController>().me?.displayName ?? '';
    // Resolve member names for tiles (best-effort).
    try {
      final members = await _services.chats.loadMembers(widget.chat.id);
      for (final m in members) {
        _names[m.profile.id] = m.profile.title;
      }
    } catch (_) {}

    try {
      await _localRenderer.initialize();
    } catch (_) {}

    if (widget.outgoing) {
      try {
        await _call.startCall(
          chatId: widget.chat.id,
          chatName: widget.chat.title,
          video: widget.video,
          memberIds: widget.memberIds,
          myName: myName,
        );
      } catch (_) {
        _bail('تعذر بدء المكالمة الجماعية');
        return;
      }
    }

    if (!mounted) return;
    _attachLocal();
    setState(() {
      _state = _call.state;
      _muted = _call.muted;
      _speakerOn = _call.speakerOn;
    });
    _stateSub = _call.stateStream.listen(_onState);
    _peersSub = _call.peersStream.listen(_onPeers);
    _syncRenderers();
  }

  void _attachLocal() {
    final stream = _call.localStream;
    if (stream != null && _localRenderer.srcObject != stream) {
      _localRenderer.srcObject = stream;
      if (mounted) setState(() {});
    }
  }

  void _onPeers(Map<String, webrtc.MediaStream?> peers) {
    _syncRenderers();
    if (mounted) setState(() {});
  }

  void _syncRenderers() {
    // Create renderers for new peers, dispose gone ones.
    for (final id in _call.peers.keys) {
      if (!_remoteRenderers.containsKey(id)) {
        final r = webrtc.RTCVideoRenderer();
        _remoteRenderers[id] = r;
        r.initialize().then((_) {
          final s = _call.peers[id];
          if (s != null && r.srcObject != s) r.srcObject = s;
          if (mounted) setState(() {});
        }).catchError((_) {});
      } else {
        final r = _remoteRenderers[id]!;
        final s = _call.peers[id];
        if (s != null && r.srcObject != s) r.srcObject = s;
      }
    }
    for (final id in List<String>.of(_remoteRenderers.keys)) {
      if (!_call.peers.containsKey(id)) {
        _remoteRenderers.remove(id)?.dispose();
      }
    }
  }

  void _onState(GroupCallUiState s) {
    if (!mounted) return;
    setState(() => _state = s);
    switch (s) {
      case GroupCallUiState.ringing:
        _attachLocal();
        break;
      case GroupCallUiState.active:
        _attachLocal();
        _syncRenderers();
        if (!_activeSw.isRunning) {
          if (_call.iAmInitiator) {
            _activeSw
              ..reset()
              ..start();
          }
          _tickTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          });
        }
        break;
      case GroupCallUiState.idle:
        if (!_finished) _finish();
        break;
    }
  }

  Future<void> _finish() async {
    _finished = true;
    _tickTimer?.cancel();
    _activeSw.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _bail(String msg) async {
    if (!mounted) return;
    setState(() => _fatalError = msg);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && !_finished) {
      _finished = true;
      Navigator.of(context).pop();
    }
  }

  // ==================================================================
  // Controls
  // ==================================================================
  Future<void> _end() => _call.leave();

  Future<void> _accept() async {
    await _call.acceptCall(memberIds: widget.memberIds);
    _attachLocal();
  }

  Future<void> _decline() => _call.declineCall();

  Future<void> _toggleMute() async {
    await _call.toggleMute();
    if (mounted) setState(() => _muted = _call.muted);
  }

  Future<void> _toggleSpeaker() async {
    await _call.toggleSpeaker();
    if (mounted) setState(() => _speakerOn = _call.speakerOn);
  }

  Future<void> _switchCamera() async {
    await _call.switchCamera();
  }

  // ==================================================================
  // Build
  // ==================================================================
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop && !_finished && _state != GroupCallUiState.idle) {
            _call.leave();
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _body(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_fatalError != null) {
      return Center(
        key: const ValueKey('error'),
        child: Text(
          _fatalError!,
          style: const TextStyle(color: Colors.white70, fontSize: 15),
          textAlign: TextAlign.center,
        ),
      );
    }
    switch (_state) {
      case GroupCallUiState.ringing:
        return widget.outgoing ? _ringUI() : _incomingUI();
      case GroupCallUiState.active:
        return _isVideo ? _activeVideoUI() : _activeAudioUI();
      case GroupCallUiState.idle:
        return const Center(
          key: ValueKey('ended'),
          child:
              Text('انتهت المكالمة', style: TextStyle(color: Colors.white70)),
        );
    }
  }

  String get _title => 'مكالمة جماعية — ${widget.chat.title}';

  Widget _incomingUI() {
    return Column(
      key: const ValueKey('incoming'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        _avatar(widget.chat.title, widget.chat.id, 96),
        const SizedBox(height: 16),
        Text(_title,
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          _isVideo ? 'مكالمة فيديو جماعية واردة' : 'مكالمة صوتية جماعية واردة',
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundButton(
              icon: Icons.call_end,
              color: AppTheme.errorColor,
              size: 66,
              onTap: _decline,
              tooltip: 'رفض',
            ),
            const SizedBox(width: 40),
            _roundButton(
              icon: Icons.call,
              color: AppTheme.successColor,
              size: 66,
              onTap: _accept,
              tooltip: 'انضمام',
            ),
          ],
        ),
        const SizedBox(height: 48),
      ],
    );
  }

  Widget _ringUI() {
    return Column(
      key: const ValueKey('ring'),
      children: [
        const Spacer(),
        _avatar(widget.chat.title, widget.chat.id, 96),
        const SizedBox(height: 16),
        Text(_title,
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('جاري الاتصال بـ ${widget.memberIds.length} عضو...',
            style: const TextStyle(color: Colors.white60, fontSize: 14)),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _roundButton(
            icon: _muted ? Icons.mic_off : Icons.mic,
            color:
                _muted ? Colors.white24 : Colors.white.withValues(alpha: 0.12),
            iconColor: Colors.white,
            onTap: _toggleMute,
            tooltip: 'الميكروفون',
          ),
          const SizedBox(width: 22),
          _roundButton(
            icon: Icons.call_end,
            color: AppTheme.errorColor,
            onTap: _end,
            tooltip: 'إنهاء',
          ),
          const SizedBox(width: 22),
          _roundButton(
            icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
            color: Colors.white.withValues(alpha: 0.12),
            iconColor: Colors.white,
            onTap: _toggleSpeaker,
            tooltip: 'مكبر الصوت',
          ),
        ]),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _activeAudioUI() {
    final count = _call.peers.length + 1;
    return Column(
      key: const ValueKey('audio'),
      children: [
        const Spacer(),
        _avatar(widget.chat.title, widget.chat.id, 96),
        const SizedBox(height: 16),
        Text(widget.chat.title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'المشاركون: $count',
          style: const TextStyle(color: AppTheme.statusRead, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Text(
          _fmt(_activeSw.elapsed),
          style: const TextStyle(color: AppTheme.statusRead, fontSize: 15),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            _audioTile(context.read<AuthController>().me?.displayName ?? 'أنت',
                muted: _muted, me: true),
            for (final entry in _call.peers.entries)
              _audioTile(_names[entry.key] ?? 'عضو'),
          ],
        ),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _roundButton(
            icon: _muted ? Icons.mic_off : Icons.mic,
            color:
                _muted ? Colors.white24 : Colors.white.withValues(alpha: 0.14),
            iconColor: Colors.white,
            onTap: _toggleMute,
            tooltip: 'الميكروفون',
          ),
          const SizedBox(width: 16),
          _roundButton(
            icon: Icons.call_end,
            color: AppTheme.errorColor,
            size: 64,
            onTap: _end,
            tooltip: 'إنهاء المكالمة',
          ),
          const SizedBox(width: 16),
          _roundButton(
            icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
            color: Colors.white.withValues(alpha: 0.14),
            iconColor: Colors.white,
            onTap: _toggleSpeaker,
            tooltip: 'مكبر الصوت',
          ),
        ]),
        const SizedBox(height: 36),
      ],
    );
  }

  Widget _audioTile(String name, {bool muted = false, bool me = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(
              color: muted
                  ? AppTheme.errorColor.withValues(alpha: 0.8)
                  : AppTheme.successColor.withValues(alpha: 0.55),
              width: 2,
            ),
          ),
          child: Icon(muted ? Icons.mic_off : Icons.mic,
              color: Colors.white70, size: 26),
        ),
        const SizedBox(height: 5),
        SizedBox(
          width: 84,
          child: Text(
            me ? '$name (أنت)' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _activeVideoUI() {
    final peerIds = _call.peers.keys.toList();
    final tiles = <Widget>[
      _videoTile(_localRenderer, null, isLocal: true),
      for (final id in peerIds) _videoTile(_remoteRenderers[id], _names[id]),
    ];
    return Stack(
      key: const ValueKey('video'),
      fit: StackFit.expand,
      children: [
        GridView.count(
          crossAxisCount: peerIds.isEmpty ? 1 : 2,
          childAspectRatio: 0.72,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 120),
          children: tiles,
        ),
        PositionedDirectional(
          top: 10,
          start: 0,
          end: 0,
          child: Text(
            '${widget.chat.title} • ${_fmt(_activeSw.elapsed)}',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600),
          ),
        ),
        PositionedDirectional(
          bottom: 26,
          start: 0,
          end: 0,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _roundButton(
              icon: _muted ? Icons.mic_off : Icons.mic,
              color: _muted
                  ? Colors.white24
                  : Colors.white.withValues(alpha: 0.14),
              iconColor: Colors.white,
              onTap: _toggleMute,
              tooltip: 'الميكروفون',
            ),
            const SizedBox(width: 14),
            _roundButton(
              icon: Icons.switch_camera,
              color: Colors.white.withValues(alpha: 0.14),
              iconColor: Colors.white,
              onTap: _switchCamera,
              tooltip: 'تبديل الكاميرا',
            ),
            const SizedBox(width: 14),
            _roundButton(
              icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
              color: Colors.white.withValues(alpha: 0.14),
              iconColor: Colors.white,
              onTap: _toggleSpeaker,
              tooltip: 'مكبر الصوت',
            ),
            const SizedBox(width: 14),
            _roundButton(
              icon: Icons.call_end,
              color: AppTheme.errorColor,
              size: 62,
              onTap: _end,
              tooltip: 'إنهاء المكالمة',
            ),
          ]),
        ),
      ],
    );
  }

  Widget _videoTile(webrtc.RTCVideoRenderer? renderer, String? name,
      {bool isLocal = false}) {
    final label = isLocal ? 'أنت' : (name ?? 'عضو');
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: Colors.white10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (renderer != null && renderer.srcObject != null)
              webrtc.RTCVideoView(
                renderer,
                mirror: isLocal,
                objectFit:
                    webrtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              Center(child: _avatar(label, isLocal ? 'me' : label, 56)),
            PositionedDirectional(
              bottom: 8,
              start: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(String title, String seedId, double size) {
    // v0.1.0: unified AvatarWidget — was a local gradient circle.
    return AvatarWidget(
      label: title,
      seedId: seedId,
      radius: size / 2,
    );
  }

  Widget _roundButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required String tooltip,
    Color iconColor = Colors.white,
    double size = 56,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: iconColor, size: size * 0.46),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _peersSub?.cancel();
    _tickTimer?.cancel();
    _activeSw.stop();
    for (final r in _remoteRenderers.values) {
      r.dispose();
    }
    _localRenderer.dispose();
    super.dispose();
  }
}
