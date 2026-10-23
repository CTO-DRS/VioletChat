import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/utils/smart_date.dart';
import '../../data/models/models.dart';
import '../../services/story_service.dart' show StoryItem;
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../state/stories_controller.dart';
import '../../widgets/brand.dart';

/// v0.1.10 — stories feature surfaces: the WhatsApp-style ring bar on
/// the chats/friends tabs, the composer (text status / encrypted image
/// with caption) and the full-screen viewer with viewers sheet.
///
/// All content is E2E: captions and images are sealed with a per-story
/// key wrapped for friends' devices (see StoryService). The viewer
/// decrypts media through the shared MediaService cache.

// ====================================================================
// RING BAR
// ====================================================================

class StoryRingBar extends StatelessWidget {
  const StoryRingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final stories = context.watch<StoriesController>();
    final profiles = stories.profileCache;
    final order = stories.authorOrder;

    return SizedBox(
      height: 108,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        children: [
          // ---- my status: compose + my live ring ----
          _RingSlot(
            label: 'حالتي',
            seen: false,
            isMine: true,
            child: _MyAvatar(stories: stories),
            onTap: () =>
                Navigator.of(context).pushNamed('/stories/compose'),
          ),
          for (final authorId in order)
            if (authorId != stories.myId)
              _RingSlot(
                label: _nameOf(profiles, authorId),
                seen: !stories.authorHasUnseen(authorId),
                child: AvatarWidget(
                  profile: profiles[authorId],
                  label: _nameOf(profiles, authorId),
                  seedId: authorId,
                  radius: 26,
                ),
                onTap: () => Navigator.of(context)
                    .pushNamed('/stories/view', arguments: authorId),
              ),
          if (order.length <= 1)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6, top: 26),
              child: Text(
                'حالات أصدقائك تظهر هنا — مشفرة طرف-لطرف',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  static String _nameOf(Map<String, Profile> profiles, String id) {
    final p = profiles[id];
    if (p != null && p.title.trim().isNotEmpty) return p.title;
    return 'صديق';
  }
}

class _MyAvatar extends StatelessWidget {
  final StoriesController stories;

  const _MyAvatar({required this.stories});

  @override
  Widget build(BuildContext context) {
    final mine = stories.byAuthor[stories.myId];
    if (mine != null && mine.isNotEmpty) {
      final latest = mine.last;
      final media = latest.content?.media;
      if (media != null) {
        // v0.1.11: video stories have no cheap frame thumbnail — a
        // distinct play glyph instead of pretending to have a preview.
        if (media.type == 'video') {
          return const ColoredBox(
            color: Color(0xFF2A1B4A),
            child: Icon(Icons.play_arrow_rounded, color: Colors.white70),
          );
        }
        return ClipOval(
          child: SizedBox(
            width: 52,
            height: 52,
            child: FutureBuilder<Uint8List?>(
              future: AppServices.I.mediaService.downloadDecrypted(
                path: media.path,
                fileKeyB64: media.fileKey,
                fileNonceB64: media.fileNonce,
              ),
              builder: (ctx, snap) => snap.data != null
                  ? Image.memory(snap.data!, fit: BoxFit.cover)
                  : const ColoredBox(
                      color: Color(0xFF2A1B4A),
                      child: Icon(Icons.image_rounded,
                          color: Colors.white54)),
            ),
          ),
        );
      }
    }
    return AvatarWidget(
      profile: context.read<AuthController>().me,
      label: 'أنا',
      seedId: stories.myId,
      radius: 26,
    );
  }
}

class _RingSlot extends StatelessWidget {
  final String label;
  final bool seen;
  final bool isMine;
  final Widget child;
  final VoidCallback onTap;

  const _RingSlot({
    required this.label,
    required this.seen,
    required this.child,
    required this.onTap,
    this.isMine = false,
  });

  @override
  Widget build(BuildContext context) {
    final ringGradient = seen && !isMine
        ? LinearGradient(colors: [
            Colors.grey.shade600,
            Colors.grey.shade700,
          ])
        : AppTheme.brandGradient;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(34),
        onTap: onTap,
        child: SizedBox(
          width: 68,
          child: Column(
            children: [
              Container(
                width: 60,
                height: 60,
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  gradient: ringGradient,
                  shape: BoxShape.circle,
                  boxShadow: (!seen || isMine)
                      ? AppTheme.glow(
                          color: AppTheme.brandPrimary,
                          alpha: 0.35,
                          blur: 12)
                      : null,
                ),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Color(0xFF150C2E),
                    shape: BoxShape.circle,
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(child: child),
                      if (isMine)
                        PositionedDirectional(
                          end: -2,
                          bottom: -2,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              gradient: AppTheme.brandGradient,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: const Color(0xFF150C2E), width: 2),
                            ),
                            child: const Icon(Icons.add_rounded,
                                size: 13, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ====================================================================
// COMPOSER
// ====================================================================

class StoryComposerScreen extends StatefulWidget {
  const StoryComposerScreen({super.key});

  @override
  State<StoryComposerScreen> createState() => _StoryComposerScreenState();
}

class _StoryComposerScreenState extends State<StoryComposerScreen> {
  static const List<List<Color>> _backgrounds = [
    [Color(0xFF7C3AED), Color(0xFFDB2777)],
    [Color(0xFF0EA5E9), Color(0xFF6366F1)],
    [Color(0xFFDB2777), Color(0xFFF59E0B)],
    [Color(0xFF059669), Color(0xFF0EA5E9)],
    [Color(0xFF6D28D9), Color(0xFF150C2E)],
    [Color(0xFFDC2626), Color(0xFF7C3AED)],
  ];

  final TextEditingController _text = TextEditingController();
  int _bg = 0;
  Uint8List? _image;

  // v0.1.11 — video story: picked bytes + metadata read from the
  // preview player. Setting one source clears the other.
  Uint8List? _video;
  String? _videoName;
  int? _videoDurationMs;
  int? _videoWidth;
  int? _videoHeight;
  VideoPlayerController? _previewCtrl;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _previewCtrl?.dispose();
    super.dispose();
  }

  void _clearMedia() {
    _previewCtrl?.dispose();
    _previewCtrl = null;
    _image = null;
    _video = null;
    _videoName = null;
    _videoDurationMs = null;
    _videoWidth = null;
    _videoHeight = null;
  }

  Future<void> _pickImage() async {
    HapticFeedback.selectionClick();
    try {
      final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery, maxWidth: 1440, imageQuality: 82);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() {
        _clearMedia();
        _image = bytes;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر اختيار الصورة')));
      }
    }
  }

  /// v0.1.11 — video story source: gallery pick or camera recording,
  /// capped at 60 seconds by the picker and 50MB by us (same budget
  /// as chat media; bigger videos are rejected with a clear message).
  Future<void> _pickVideo({required ImageSource source}) async {
    HapticFeedback.selectionClick();
    try {
      final picked = await ImagePicker().pickVideo(
        source: source,
        maxDuration: const Duration(seconds: 60),
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > AppConfig.mediaMaxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('الفيديو أكبر من 50 ميجابايت — اختر مقطعاً أقصر')));
        }
        return;
      }
      setState(() {
        _clearMedia();
        _video = bytes;
        _videoName = picked.name;
      });
      await _initPreview();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر اختيار الفيديو')));
      }
    }
  }

  Future<void> _showVideoSourceSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('فيديو من المعرض'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickVideo(source: ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded),
              title: const Text('تسجيل فيديو (حتى 60 ثانية)'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickVideo(source: ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Muted looped preview of the picked video; also captures duration
  /// and dimensions for the (encrypted) MediaInfo.
  Future<void> _initPreview() async {
    final v = _video;
    if (v == null) return;
    try {
      final dir = await Directory.systemTemp.createTemp('violet_story_pick');
      final file = File('${dir.path}/preview.mp4');
      await file.writeAsBytes(v, flush: true);
      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      await ctrl.setLooping(true);
      await ctrl.setVolume(0);
      unawaited(ctrl.play());
      setState(() {
        _previewCtrl = ctrl;
        _videoDurationMs = ctrl.value.duration.inMilliseconds;
        _videoWidth = ctrl.value.size.width.round();
        _videoHeight = ctrl.value.size.height.round();
      });
    } catch (_) {
      // Preview is cosmetic — publish still works without metadata.
    }
  }

  Future<void> _publish() async {
    if (_busy) return;
    final hasText = _text.text.trim().isNotEmpty;
    if (!hasText && _image == null && _video == null) return;
    setState(() => _busy = true);
    final ok = await context.read<StoriesController>().publish(
          text: hasText ? _text.text.trim() : null,
          imageBytes: _image,
          videoBytes: _video,
          videoMime: _video != null ? 'video/mp4' : null,
          videoName: _videoName,
          durationMs: _videoDurationMs,
          width: _videoWidth,
          height: _videoHeight,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.of(context).pop();
      Navigator.of(context).pushNamed('/stories/view');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر نشر الحالة — تحقق من الاتصال')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF150C2E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('حالة جديدة'),
        actions: [
          IconButton(
            tooltip: 'من المعرض',
            icon: const Icon(Icons.photo_library_rounded),
            onPressed: _busy ? null : _pickImage,
          ),
          IconButton(
            tooltip: 'فيديو',
            icon: const Icon(Icons.videocam_rounded),
            onPressed: _busy ? null : _showVideoSourceSheet,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(child: _canvas()),
                // background swatches — text mode only
                if (_image == null && _video == null)
                  SizedBox(
                    height: 56,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      children: [
                        for (var i = 0; i < _backgrounds.length; i++)
                          GestureDetector(
                            onTap: () => setState(() => _bg = i),
                            child: Container(
                              width: 36,
                              height: 36,
                              margin:
                                  const EdgeInsetsDirectional.only(end: 8),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                    colors: _backgrounds[i]),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _bg == i
                                      ? Colors.white
                                      : Colors.white24,
                                  width: _bg == i ? 2.5 : 1,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            maxLines: 2,
                            minLines: 1,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'اكتب حالتك…',
                              hintStyle:
                                  TextStyle(color: Colors.white54),
                              prefixIcon: _image != null
                                  ? const Icon(Icons.image_rounded,
                                      color: Colors.white54)
                                  : (_video != null
                                      ? const Icon(Icons.videocam_rounded,
                                          color: Colors.white54)
                                      : null),
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: 0.08),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(26),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: _publish,
                          borderRadius: BorderRadius.circular(28),
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              gradient: AppTheme.brandGradient,
                              shape: BoxShape.circle,
                              boxShadow: AppTheme.glow(
                                  color: AppTheme.brandPrimary,
                                  alpha: 0.4,
                                  blur: 14),
                            ),
                            child: const Icon(Icons.send_rounded,
                                color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _canvas() {
    if (_video != null) {
      final ctrl = _previewCtrl;
      if (ctrl != null && ctrl.value.isInitialized) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                Center(
                  child: AspectRatio(
                    aspectRatio: ctrl.value.aspectRatio == 0
                        ? 16 / 9
                        : ctrl.value.aspectRatio,
                    child: VideoPlayer(ctrl),
                  ),
                ),
                PositionedDirectional(
                  top: 10,
                  end: 10,
                  child: IconButton(
                    tooltip: 'إزالة الفيديو',
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white),
                    onPressed: () => setState(_clearMedia),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return const ColoredBox(
        color: Color(0xFF150C2E),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_rounded, color: Colors.white54, size: 42),
              SizedBox(height: 10),
              Text('جاري تجهيز المعاينة…',
                  style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
    }
    if (_image != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.memory(_image!,
              fit: BoxFit.cover, width: double.infinity),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: _backgrounds[_bg],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: TextField(
              controller: _text,
              maxLines: null,
              textAlign: TextAlign.center,
              autofocus: true,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  height: 1.5),
              decoration: const InputDecoration(
                hintText: 'ما الذي يحدث؟',
                hintStyle: TextStyle(color: Colors.white70, fontSize: 22),
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ====================================================================
// VIEWER
// ====================================================================

class StoryViewerScreen extends StatefulWidget {
  /// Initial author (null = start from the newest / my own).
  final String? authorId;

  const StoryViewerScreen({super.key, this.authorId});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  final PageController _page = PageController();
  Timer? _tick;
  double _progress = 0;
  bool _paused = false;
  bool _jumped = false;

  // v0.1.11 — video stories: each video page registers its player
  // keyed by story id. During page transitions two pages can be alive
  // at once — a plain single reference would race (the outgoing page's
  // dispose would clear the incoming page's controller), so the tick
  // always looks up the CURRENT story's controller instead.
  final Map<String, VideoPlayerController> _videoCtrls = {};

  VideoPlayerController? get _activeVideoCtrl {
    final cur = _current?.$2;
    return cur == null ? null : _videoCtrls[cur.id];
  }

  // v0.1.11 — reply to a friend's story, sent into the direct chat.
  final TextEditingController _replyCtrl = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  bool _replySending = false;

  bool get _replyActive => _replyFocus.hasFocus;
  bool get _effectivePaused => _paused || _replyActive;

  List<(String author, StoryItem story)> _flat(StoriesController s) {
    final out = <(String, StoryItem)>[];
    for (final id in s.authorOrder) {
      for (final st in s.byAuthor[id] ?? const <StoryItem>[]) {
        out.add((id, st));
      }
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _startTick();
    // Keyboard focus on the reply field pauses the story timer (and
    // the video through didUpdateWidget on the next rebuild).
    _replyFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _setVideoPaused(bool p) {
    final vc = _activeVideoCtrl;
    if (vc != null && vc.value.isInitialized) {
      try {
        if (p) {
          vc.pause();
        } else {
          vc.play();
        }
      } catch (_) {}
    }
  }

  /// v0.1.11 — send the typed reply into the direct chat with the
  /// story author (encrypted kind='storyReply' — see StoriesController).
  Future<void> _sendReply(StoriesController s, StoryItem story) async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty || _replySending) return;
    _replyCtrl.clear();
    _replyFocus.unfocus();
    setState(() => _replySending = true);
    final ok = await s.replyToStory(story, text);
    if (!mounted) return;
    setState(() => _replySending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'أُرسل ردك في المحادثة ✓' : 'تعذر إرسال الرد'),
    ));
  }

  void _jumpToInitial(List<(String, StoryItem)> flat) {
    if (_jumped) return;
    _jumped = true;
    if (widget.authorId == null || flat.isEmpty) return;
    final idx = flat.indexWhere((e) => e.$1 == widget.authorId);
    if (idx > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _page.hasClients) {
          _page.jumpToPage(idx);
          _progress = 0;
        }
      });
    }
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 60), (t) {
      if (!mounted || _effectivePaused) return;

      // v0.1.11 — video story: hold still until ITS player is ready
      // (download+decrypt can take longer than any fixed timer; a
      // timer here would skip the story), then follow the position.
      final cur = _current?.$2;
      final isVideo = cur?.content?.media?.type == 'video';
      final vc = _activeVideoCtrl;
      if (isVideo && (vc == null || !vc.value.isInitialized)) return;
      if (vc != null) {
        final dur = vc.value.duration.inMilliseconds;
        final pos = vc.value.position.inMilliseconds;
        if (dur > 0) {
          setState(() => _progress = pos / dur);
          if (!vc.value.isPlaying && pos >= dur - 60) {
            _progress = 0;
            _advance();
          }
        }
        return;
      }

      setState(() => _progress += 60 / _storyDurationMs);
      if (_progress >= 1) {
        _progress = 0;
        _advance();
      }
    });
  }

  double get _storyDurationMs =>
      _current?.$2.content?.media != null ? 7000 : 5500;

  (String, StoryItem)? get _current {
    final s = context.read<StoriesController>();
    final flat = _flat(s);
    if (flat.isEmpty) return null;
    final idx = _page.hasClients ? (_page.page ?? 0).round() : 0;
    if (idx >= flat.length) return null;
    return flat[idx];
  }

  void _advance() {
    final flat = _flat(context.read<StoriesController>());
    final idx = (_page.hasClients ? (_page.page ?? 0).round() : 0);
    if (idx + 1 < flat.length) {
      _page.nextPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut);
    } else {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  void _rewind() {
    final idx = (_page.hasClients ? (_page.page ?? 0).round() : 0);
    if (idx > 0) {
      _page.previousPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _page.dispose();
    // Controllers belong to their page widgets — the framework
    // disposes them; this only drops the registry.
    _videoCtrls.clear();
    _replyCtrl.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<StoriesController>();
    final flat = _flat(s);

    if (flat.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
            child: Text('لا حالات الآن',
                style: TextStyle(color: Colors.white70))),
      );
    }
    _jumpToInitial(flat);

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _page,
        builder: (context, _) {
          final idx = (_page.hasClients ? (_page.page ?? 0).round() : 0)
              .clamp(0, flat.length - 1);
          final entry = flat[idx];
          // mark viewed on arrival (post-frame to avoid build-phase
          // provider mutations)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              context.read<StoriesController>().markViewed(entry.$2);
            }
          });
          final authorGroup =
              flat.where((e) => e.$1 == entry.$1).toList();
          final segIdx = authorGroup.indexWhere((e) => e.$2.id == entry.$2.id);
          final profiles = s.profileCache;
          final isMineStory = entry.$1 == s.myId;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              // v0.1.11: the reply bar owns its taps — never advance
              // while the user is reaching for/using the reply field.
              if (!isMineStory) {
                if (_replyActive) return;
                final h = MediaQuery.of(context).size.height;
                if (d.globalPosition.dy > h - 110) return;
              }
              final w = MediaQuery.of(context).size.width;
              _progress = 0;
              if (d.globalPosition.dx > w / 2) {
                _advance();
              } else {
                _rewind();
              }
            },
            onLongPressStart: (_) {
              _paused = true;
              _setVideoPaused(true);
            },
            onLongPressEnd: (_) {
              if (!_replyActive) {
                _paused = false;
                _setVideoPaused(false);
              }
            },
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 120) {
                Navigator.of(context).maybePop();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ---------- content ----------
                _StoryBody(
                  story: entry.$2,
                  paused: _effectivePaused,
                  onVideoController: (storyId, c) {
                    if (c == null) {
                      _videoCtrls.remove(storyId);
                    } else {
                      _videoCtrls[storyId] = c;
                    }
                  },
                ),
                // ---------- top chrome ----------
                SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                        child: Row(
                          children: [
                            for (var i = 0; i < authorGroup.length; i++)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 2),
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: i < segIdx
                                          ? 1
                                          : i == segIdx
                                              ? _progress.clamp(0.0, 1.0)
                                              : 0,
                                      minHeight: 3,
                                      backgroundColor:
                                          Colors.white24,
                                      valueColor:
                                          const AlwaysStoppedAnimation(
                                              Colors.white),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            AvatarWidget(
                              profile: profiles[entry.$1],
                              label: profiles[entry.$1]?.title ?? '؟',
                              seedId: entry.$1,
                              radius: 17,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.$1 == s.myId
                                        ? 'حالتي'
                                        : (profiles[entry.$1]?.title ??
                                            'صديق'),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14),
                                  ),
                                  Text(
                                    SmartDate.listStamp(entry
                                        .$2.createdAtDate
                                        .toLocal()),
                                    style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.7),
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            if (entry.$1 == s.myId)
                              IconButton(
                                tooltip: 'حذف',
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.white),
                                onPressed: () => _confirmDelete(
                                    context, s, entry.$2),
                              ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded,
                                  color: Colors.white),
                              onPressed: () =>
                                  Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // ---------- bottom chrome ----------
                Align(
                  alignment: AlignmentDirectional.bottomCenter,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: entry.$1 == s.myId
                          ? InkWell(
                              borderRadius: BorderRadius.circular(22),
                              onTap: () => _showViewers(context, s, entry.$2),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(22),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.remove_red_eye_outlined,
                                        color: Colors.white, size: 17),
                                    SizedBox(width: 6),
                                    Text('المشاهدون',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            )
                          // v0.1.11 — reply bar: an encrypted reply
                          // lands in the direct chat with the author.
                          : Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _replyCtrl,
                                    focusNode: _replyFocus,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 14),
                                    textInputAction: TextInputAction.send,
                                    onSubmitted: (_) =>
                                        _sendReply(s, entry.$2),
                                    decoration: InputDecoration(
                                      hintText: 'أرسل رداً…',
                                      hintStyle: TextStyle(
                                          color: Colors.white
                                              .withValues(alpha: 0.5)),
                                      filled: true,
                                      fillColor: Colors.white
                                          .withValues(alpha: 0.10),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 10),
                                      border: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(24),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                InkWell(
                                  onTap: _replySending
                                      ? null
                                      : () => _sendReply(s, entry.$2),
                                  borderRadius: BorderRadius.circular(22),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      gradient: AppTheme.brandGradient,
                                      shape: BoxShape.circle,
                                      boxShadow: AppTheme.glow(
                                          color: AppTheme.brandPrimary,
                                          alpha: 0.35,
                                          blur: 10),
                                    ),
                                    child: _replySending
                                        ? const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white),
                                          )
                                        : const Icon(Icons.send_rounded,
                                            color: Colors.white, size: 20),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, StoriesController s, StoryItem story) {
    showDialog<void>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: const Text('حذف الحالة؟'),
        content:
            const Text('سيُحذف المحتوى المشفر نهائياً من الخادم لك وللجميع.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dlg).pop(),
              child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626)),
            onPressed: () {
              Navigator.of(dlg).pop();
              s.deleteStory(story);
              if (mounted) Navigator.of(context).maybePop();
            },
            child: const Text('حذف'),
          ),
        ],
      ),
    );
  }

  Future<void> _showViewers(
      BuildContext context, StoriesController s, StoryItem story) async {
    _paused = true;
    _setVideoPaused(true);
    final viewers = await s.myViewers();
    final ids = viewers[story.id]?.keys.toSet() ?? <String>{};
    final profiles = await s.profilesOf(ids);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF1D1140),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('المشاهدون',
                  textAlign: TextAlign.center,
                  style: Theme.of(sheetCtx).textTheme.titleMedium),
              const SizedBox(height: 10),
              if (ids.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text('لا مشاهدات بعد',
                      textAlign: TextAlign.center,
                      style: Theme.of(sheetCtx).textTheme.bodySmall),
                )
              else
                ...ids.map((id) => ListTile(
                      leading: AvatarWidget(
                        profile: profiles[id],
                        label: profiles[id]?.title ?? '؟',
                        seedId: id,
                        radius: 19,
                      ),
                      title: Text(profiles[id]?.title ?? 'صديق'),
                      subtitle: viewers[story.id]?[id] != null &&
                              viewers[story.id]![id]!.isNotEmpty
                          ? Text(SmartDate.listStamp(DateTime.tryParse(
                                      viewers[story.id]![id]!)
                                  ?.toLocal() ??
                              DateTime.now()))
                          : null,
                    )),
            ],
          ),
        ),
      ),
    );
    if (mounted) {
      _paused = false;
      if (!_replyActive) _setVideoPaused(false);
    }
  }
}

/// Decrypts and renders one story: video (v0.1.11), image full-bleed
/// (MediaService cache) or a colored text status. [paused] + the video
/// controller callback keep the viewer's progress ring in sync with
/// the actual playback instead of a fixed timer.
class _StoryBody extends StatelessWidget {
  final StoryItem story;
  final bool paused;
  final void Function(String storyId, VideoPlayerController?)
      onVideoController;

  const _StoryBody({
    required this.story,
    required this.paused,
    required this.onVideoController,
  });

  @override
  Widget build(BuildContext context) {
    final content = story.content;
    if (!story.decrypted || content == null) {
      return const ColoredBox(
        color: Color(0xFF150C2E),
        child: Center(
          child: Text('🔒 تعذر فك تشفير هذه الحالة بهذا الجهاز',
              style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    final media = content.media;
    if (media != null) {
      if (media.type == 'video') {
        return _VideoStoryBody(
          // Keyed by story id: paging to the next story tears the old
          // player down (dispose clears its registry entry) and builds
          // a fresh one for the new row.
          key: ValueKey('story-video-${story.id}'),
          media: media,
          caption: content.text,
          paused: paused,
          onController: (c) => onVideoController(story.id, c),
        );
      }
      return FutureBuilder<Uint8List?>(
        future: AppServices.I.mediaService.downloadDecrypted(
          path: media.path,
          fileKeyB64: media.fileKey,
          fileNonceB64: media.fileNonce,
        ),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const ColoredBox(
                color: Colors.black,
                child: Center(child: CircularProgressIndicator()));
          }
          if (snap.data == null) {
            return const ColoredBox(
              color: Colors.black,
              child: Center(
                  child: Text('تعذر تحميل الصورة',
                      style: TextStyle(color: Colors.white70))),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(snap.data!, fit: BoxFit.contain),
              if (content.text != null && content.text!.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.bottomCenter,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 90),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(content.text!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16)),
                  ),
                ),
            ],
          );
        },
      );
    }
    // Text status — same gradient family as the composer.
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF7C3AED), Color(0xFFDB2777)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            content.text ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                height: 1.5),
          ),
        ),
      ),
    );
  }
}

/// v0.1.11 — one encrypted video story: decrypt-once to a private temp
/// file (same pipeline as chat video), play with the OS player plugin.
/// Taps still belong to the viewer (advance/rewind); long-press and
/// the reply field pause playback through [paused]. Any failure shows
/// a graceful error instead of breaking the ring.
class _VideoStoryBody extends StatefulWidget {
  final MediaInfo media;
  final String? caption;
  final bool paused;
  final void Function(VideoPlayerController?) onController;

  const _VideoStoryBody({
    super.key,
    required this.media,
    required this.caption,
    required this.paused,
    required this.onController,
  });

  @override
  State<_VideoStoryBody> createState() => _VideoStoryBodyState();
}

class _VideoStoryBodyState extends State<_VideoStoryBody> {
  VideoPlayerController? _ctrl;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final m = widget.media;
      final bytes = await AppServices.I.mediaService.downloadDecrypted(
        path: m.path,
        fileKeyB64: m.fileKey,
        fileNonceB64: m.fileNonce,
      );
      final dir = await Directory.systemTemp.createTemp('violet_story_video');
      final file = File('${dir.path}/story.mp4');
      await file.writeAsBytes(bytes, flush: true);
      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      widget.onController(ctrl);
      setState(() => _ctrl = ctrl);
      if (!widget.paused) {
        unawaited(ctrl.play());
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(_VideoStoryBody old) {
    super.didUpdateWidget(old);
    if (widget.paused != old.paused) {
      final c = _ctrl;
      if (c != null && c.value.isInitialized) {
        try {
          if (widget.paused) {
            c.pause();
          } else {
            c.play();
          }
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    widget.onController(null);
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text('تعذر تشغيل الفيديو',
              style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio:
                  ctrl.value.aspectRatio == 0 ? 16 / 9 : ctrl.value.aspectRatio,
              child: VideoPlayer(ctrl),
            ),
          ),
          if (widget.caption != null && widget.caption!.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.bottomCenter,
              child: Container(
                margin: const EdgeInsets.only(bottom: 90),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(widget.caption!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
        ],
      ),
    );
  }
}
