import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../data/models/models.dart';
import '../../services/call_service.dart';
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

/// شاشة المكالمة (ثنائية فقط — المكالمات الجماعية غير مفعّلة):
/// WebRTC حقيقي مع معاينة محلية وبث بعيد وتحكم كامل.
class CallScreen extends StatefulWidget {
  final Chat chat;
  final bool outgoing;
  final bool video;

  const CallScreen({
    super.key,
    required this.chat,
    required this.outgoing,
    required this.video,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final webrtc.RTCVideoRenderer _remoteRenderer = webrtc.RTCVideoRenderer();

  StreamSubscription<CallUiState>? _stateSub;
  StreamSubscription<webrtc.MediaStream>? _remoteSub;
  Timer? _tickTimer;
  final Stopwatch _activeSw = Stopwatch();

  CallUiState _state = CallUiState.idle;
  String? _callId;
  bool _everActive = false;
  bool _finished = false;
  bool _muted = false;
  bool _speakerOn = true;
  String? _fatalError;

  AppServices get _services => context.read<AppServices>();
  CallService get _call => _services.call;

  String get _peerName => widget.chat.peer?.title ?? 'مكالمة';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final myName = context.read<AuthController>().me?.displayName;
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
    } catch (_) {
      // Renderers stay black; audio path keeps working.
    }

    if (!widget.outgoing) {
      // Incoming: the calls row was created by the caller; capture its id.
      _callId = _call.activeCallId;
    } else {
      final peer = widget.chat.peer;
      if (peer == null) {
        _bail('تعذر بدء المكالمة');
        return;
      }
      try {
        // 1) persist the call row (history + notifications)
        _callId = await _services.calls.createCall(
          chatId: widget.chat.id,
          calleeId: peer.id,
          type: widget.video ? 'video' : 'audio',
        );
        // 2) negotiate WebRTC
        await _call.startCall(
          callId: _callId!,
          peerUserId: peer.id,
          video: widget.video,
          myName: myName,
        );
      } catch (_) {
        _bail('تعذر بدء المكالمة — تحقق من الاتصال');
        return;
      }
    }
    if (!mounted) return;

    _attachLocal();
    setState(() {
      _state = _call.current;
      _muted = _call.muted;
      _speakerOn = _call.speakerOn;
    });
    _stateSub = _call.state.listen(_onState);
    _remoteSub = _call.remoteStream.listen((stream) {
      _remoteRenderer.srcObject = stream;
      if (mounted) setState(() {});
    });
  }

  void _attachLocal() {
    final stream = _call.localStream;
    if (stream != null && _localRenderer.srcObject != stream) {
      _localRenderer.srcObject = stream;
      if (mounted) setState(() {});
    }
  }

  void _onState(CallUiState s) {
    if (!mounted) return;
    setState(() => _state = s);
    switch (s) {
      case CallUiState.outgoing:
        _callId ??= _call.activeCallId;
        _attachLocal();
        break;
      case CallUiState.incoming:
        _callId ??= _call.activeCallId;
        break;
      case CallUiState.active:
        _callId ??= _call.activeCallId;
        _attachLocal();
        if (!_everActive) {
          _everActive = true;
          _activeSw
            ..reset()
            ..start();
        }
        _tickTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
        break;
      case CallUiState.idle:
        if (!_finished) _finish();
        break;
    }
  }

  /// Persist the call record then leave the screen.
  Future<void> _finish() async {
    _finished = true;
    _tickTimer?.cancel();
    _activeSw.stop();
    final durationSec = _activeSw.elapsed.inSeconds;
    final status = _everActive
        ? AppConstants.callEnded
        : (widget.outgoing
            ? AppConstants.callMissed
            : AppConstants.callDeclined);
    final id = _callId;
    if (id != null) {
      try {
        await _services.calls
            .updateStatus(id, status, durationSec: durationSec);
      } catch (_) {
        // History write is best-effort; never block the UI on it.
      }
    }
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

  // ===================================================================
  // Controls
  // ===================================================================
  Future<void> _end() => _call.hangUp(); // state -> idle -> _finish()

  Future<void> _accept() async {
    await _call.acceptCall();
    _attachLocal();
  }

  Future<void> _decline() => _call.declineCall(); // idle -> _finish()

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

  // ===================================================================
  // Build
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop && !_finished) {
            _call.hangUp();
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
      case CallUiState.incoming:
        return _incomingUI();
      case CallUiState.outgoing:
        return _ringUI('جاري الاتصال...');
      case CallUiState.active:
        return widget.video ? _activeVideoUI() : _activeAudioUI();
      case CallUiState.idle:
        return const Center(
          key: ValueKey('ended'),
          child:
              Text('انتهت المكالمة', style: TextStyle(color: Colors.white70)),
        );
    }
  }

  // ===================================================================
  // UI states
  // ===================================================================
  Widget _avatar(double size) {
    final title = _peerName;
    final seedId = widget.chat.peer?.id ?? widget.chat.id;
    // v0.1.0: unified AvatarWidget — was a local gradient circle.
    return AvatarWidget(
      label: title,
      seedId: seedId,
      radius: size / 2,
    );
  }

  Widget _incomingUI() {
    return Column(
      key: const ValueKey('incoming'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        _avatar(110),
        const SizedBox(height: 18),
        Text(
          _peerName,
          style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          widget.video ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة',
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
              tooltip: 'قبول',
            ),
          ],
        ),
        const SizedBox(height: 48),
      ],
    );
  }

  Widget _ringUI(String status) {
    return Column(
      key: const ValueKey('ring'),
      children: [
        const Spacer(),
        _avatar(110),
        const SizedBox(height: 18),
        Text(
          _peerName,
          style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(status,
            style: const TextStyle(color: Colors.white60, fontSize: 14)),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundButton(
              icon: _muted ? Icons.mic_off : Icons.mic,
              color: _muted
                  ? Colors.white24
                  : Colors.white.withValues(alpha: 0.12),
              iconColor: Colors.white,
              onTap: _toggleMute,
              tooltip: _muted ? 'إلغاء كتم الميكروفون' : 'كتم الميكروفون',
            ),
            const SizedBox(width: 22),
            _roundButton(
              icon: Icons.call_end,
              color: AppTheme.errorColor,
              onTap: _end,
              tooltip: 'إنهاء المكالمة',
            ),
            const SizedBox(width: 22),
            _roundButton(
              icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
              color: Colors.white.withValues(alpha: 0.12),
              iconColor: Colors.white,
              onTap: _toggleSpeaker,
              tooltip: _speakerOn ? 'إيقاف مكبر الصوت' : 'تشغيل مكبر الصوت',
            ),
          ],
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _activeAudioUI() {
    return Column(
      key: const ValueKey('audio'),
      children: [
        const Spacer(),
        _avatar(110),
        const SizedBox(height: 18),
        Text(
          _peerName,
          style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          _fmt(_activeSw.elapsed),
          style: const TextStyle(color: AppTheme.statusRead, fontSize: 16),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundButton(
              icon: _muted ? Icons.mic_off : Icons.mic,
              color: _muted
                  ? Colors.white24
                  : Colors.white.withValues(alpha: 0.12),
              iconColor: Colors.white,
              onTap: _toggleMute,
              tooltip: 'الميكروفون',
            ),
            const SizedBox(width: 22),
            _roundButton(
              icon: Icons.call_end,
              color: AppTheme.errorColor,
              size: 66,
              onTap: _end,
              tooltip: 'إنهاء المكالمة',
            ),
            const SizedBox(width: 22),
            _roundButton(
              icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
              color: Colors.white.withValues(alpha: 0.12),
              iconColor: Colors.white,
              onTap: _toggleSpeaker,
              tooltip: 'مكبر الصوت',
            ),
          ],
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _activeVideoUI() {
    final hasRemote = _remoteRenderer.srcObject != null;
    final hasLocal = _localRenderer.srcObject != null;
    return Stack(
      key: const ValueKey('video'),
      fit: StackFit.expand,
      children: [
        if (hasRemote)
          webrtc.RTCVideoView(
            _remoteRenderer,
            objectFit: webrtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          )
        else
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _avatar(90),
                const SizedBox(height: 14),
                Text(_peerName,
                    style: const TextStyle(color: Colors.white, fontSize: 19)),
                const SizedBox(height: 6),
                Text(_fmt(_activeSw.elapsed),
                    style: const TextStyle(
                        color: AppTheme.statusRead, fontSize: 14)),
              ],
            ),
          ),
        if (hasLocal)
          PositionedDirectional(
            top: 14,
            end: 14,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 104,
                height: 150,
                color: Colors.white10,
                child: webrtc.RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit:
                      webrtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),
          ),
        PositionedDirectional(
          bottom: 26,
          start: 0,
          end: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
                icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                color: Colors.white.withValues(alpha: 0.14),
                iconColor: Colors.white,
                onTap: _toggleSpeaker,
                tooltip: 'مكبر الصوت',
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
                icon: Icons.call_end,
                color: AppTheme.errorColor,
                size: 62,
                onTap: _end,
                tooltip: 'إنهاء المكالمة',
              ),
            ],
          ),
        ),
      ],
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
    _remoteSub?.cancel();
    _tickTimer?.cancel();
    _activeSw.stop();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}
