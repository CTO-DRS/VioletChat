import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../theme/app_theme.dart';
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
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    HapticFeedback.selectionClick();
    try {
      final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery, maxWidth: 1440, imageQuality: 82);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() => _image = bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر اختيار الصورة')));
      }
    }
  }

  Future<void> _publish() async {
    if (_busy) return;
    final hasText = _text.text.trim().isNotEmpty;
    if (!hasText && _image == null) return;
    setState(() => _busy = true);
    final ok = await context.read<StoriesController>().publish(
          text: hasText ? _text.text.trim() : null,
          imageBytes: _image,
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
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(child: _canvas()),
                // background swatches — text mode only
                if (_image == null)
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
                                  : null,
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
      if (!mounted || _paused) return;
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

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final w = MediaQuery.of(context).size.width;
              _progress = 0;
              if (d.globalPosition.dx > w / 2) {
                _advance();
              } else {
                _rewind();
              }
            },
            onLongPressStart: (_) => _paused = true,
            onLongPressEnd: (_) => _paused = false,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 120) {
                Navigator.of(context).maybePop();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ---------- content ----------
                _StoryBody(story: entry.$2),
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
                      child: Row(
                        children: [
                          if (entry.$1 == s.myId)
                            InkWell(
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
                          else
                            const SizedBox.shrink(),
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
    if (mounted) _paused = false;
  }
}

/// Decrypts and renders one story: image full-bleed (MediaService
/// cache) or a colored text status.
class _StoryBody extends StatelessWidget {
  final StoryItem story;

  const _StoryBody({required this.story});

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
