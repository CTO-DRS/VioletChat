import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
// `show DateFormat` is load-bearing: intl also exports TextDirection,
// which would shadow dart:ui's TextDirection (needed for RTL flips).
import 'package:intl/intl.dart' show DateFormat;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/storage/local_database.dart';
import '../../core/utils/disappearing_policy.dart';
import '../../core/utils/smart_date.dart';
import '../../data/models/models.dart';
import '../../routing/app_router.dart';
import '../../services/chat_export_service.dart';
import '../../state/app_services.dart';
import '../../state/chat_controller.dart';
import '../../state/chats_controller.dart';
import '../../state/settings_controller.dart';
import '../../theme/app_theme.dart';
import 'poll_widgets.dart';
import '../../widgets/brand.dart';
import '../../widgets/verified_badge.dart';
import '../../widgets/swipe_to_reply.dart';

/// شاشة المحادثة — رسائل مشفرة طرف-لطرف، RTL بالكامل.
class ChatScreen extends StatefulWidget {
  final Chat chat;
  const ChatScreen({super.key, required this.chat});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // v0.1.0: moved to AppTheme.brandGradient — single source of truth.
  static const List<String> _emojis = ['👍', '❤️', '😂', '😮', '😢', '🎉'];

  /// v0.1.9 — حجم خط نص الرسائل من الإعدادات (المظهر ← حجم خط المحادثة).
  /// watch: تغيير الشريط يعيد بناء الفقاعات فوراً — معاينة حقيقية.
  int get _chatFont =>
      context.watch<SettingsController>().settings.chatFontSize;

  late final AppServices _services;
  ChatController? _controller;
  final _scroll = ScrollController();
  final _textCtrl = TextEditingController();
  final _picker = ImagePicker();
  AudioRecorder? _recorder;

  DateTime? _lastTypingAt;
  bool _uploading = false;
  bool _recording = false;
  bool _didInitialJump = false;
  bool _loadingOlderLocally = false;

  // v0.1.0: per-chat draft persistence (encrypted, local only).
  Timer? _draftTimer;
  // v0.1.0: tap-to-jump on reply quotes + flash highlight.
  final Map<String, GlobalKey> _tileKeys = {};
  String? _highlightId;
  Timer? _highlightTimer;

  List<ChatMember> _members = [];
  final Map<String, Profile> _memberMap = {};

  String? _recordingPath;
  final Stopwatch _recSw = Stopwatch();
  Timer? _recTimer;

  ChatController get _c => _controller!;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    final controller = ChatController(_services, widget.chat);
    _controller = controller;
    unawaited(controller.start());
    _scroll.addListener(_onScroll);
    _loadMembers();
    _restoreDraft();
  }

  Future<void> _restoreDraft() async {
    try {
      final blob = await LocalDatabase.kvGet(_draftKey);
      if (blob == null || !mounted) return;
      final text = (await LocalDatabase.openJson(blob))?['t'] as String? ?? '';
      if (text.isNotEmpty && _textCtrl.text.isEmpty) {
        _textCtrl.text = text;
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Drafts are a nicety — never block the chat on them.
    }
  }

  String get _draftKey => 'draft:${widget.chat.id}';

  Future<void> _saveDraft() async {
    final text = _textCtrl.text.trim();
    try {
      if (text.isEmpty) {
        await LocalDatabase.kvRemove(_draftKey);
      } else {
        await LocalDatabase.kvSet(
            _draftKey, await LocalDatabase.sealJson({'t': text}));
      }
    } catch (_) {}
  }

  Future<void> _loadMembers() async {
    if (!widget.chat.isGroup) return;
    try {
      final members = await _services.chats.loadMembers(widget.chat.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _memberMap.clear();
        for (final m in members) {
          _memberMap[m.profile.id] = m.profile;
        }
      });
    } catch (_) {
      // Members list is a nice-to-have; the chat still works without it.
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _highlightTimer?.cancel();
    if (_textCtrl.text.trim().isNotEmpty) {
      // Flush a pending draft synchronously best-effort — ignore errors
      // (the async gap is unavoidable in dispose).
      unawaited(_saveDraft());
    }
    _recTimer?.cancel();
    _recSw.stop();
    _recorder?.dispose();
    _textCtrl.dispose();
    _scroll.dispose();
    _controller?.dispose();
    super.dispose();
  }

  // ===================================================================
  // Pagination (infinite scroll near the top)
  // ===================================================================
  Future<void> _onScroll() async {
    final c = _controller;
    if (c == null || _loadingOlderLocally) return;
    if (c.loadingOlder || c.noMoreOlder) return;
    if (c.messages.length < AppConfig.pageSize) return;
    if (!_scroll.hasClients || _scroll.position.pixels > 320) return;

    _loadingOlderLocally = true;
    final oldMax = _scroll.position.maxScrollExtent;
    final oldOffset = _scroll.offset;
    await c.loadOlder();
    _loadingOlderLocally = false;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final delta = _scroll.position.maxScrollExtent - oldMax;
      if (delta > 0) {
        _scroll.jumpTo(
          (oldOffset + delta)
              .clamp(0.0, _scroll.position.maxScrollExtent)
              .toDouble(),
        );
      }
    });
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent > 0) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ===================================================================
  // Sending — text / typing
  // ===================================================================
  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    // v0.1.0: light tactile pulse on send.
    HapticFeedback.lightImpact();
    _draftTimer?.cancel();
    _textCtrl.clear();
    unawaited(_saveDraft()); // clear the stored draft too
    setState(() {});
    try {
      await _c.sendText(text);
      _jumpToBottom();
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('تعذر إرسال الرسالة — ستعاد المحاولة تلقائياً');
    }
  }

  void _onTextChanged(String v) {
    setState(() {});
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 900), () {
      unawaited(_saveDraft());
    });
    final now = DateTime.now();
    if (_lastTypingAt == null ||
        now.difference(_lastTypingAt!).inMilliseconds >= 2000) {
      _lastTypingAt = now;
      _c.onTyping();
    }
  }

  // ===================================================================
  // Media — pick / upload
  // ===================================================================
  Future<void> _sendImage(ImageSource source) async {
    Navigator.of(context).pop();
    try {
      final x = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 72,
      );
      if (x == null) return;
      setState(() => _uploading = true);
      final bytes = await x.readAsBytes();
      _checkSize(bytes.length);

      int? w;
      int? h;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        w = frame.image.width;
        h = frame.image.height;
        frame.image.dispose();
        codec.dispose();
      } catch (_) {
        // Dimensions are optional metadata.
      }

      final result = await _services.mediaService.uploadMedia(
        chatId: widget.chat.id,
        type: 'image',
        bytes: bytes,
        originalName: x.name,
        mime: x.mimeType ?? 'image/jpeg',
        width: w,
        height: h,
      );
      await _c.sendMedia(result);
      _jumpToBottom();
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('تعذر إرسال الصورة');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _sendFile() async {
    Navigator.of(context).pop();
    try {
      final picked = await FilePicker.platform.pickFiles();
      final f = picked?.files.single;
      if (f == null || f.path == null) return;
      setState(() => _uploading = true);
      final bytes = await File(f.path!).readAsBytes();
      _checkSize(bytes.length);

      final result = await _services.mediaService.uploadMedia(
        chatId: widget.chat.id,
        type: 'file',
        bytes: bytes,
        originalName: f.name,
        mime: 'application/octet-stream',
      );
      await _c.sendMedia(result);
      _jumpToBottom();
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('تعذر إرسال الملف');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _checkSize(int bytesLength) {
    if (bytesLength > AppConfig.mediaMaxBytes) {
      throw AppException.validation(
          'الملف أكبر من الحد المسموح (${_fmtSize(AppConfig.mediaMaxBytes)})');
    }
  }

  // ===================================================================
  // Voice recording
  // ===================================================================
  Future<void> _startRecording() async {
    final rec = _recorder ??= AudioRecorder();
    try {
      final ok = await rec.hasPermission();
      if (!ok) {
        _err('إذن الميكروفون مطلوب للتسجيل الصوتي');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );
      _recordingPath = path;
      _recSw
        ..reset()
        ..start();
      // v0.1.0: confirm recording start with a double tick.
      HapticFeedback.mediumImpact();
      setState(() => _recording = true);
      _recTimer?.cancel();
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (_recSw.elapsed.inSeconds >= 180) {
          _stopRecording(send: true);
        }
      });
    } catch (_) {
      _err('تعذر بدء التسجيل');
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _recTimer?.cancel();
    _recSw.stop();
    final path = _recordingPath;
    _recordingPath = null;
    setState(() => _recording = false);

    final rec = _recorder;
    String? saved;
    try {
      saved = await rec?.stop();
    } catch (_) {}
    if (!send) {
      if (path != null) _deleteQuietly(path);
      if (saved != null && saved != path) _deleteQuietly(saved);
      return;
    }
    if (saved == null) {
      _err('تعذر حفظ التسجيل');
      return;
    }
    try {
      final bytes = await File(saved).readAsBytes();
      _checkSize(bytes.length);
      final result = await _services.mediaService.uploadMedia(
        chatId: widget.chat.id,
        type: 'audio',
        bytes: bytes,
        originalName: 'رسالة صوتية',
        mime: 'audio/mp4',
        durationMs: _recSw.elapsedMilliseconds,
      );
      await _c.sendMedia(result);
      _jumpToBottom();
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('تعذر إرسال التسجيل الصوتي');
    } finally {
      _deleteQuietly(saved);
    }
  }

  void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ===================================================================
  // Calls (1-to-1 only — group calls are NOT implemented)
  // ===================================================================
  void _showCallSheet() {
    final peer = widget.chat.peer;
    if (peer == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call),
              title: const Text('مكالمة صوتية'),
              subtitle: Text(peer.title),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openCall(video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('مكالمة فيديو'),
              subtitle: Text(peer.title),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openCall(video: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCall({required bool video}) async {
    if (!AppConfig.enableCalls || widget.chat.peer == null) return;
    await Navigator.pushNamed(
      context,
      AppRoutes.call,
      arguments: CallRouteArgs(widget.chat, true, video),
    );
  }

  // ===================================================================
  // Group calls (v0.1.0 — real WebRTC mesh)
  // ===================================================================
  void _showGroupCallSheet() {
    final others = _members.map((m) => m.profile.id).toSet().toList();
    if (others.isEmpty) {
      _snack('تعذر قراءة أعضاء المجموعة — حاول مجدداً');
      return;
    }
    if (others.length + 1 > AppConfig.groupCallMaxPeers) {
      _snack(
          'المكالمات الجماعية تدعم حتى ${AppConfig.groupCallMaxPeers} مشاركين — هذه المجموعة أكبر');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call),
              title: const Text('مكالمة جماعية صوتية'),
              subtitle: Text('${_members.length} أعضاء'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openGroupCall(video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('مكالمة جماعية فيديو'),
              subtitle: Text('${_members.length} أعضاء'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openGroupCall(video: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGroupCall({required bool video}) async {
    if (!AppConfig.enableGroupCalls || !widget.chat.isGroup) return;
    await Navigator.pushNamed(
      context,
      AppRoutes.groupCall,
      arguments: GroupCallRouteArgs(
        widget.chat,
        outgoing: true,
        video: video,
        memberIds: _members.map((m) => m.profile.id).toList(),
      ),
    );
  }

  // ===================================================================
  // Forward (v0.1.0)
  // ===================================================================
  bool _canForward(Message m) =>
      !m.isDeletedForAll &&
      ((m.kind == 'text' && (m.text ?? '').trim().isNotEmpty) ||
          m.media != null);

  Future<void> _forwardMessage(Message m) async {
    final chats = context.read<ChatsController>().chats;
    final target = await showModalBottomSheet<Chat>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetCtx).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('إعادة توجيه إلى...',
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              Expanded(
                child: chats.isEmpty
                    ? const Center(child: Text('لا توجد محادثات'))
                    : ListView.builder(
                        itemCount: chats.length,
                        itemBuilder: (ctx, i) {
                          final c = chats[i];
                          return ListTile(
                            leading: AvatarWidget(
                              label: c.title,
                              seedId: c.isGroup ? c.id : (c.peer?.id ?? c.id),
                              radius: 20,
                            ),
                            title: Text(c.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.pop(sheetCtx, c),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    if (target == null || !mounted) return;
    if (target.id == widget.chat.id) {
      _snack('الرسالة موجودة أصلاً في هذه المحادثة');
      return;
    }
    try {
      if (m.kind == 'text' && (m.text ?? '').trim().isNotEmpty) {
        await _services.sync.enqueueText(target, m.text!.trim(),
            forwardedFrom: m.id);
      } else if (m.media != null) {
        final info = m.media!;
        final bytes = await _services.mediaService.downloadDecrypted(
          path: info.path,
          fileKeyB64: info.fileKey,
          fileNonceB64: info.fileNonce,
        );
        final result = await _services.mediaService.uploadMedia(
          chatId: target.id,
          type: info.type,
          bytes: bytes,
          originalName: info.name,
          mime: info.mime,
          width: info.width,
          height: info.height,
          durationMs: info.durationMs,
        );
        await _services.sync.enqueueMedia(target, result.toMediaInfo(),
            forwardedFrom: m.id);
      } else {
        _snack('لا يمكن إعادة توجيه هذه الرسالة');
        return;
      }
      _snack('تمت إعادة التوجيه إلى ${target.title}');
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('تعذر إعادة توجيه الرسالة');
    }
  }

  // ===================================================================
  // Jump to quoted message (v0.1.0)
  // ===================================================================
  Future<void> _jumpToMessage(String? id) async {
    if (id == null || id.isEmpty) return;
    // If the quoted message is deeper in history, page up until it is
    // loaded (bounded — honest stop when the cache is exhausted).
    var guard = 0;
    while (
        !_c.messages.any((m) => m.id == id) && !_c.noMoreOlder && guard < 40) {
      guard++;
      await _c.loadOlder();
    }
    if (!mounted) return;
    if (!_c.messages.any((m) => m.id == id)) {
      _snack('الرسالة الأصلية غير متاحة في السجل');
      return;
    }
    final key = _tileKeys[id];
    final ctx = key?.currentContext;
    if (ctx == null || !ctx.mounted) {
      _snack('تعذر الانتقال — أعد المحاولة');
      return;
    }
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      alignment: 0.35,
    );
    _highlightTimer?.cancel();
    setState(() => _highlightId = id);
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  // ===================================================================
  // Long-press actions
  // ===================================================================
  void _msgSheet(Message m) {
    final c = _c;
    final mine = m.senderId == c.myId;
    final hasText = (m.text ?? '').trim().isNotEmpty && !m.isDeletedForAll;
    final canEdit = mine && m.kind == 'text' && hasText;

    // v0.1.0: medium tactile thump announcing the long-press sheet.
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final emoji in _emojis)
                  IconButton(
                    tooltip: 'تفاعل $emoji',
                    onPressed: () {
                      // v0.1.0: selection tick on reaction pick.
                      HapticFeedback.selectionClick();
                      Navigator.pop(sheetCtx);
                      c.toggleReaction(m, emoji);
                    },
                    icon: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
              ],
            ),
            const Divider(height: 1),
            _sheetTile(Icons.reply, 'رد', () {
              Navigator.pop(sheetCtx);
              c.startReply(m);
            }),
            if (hasText)
              _sheetTile(Icons.content_copy, 'نسخ', () {
                Navigator.pop(sheetCtx);
                Clipboard.setData(ClipboardData(text: m.text ?? ''));
                _snack('تم نسخ الرسالة');
              }),
            if (_canForward(m))
              _sheetTile(Icons.shortcut, 'إعادة توجيه', () {
                Navigator.pop(sheetCtx);
                _forwardMessage(m);
              }),
            if (canEdit)
              _sheetTile(Icons.edit, 'تعديل', () {
                Navigator.pop(sheetCtx);
                _editMessage(m);
              }),
            _sheetTile(Icons.push_pin, 'تثبيت', () {
              Navigator.pop(sheetCtx);
              c.togglePin(m);
              _snack('تم تثبيت الرسالة');
            }),
            // v0.1.0: star / unstar — drives «الرسائل المحفوظة».
            _sheetTile(
                m.starred
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined,
                m.starred ? 'إلغاء الحفظ' : 'حفظ الرسالة', () {
              Navigator.pop(sheetCtx);
              c.toggleStar(m);
              _snack(m.starred
                  ? 'أُزيلت من الرسائل المحفوظة'
                  : 'حُفظت في «الرسائل المحفوظة»');
            }),
            if (mine)
              _sheetTile(Icons.info_outline, 'معلومات', () {
                Navigator.pop(sheetCtx);
                _receiptsDialog(m);
              }),
            _sheetTile(Icons.delete_outline, 'حذف عندي', () {
              Navigator.pop(sheetCtx);
              c.deleteForMe(m);
            }, danger: true),
            if (mine && !m.isDeletedForAll)
              _sheetTile(Icons.delete_forever, 'حذف عند الجميع', () {
                Navigator.pop(sheetCtx);
                _confirmDeleteForAll(m);
              }, danger: true),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteForAll(Message m) {
    showDialog<void>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('حذف عند الجميع'),
        content: const Text(
            'سيتم حذف هذه الرسالة عند كل أعضاء المحادثة. لا يمكن التراجع.',
            textAlign: TextAlign.right),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
              minimumSize: const Size(120, 44),
            ),
            onPressed: () {
              Navigator.pop(dlgCtx);
              _c.deleteForEveryone(m);
            },
            child: const Text('حذف'),
          ),
        ],
      ),
    );
  }

  Future<void> _editMessage(Message m) async {
    final ctrl = TextEditingController(text: m.text ?? '');
    final newText = await showDialog<String>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('تعديل الرسالة'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'النص الجديد'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, ctrl.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == m.text) return;
    try {
      await _c.editMessage(m, newText);
    } catch (_) {
      _err('تعذر تعديل الرسالة');
    }
  }

  void _receiptsDialog(Message m) {
    final receipts = _c.receiptsByMsg[m.id] ?? const <Receipt>[];
    final df = DateFormat('d/M HH:mm');
    showDialog<void>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('حالة الرسالة'),
        content: SizedBox(
          width: 320,
          child: receipts.isEmpty
              ? const Text('لم يستلم أحد هذه الرسالة بعد',
                  textAlign: TextAlign.right)
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: receipts.length,
                  itemBuilder: (ctx, i) {
                    final r = receipts[i];
                    // v0.1.9: في الثنائية لا خريطة أعضاء — الطرف واحد معلوم.
                    final name = _memberMap[r.userId]?.title ??
                        (_c.isGroup ? 'عضو' : 'الطرف الآخر');
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        r.readAt != null ? Icons.done_all : Icons.done_all,
                        size: 20,
                        color: r.readAt != null
                            ? AppTheme.tickColor(true)
                            : AppTheme.tickColor(false),
                      ),
                      title: Text(name, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                        r.readAt != null
                            ? 'قُرئت: ${df.format(DateTime.parse(r.readAt!).toLocal())}'
                            : (r.deliveredAt != null
                                ? 'وصلت: ${df.format(DateTime.parse(r.deliveredAt!).toLocal())}'
                                : 'مُرسلة — بانتظار الوصول'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // Small helpers
  // ===================================================================
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _err(String msg) => _snack(msg);

  static String _fmtSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _fmtClock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ===================================================================
  // Build
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: _appBar(),
        body: Column(
          children: [
            _pinnedBanner(),
            _disappearBanner(),
            Expanded(child: _messagesList()),
            _newBelowChip(),
            _composer(),
          ],
        ),
      ),
    );
  }

  /// v0.1.0: pinned-message banner under the AppBar — tap jumps to the
  /// message with the highlight flash; the pin icon shows only when
  /// the viewer is the message's sender (pinning is sender-only
  /// server-side, so only the pinner can unpin).
  Widget _pinnedBanner() {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final m = _c.pinnedMessage;
        if (m == null || m.isDeletedForAll) {
          return const SizedBox(width: double.infinity);
        }
        final preview = (m.text != null && m.text!.trim().isNotEmpty)
            ? m.text!
            : switch (m.media?.type) {
                'image' => '📷 صورة',
                'audio' => '🎤 رسالة صوتية',
                'video' => '🎬 فيديو',
                _ => '📎 ملف',
              };
        final mine = m.senderId == _c.myId;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () => _jumpToMessage(m.id),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets
                  .fromLTRB(12, 7, 12, 7),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: AppTheme.brandPrimary.withValues(alpha: 0.35),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                textDirection: ui.TextDirection.rtl,
                children: [
                  const Icon(Icons.push_pin_rounded,
                      size: 16, color: AppTheme.brandSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (mine)
                    GestureDetector(
                      onTap: () => _c.unpinPinned(),
                      child: const Padding(
                        padding: EdgeInsetsDirectional.only(start: 8),
                        child: Icon(Icons.close_rounded,
                            size: 18, color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// v0.1.0: disappearing-messages banner — visible while the chat has
  /// a TTL active (mirrors controller state; optimistic on change).
  Widget _disappearBanner() {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final ttl = _c.disappearTtl;
        if (ttl == null || ttl <= 0) {
          return const SizedBox(width: double.infinity);
        }
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: _showDisappearSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: AppTheme.brandPrimary.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                textDirection: ui.TextDirection.rtl,
                children: [
                  const Icon(Icons.timer_outlined,
                      size: 15, color: AppTheme.brandSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'الرسائل المؤقتة مفعّلة — تختفي بعد ${DisappearingPolicy.label(ttl)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// v0.1.0: disappearing-messages TTL picker (member-level, same
  /// trust level as set_chat_flags). null = OFF. The server stamps
  /// each NEW message at insert; already-sent messages keep the expiry
  /// they were stamped with (WhatsApp-like semantics).
  void _showDisappearSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            const Text('الرسائل المؤقتة',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Text(
                'الرسائل الجديدة تُحذف تلقائياً بعد المدة المحددة عند الجميع. الرسائل السابقة لا تتأثر.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
            // v0.1.0: RadioGroup<int> with a -1 OFF sentinel — the
            // post-3.32 radio API routes changes through the group;
            // inner tiles carry only `value`.
            RadioGroup<int>(
              groupValue: _c.disappearTtl ?? -1,
              onChanged: (v) {
                Navigator.pop(sheetCtx);
                _c.setDisappearTtl(v == null || v < 0 ? null : v);
                _snack(v == null || v < 0
                    ? 'أُوقفت الرسائل المؤقتة'
                    : 'ستختفي الرسائل الجديدة بعد ${DisappearingPolicy.label(v)}');
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<int>(
                      value: -1, title: Text('إيقاف')),
                  for (final t in DisappearingPolicy.ttlChoices)
                    RadioListTile<int>(
                        value: t,
                        title: Text(DisappearingPolicy.label(t))),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// v0.1.0: export the LOCALLY-CACHED transcript as a .txt via the
  /// system share sheet. Media becomes a placeholder line — blobs stay
  /// on-device (documented boundary, see ChatExportService).
  Future<void> _exportChat() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('تصدير المحادثة'),
        content: const Text(
            'سيتم إنشاء ملف نصي بالرسائل المخزّنة على هذا الجهاز ومشاركته عبر تطبيقاتك. الوسائط تظهر كوصف فقط. هل تريد المتابعة؟',
            textAlign: TextAlign.right),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('تصدير'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      final msgs = await _services.cache.allForChat(widget.chat.id);
      String nameOf(String senderId) {
        if (senderId == _c.myId) return 'أنا';
        final member = _memberMap[senderId];
        if (member != null) return member.title;
        return widget.chat.peer?.title ?? 'عضو';
      }

      final transcript = ChatExportService.buildTranscript(
        title: widget.chat.title,
        messages: msgs,
        nameOf: nameOf,
      );
      await ChatExportService.shareTranscript(
        title: widget.chat.title,
        safeFileName: widget.chat.id,
        transcript: transcript,
      );
    } catch (_) {
      _err('تعذر إنشاء ملف التصدير');
    }
  }

  PreferredSizeWidget _appBar() {
    final c = _controller;
    final typing = c?.typingUserId != null;
    // Honest subtitle: 'متصل الآن' only when the server reports a
    // fresh heartbeat for the peer (privacy settings honoured
    // server-side). Otherwise — v0.1.0 — the peer's last-seen stamp
    // when the server exposes one (same privacy rules, 30-day window).
    // Anything else stays empty — we never claim a status we cannot
    // verify.
    final lastSeen = c?.peerLastSeen;
    final subtitle = typing
        ? 'يكتب الآن...'
        : (widget.chat.isGroup
            ? '${_members.length} أعضاء'
            : (c?.peerOnline == true
                ? 'متصل الآن'
                : (lastSeen != null
                    ? SmartDate.lastSeen(lastSeen.toLocal())
                    : '')));
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_forward),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      titleSpacing: 0,
      title: InkWell(
        onTap: widget.chat.isGroup
            ? () => Navigator.pushNamed(context, AppRoutes.groupInfo,
                arguments: widget.chat)
            : null,
        child: Row(
          children: [
            AvatarWidget(
              label: widget.chat.title,
              seedId: widget.chat.isGroup
                  ? widget.chat.id
                  : (widget.chat.peer?.id ?? widget.chat.id),
              radius: 19,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // v0.1.1: verification badge for verified peers
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 17),
                        ),
                      ),
                      if (!widget.chat.isGroup &&
                          (widget.chat.peer?.isVerified ?? false)) ...[
                        const SizedBox(width: 3),
                        const VerifiedBadge(size: 16),
                      ],
                    ],
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      subtitle,
                      key: ValueKey<String>(subtitle),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        color: typing
                            ? AppTheme.brandSecondary
                            : Theme.of(context).textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (AppConfig.enableCalls && !widget.chat.isGroup)
          IconButton(
            tooltip: 'مكالمة',
            icon: const Icon(Icons.call),
            onPressed: _showCallSheet,
          ),
        // v0.1.0: real group calls (WebRTC mesh) from the chat bar.
        if (AppConfig.enableGroupCalls && widget.chat.isGroup)
          IconButton(
            tooltip: 'مكالمة جماعية',
            icon: const Icon(Icons.groups),
            onPressed: _showGroupCallSheet,
          ),
        if (widget.chat.isGroup)
          IconButton(
            tooltip: 'معلومات المجموعة',
            icon: const Icon(Icons.group),
            onPressed: () => Navigator.pushNamed(context, AppRoutes.groupInfo,
                arguments: widget.chat),
          ),
        // v0.1.0: chat tools — media gallery / export / disappearing TTL.
        PopupMenuButton<String>(
          tooltip: 'خيارات المحادثة',
          icon: const Icon(Icons.more_vert),
          onSelected: (v) {
            if (v == 'media') {
              Navigator.pushNamed(context, AppRoutes.mediaGallery,
                  arguments: widget.chat);
            } else if (v == 'export') {
              unawaited(_exportChat());
            } else if (v == 'ttl') {
              _showDisappearSheet();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'media',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.photo_library_outlined),
                title: Text('وسائط المحادثة'),
              ),
            ),
            PopupMenuItem(
              value: 'export',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.ios_share),
                title: Text('تصدير المحادثة'),
              ),
            ),
            PopupMenuItem(
              value: 'ttl',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.timer_outlined),
                title: Text('الرسائل المؤقتة'),
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _messagesList() {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final msgs = _c.chatMessages;
        if (msgs.isEmpty) {
          return _emptyState();
        }
        if (!_didInitialJump) {
          _didInitialJump = true;
          _jumpToBottom();
        }
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsetsDirectional.only(
              start: 10, end: 10, top: 8, bottom: 10),
          itemCount: msgs.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              if (_c.loadingOlder) {
                return const Padding(
                  padding: EdgeInsets.all(10),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            }
            final m = msgs[i - 1];
            final prev = i > 1 ? msgs[i - 2] : null;
            return _buildItem(m, prev);
          },
        );
      },
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline,
                size: 46, color: AppTheme.brandSecondary),
            const SizedBox(height: 14),
            Text(
              'ابدأ المحادثة',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 18),
            ),
            const SizedBox(height: 6),
            Text(
              'رسائلك مشفرة طرف-لطرف',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(Message m, Message? prev) {
    // Date divider when the day changes — AND on the very first message
    // (v0.1.0 fix: previously the first message never got a separator,
    // so a fresh conversation had no «اليوم» pill at all).
    if (prev == null || !_sameDay(prev.createdAt, m.createdAt)) {
      return Column(
        children: [
          _dateDivider(m.createdAt),
          _messageTile(m),
        ],
      );
    }
    return _messageTile(m);
  }

  bool _sameDay(String aIso, String bIso) {
    final a = DateTime.tryParse(aIso)?.toLocal();
    final b = DateTime.tryParse(bIso)?.toLocal();
    if (a == null || b == null) return true;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Widget _dateDivider(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return const SizedBox.shrink();
    // v0.1.0: shared SmartDate wording (اليوم / أمس / d/M / d/M/y)
    // — same stamps as the chats list, one source of truth.
    final label = SmartDate.dayLabel(d);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).textTheme.bodyMedium?.color)),
      ),
    );
  }

  Widget _messageTile(Message m) {
    if (m.kind == 'system') return _systemPill(m);
    final mine = m.senderId == _c.myId;
    final reactions = _c.reactionsByMsg[m.id] ?? const <Reaction>[];

    final bubble = m.kind == AppConstants.kindPoll
        ? PollBubble(
            pollMsg: m,
            mine: mine,
            chatMessages: _c.messages,
            myId: _c.myId,
            font: _chatFont.toDouble(),
            onVote: (i) => _c.castVote(m, i),
          )
        : _bubble(m, mine);
    final highlighted = _highlightId == m.id;
    // v0.1.0: key registry for tap-to-jump on reply quotes + flash.
    final key = _tileKeys.putIfAbsent(m.id, GlobalKey.new);
    if (_tileKeys.length > 500) _tileKeys.clear();
    return KeyedSubtree(
      key: key,
      child: Container(
        decoration: BoxDecoration(
          color: highlighted
              ? AppTheme.brandPrimary.withValues(alpha: 0.14)
              : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Align(
            alignment: mine
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // v0.1.0: swipe-to-reply — both physical directions
                // trigger so the RTL layout needs no special casing.
                if (!m.isDeletedForAll)
                  SwipeToReply(
                    onReply: () => _c.startReply(m),
                    child: bubble,
                  )
                else
                  bubble,
                if (reactions.isNotEmpty) _reactionsRow(m, reactions, mine),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _systemPill(Message m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: AlignmentDirectional.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            m.text ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(Message m, bool mine) {
    const radius = 18.0;
    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onLongPress: m.isDeletedForAll ? null : () => _msgSheet(m),
      onTap: () => _onBubbleTap(m),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding:
            EdgeInsets.fromLTRB(12, m.media?.type == 'image' ? 5 : 9, 12, 7),
        decoration: BoxDecoration(
          gradient: mine ? AppTheme.brandGradient : null,
          color: mine
              ? null
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadiusDirectional.only(
            topStart: const Radius.circular(radius),
            topEnd: const Radius.circular(radius),
            bottomStart: Radius.circular(mine ? radius : 5),
            bottomEnd: Radius.circular(mine ? 5 : radius),
          ),
          // v0.1.2: neon halo behind my messages (mockup glow language).
          boxShadow: mine
              ? AppTheme.glow(
                  color: AppTheme.brandPrimary, alpha: 0.28, blur: 14)
              : null,
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine && _c.isGroup)
              Padding(
                padding: const EdgeInsetsDirectional.only(bottom: 3),
                child: Text(
                  _memberMap[m.senderId]?.title ?? 'عضو',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.brandSecondary,
                  ),
                ),
              ),
            // v0.1.0: forward attribution — the chip reads «مُعاد
            // توجيهه» whenever the row carries forwarded_from.
            if (m.forwardedFrom != null && !m.isDeletedForAll)
              Padding(
                padding: const EdgeInsetsDirectional.only(bottom: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shortcut_rounded,
                        size: 13,
                        color: mine
                            ? Colors.white70
                            : Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color),
                    const SizedBox(width: 3),
                    Text(
                      'مُعاد توجيهه',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: mine
                            ? Colors.white70
                            : Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color,
                      ),
                    ),
                  ],
                ),
              ),
            if (m.isDeletedForAll)
              Text(
                'تم حذف هذه الرسالة',
                style: TextStyle(
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  color: mine
                      ? Colors.white70
                      : Theme.of(context).textTheme.bodyMedium?.color,
                ),
              )
            else ...[
              if (m.replyTo != null) _replyChip(m, mine),
              _mediaContent(m, mine),
              if ((m.text ?? '').trim().isNotEmpty && m.kind == 'media')
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 5),
                  child: SelectableText(
                    m.text!,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: _chatFont.toDouble(),
                        color: mine
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurface),
                  ),
                ),
              if ((m.text ?? '').trim().isNotEmpty && m.kind == 'text')
                SelectableText(
                  m.text!,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: _chatFont.toDouble(),
                      height: 1.4,
                      color: mine
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface),
                ),
            ],
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // v0.1.0: star marker on the bubble meta row.
                if (m.starred)
                  const Padding(
                    padding: EdgeInsetsDirectional.only(end: 4),
                    child: Icon(Icons.bookmark_rounded,
                        size: 11, color: AppTheme.brandSecondary),
                  ),
                if (m.editedAt != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 5),
                    child: Text(
                      'معدّلة',
                      style: TextStyle(
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                        color: mine
                            ? Colors.white60
                            : Theme.of(context).textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                Text(
                  _msgTime(m.createdAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: mine
                        ? Colors.white70
                        : Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  if (m.localState == MsgState.failed)
                    const Icon(Icons.error_outline,
                        size: 13, color: AppTheme.errorColor)
                  else
                    _tickIcon(m.localState),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _onBubbleTap(Message m) {
    if (m.localState == MsgState.failed) {
      _snack('جاري إعادة محاولة الإرسال...');
      _services.sync.drain();
      return;
    }
    final media = m.media;
    if (media == null || m.isDeletedForAll) return;
    if (media.type == 'image') _openImageViewer(media);
  }

  Widget _tickIcon(MsgState state) {
    switch (state) {
      case MsgState.queued:
        return const Icon(Icons.schedule, size: 13, color: Colors.white60);
      case MsgState.sending:
        return const Icon(Icons.check_circle_outline,
            size: 13, color: Colors.white60);
      case MsgState.sent:
        return const Icon(Icons.check, size: 13, color: Colors.white70);
      case MsgState.delivered:
        return Icon(Icons.done_all, size: 14, color: AppTheme.tickColor(false));
      case MsgState.read:
        return Icon(Icons.done_all, size: 14, color: AppTheme.tickColor(true));
      case MsgState.failed:
        return const Icon(Icons.error_outline,
            size: 13, color: AppTheme.errorColor);
    }
  }

  String _msgTime(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    return DateFormat('HH:mm').format(d);
  }

  Widget _replyChip(Message m, bool mine) {
    final dim =
        mine ? Colors.white70 : Theme.of(context).textTheme.bodyMedium?.color;
    return InkWell(
      // v0.1.0: tapping the quote scrolls to the original message.
      onTap: () => unawaited(_jumpToMessage(m.replyTo)),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsetsDirectional.only(bottom: 6),
        padding: const EdgeInsetsDirectional.only(end: 8),
        decoration: BoxDecoration(
          color: mine
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 3,
                color: mine
                    ? Colors.white54
                    : AppTheme.brandPrimary.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 210),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(top: 5),
                      child: Text('رد على',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: dim)),
                    ),
                    Padding(
                      padding: const EdgeInsetsDirectional.only(bottom: 5),
                      child: Text(
                        (m.replyPreview ?? '').isEmpty
                            ? 'رسالة'
                            : m.replyPreview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: dim),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mediaContent(Message m, bool mine) {
    final media = m.media;
    if (media == null) return const SizedBox.shrink();
    switch (media.type) {
      case 'image':
        return _ImageBubble(media: media, services: _services, mine: mine);
      case 'audio':
        return _AudioBubble(media: media, services: _services, mine: mine);
      case 'video':
        return _VideoBubble(media: media, services: _services, mine: mine);
      case 'file':
      default:
        return _FileCard(media: media, services: _services, mine: mine);
    }
  }

  /// v0.1.0: pill shown while the user is reading older history and
  /// new messages arrive below the loaded window. Tapping returns to
  /// the newest page (same as most messengers' "new messages" chip).
  Widget _newBelowChip() {
    final c = _controller;
    if (c == null || c.newBelow == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 6),
      child: Center(
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          ),
          onPressed: () async {
            await c.jumpToLatest();
            if (_scroll.hasClients) {
              await _scroll.animateTo(
                0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
              );
            }
          },
          child: Text('↓ ${c.newBelow} رسالة جديدة'),
        ),
      ),
    );
  }

  Widget _reactionsRow(Message m, List<Reaction> reactions, bool mine) {
    final counts = <String, int>{};
    for (final r in reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 3),
      child: Wrap(
        spacing: 5,
        children: [
          for (final e in counts.entries)
            ActionChip(
              visualDensity: VisualDensity.compact,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              side: BorderSide(
                color: reactions
                        .any((r) => r.emoji == e.key && r.userId == _c.myId)
                    ? AppTheme.brandSecondary
                    : Colors.transparent,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              label: Text(
                '${e.key} ${e.value > 1 ? e.value : ''}'.trim(),
                style: const TextStyle(fontSize: 12),
              ),
              onPressed: () => _c.toggleReaction(m, e.key),
            ),
        ],
      ),
    );
  }

  // ===================================================================
  // Image viewer
  // ===================================================================
  void _openImageViewer(MediaInfo media) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: _ImageViewer(media: media, services: _services),
      ),
    );
  }

  // ===================================================================
  // Composer
  // ===================================================================
  Widget _composer() {
    final c = _controller!;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final hasReply = c.replyTo != null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_uploading) const LinearProgressIndicator(minHeight: 2),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: hasReply
                  ? _replyBar(c.replyTo!)
                  : const SizedBox(width: double.infinity),
            ),
            // v0.1.0: SafeArea(top:false) consumes the gesture-nav /
            // display-cutout bottom inset. The old flat Container sat
            // directly in the Scaffold body, so on devices without a
            // legacy nav bar the composer hugged the screen edge —
            // clipped buttons, zero safe margin (طمس الحواف).
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
              ),
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                      start: 4, end: 4, top: 6, bottom: 2),
                  child: _recording ? _recordingBar() : _inputRow(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _replyBar(Message reply) {
    return Container(
      key: const ValueKey('replyBar'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsetsDirectional.only(
          start: 14, end: 4, top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'رد على ${_c.isGroup && reply.senderId != _c.myId ? (_memberMap[reply.senderId]?.title ?? 'عضو') : 'رسالة'}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brandSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  (reply.text ?? '').trim().isEmpty ? '📎 وسائط' : reply.text!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // v0.1.0: was Colors.white54 — invisible on the light
                  // surface of the reply bar in light mode.
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'إلغاء الرد',
            icon: const Icon(Icons.close, size: 20),
            onPressed: _c.cancelReply,
          ),
        ],
      ),
    );
  }

  /// v0.1.0: single pill shape for EVERY border state. Before, only
  /// [border] was set locally, so [focusedBorder] fell back to the
  /// theme's radius-14 border painted around this radius-24 pill —
  /// clipped corners on focus, visually "overlapping" the hint/text.
  static const InputBorder _composerBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(24)),
    borderSide: BorderSide.none,
  );

  /// v0.1.0: fixed 44×44 icon slot. The old bare IconButtons let the
  /// [AnimatedSwitcher] stack two 48dp buttons mid-transition and press
  /// their touch targets against the field edge (hint "تداخل مع الأزرار").
  Widget _composerButton({
    Key? key,
    required Widget icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool filled = false,
  }) {
    final btn = filled
        ? IconButton.filled(
            key: key,
            tooltip: tooltip,
            icon: icon,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          )
        : IconButton(
            key: key,
            tooltip: tooltip,
            icon: icon,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          );
    return SizedBox(width: 44, height: 44, child: Center(child: btn));
  }

  Widget _inputRow() {
    final textEmpty = _textCtrl.text.trim().isEmpty;
    final rtl = Directionality.of(context) == ui.TextDirection.rtl;
    return Row(
      // v0.1.0: bottom-aligned — when the field grows to 5 lines the
      // attach/mic/send buttons stay anchored at the last line instead
      // of floating centered next to a tall empty pill.
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _composerButton(
          tooltip: 'إرفاق',
          icon: const Icon(Icons.attach_file, color: AppTheme.brandSecondary),
          onPressed: _uploading ? null : _attachmentSheet,
        ),
        const SizedBox(width: 2),
        Expanded(
          child: TextField(
            controller: _textCtrl,
            minLines: 1,
            maxLines: 5,
            enabled: !_recording,
            onChanged: _onTextChanged,
            // v0.1.0: keeps line 1 (and the hint with it) vertically
            // centred as the field grows — no more hint drifting to the
            // top while typed text sits centre (محاذاة النص التوجيهي).
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              hintText: 'اكتب رسالة...',
              // v0.1.0: never wrap, never lose the hint.
              hintMaxLines: 1,
              // v0.1.0: pin the hint to RTL even when the user's first
              // character is LTR — the hint must not flip or realign.
              // ui.* prefix: package:intl shadows dart:ui TextDirection.
              hintTextDirection: ui.TextDirection.rtl,
              isDense: true,
              contentPadding: EdgeInsetsDirectional.symmetric(
                  horizontal: 16, vertical: 11),
              border: _composerBorder,
              enabledBorder: _composerBorder,
              focusedBorder: _composerBorder,
              filled: true,
            ),
          ),
        ),
        const SizedBox(width: 2),
        SizedBox(
          width: 44,
          height: 44,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: textEmpty
                ? _composerButton(
                    key: const ValueKey('mic'),
                    tooltip: 'تسجيل صوتي',
                    icon:
                        const Icon(Icons.mic, color: AppTheme.brandSecondary),
                    onPressed: _startRecording,
                  )
                : _composerButton(
                    key: const ValueKey('send'),
                    filled: true,
                    tooltip: 'إرسال',
                    // v0.1.0: Icons.send is NOT in Flutter's auto-mirrored
                    // set — in RTL the outgoing arrow must point toward
                    // the far (left) edge, i.e. the direction the message
                    // travels. Hard-coding textDirection here is safe:
                    // the composer is RTL-first by product decision.
                    icon: Transform.flip(
                      flipX: rtl,
                      child: const Icon(Icons.send, size: 20),
                    ),
                    onPressed: _sendText,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _recordingBar() {
    // v0.1.0: internal safe padding + the same 44×44 button slots as
    // _inputRow, so the recording state aligns pixel-for-pixel with the
    // typing state and never touches the container edge.
    final rtl = Directionality.of(context) == ui.TextDirection.rtl;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 0, top: 4),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
                color: AppTheme.errorColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            _fmtClock(_recSw.elapsed),
            style: const TextStyle(
                color: AppTheme.errorColor,
                fontWeight: FontWeight.w700,
                fontSize: 13),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('جاري التسجيل...',
                // v0.1.0: was Colors.white54 — invisible on the light
                // composer surface in light mode.
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          _composerButton(
            tooltip: 'إلغاء التسجيل',
            icon: const Icon(Icons.delete_outline, color: AppTheme.errorColor),
            onPressed: () => _stopRecording(send: false),
          ),
          const SizedBox(width: 4),
          _composerButton(
            filled: true,
            tooltip: 'إرسال التسجيل',
            icon: Transform.flip(
              flipX: rtl,
              child: const Icon(Icons.send, size: 20),
            ),
            onPressed: () => _stopRecording(send: true),
          ),
        ],
      ),
    );
  }

  void _attachmentSheet() {
    // v0.1.2: neon grid sheet — big glowing tiles instead of list rows
    // (mockup quick-attachments: الصور / الملفات / الكاميرا).
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('إرفاق', textAlign: TextAlign.center,
                  style: Theme.of(sheetCtx).textTheme.titleMedium),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _attachTile(
                      sheetCtx,
                      icon: Icons.photo_library_rounded,
                      label: 'الصور',
                      hint: 'من المعرض',
                      gradient: const LinearGradient(
                          colors: [Color(0xFF8B5CF6), Color(0xFFA855F7)]),
                      onTap: () => _sendImage(ImageSource.gallery),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _attachTile(
                      sheetCtx,
                      icon: Icons.photo_camera_rounded,
                      label: 'الكاميرا',
                      hint: 'التقاط الآن',
                      gradient: const LinearGradient(
                          colors: [Color(0xFF0EA5E9), Color(0xFF22D3EE)]),
                      onTap: () => _sendImage(ImageSource.camera),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _attachTile(
                      sheetCtx,
                      icon: Icons.insert_drive_file_rounded,
                      label: 'الملفات',
                      hint: 'أي نوع ملف',
                      gradient: const LinearGradient(
                          colors: [Color(0xFFDB2777), Color(0xFFA855F7)]),
                      onTap: _sendFile,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // v0.1.10: encrypted poll — one full-width tile below the
              // media grid (mockup keeps the 3-column media row intact).
              _attachTile(
                sheetCtx,
                icon: Icons.poll_rounded,
                label: 'استطلاع رأي',
                hint: 'سؤال وخيارات مشفرة',
                gradient: const LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  showPollComposerSheet(
                    context,
                    onPublish: (q, opts) => _c.sendPoll(q, opts),
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                'كل المرفقات تُشفَّر طرف-لطرف قبل الرفع — حتى 50 ميجابايت',
                textAlign: TextAlign.center,
                style: Theme.of(sheetCtx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachTile(
    BuildContext sheetCtx, {
    required IconData icon,
    required String label,
    required String hint,
    required Gradient gradient,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(sheetCtx).colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: AppTheme.darkBorder.withValues(alpha: 0.35)),
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(14),
                boxShadow: AppTheme.glow(alpha: 0.35, blur: 14),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 1),
            Text(hint,
                style: Theme.of(sheetCtx).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Sheet tile helper
// =====================================================================

Widget _sheetTile(IconData icon, String label, VoidCallback onTap,
    {bool danger = false}) {
  return ListTile(
    dense: true,
    leading: Icon(icon,
        color: danger ? AppTheme.errorColor : AppTheme.brandSecondary),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 14,
        color: danger ? AppTheme.errorColor : null,
      ),
    ),
    onTap: onTap,
  );
}

// =====================================================================
// Avatar — v0.1.0: the local _Avatar class was removed in favor of the
// unified AvatarWidget (widgets/brand.dart) — one shape, one color
// hashing, everywhere in the app.
// =====================================================================

// =====================================================================
// Image bubble (encrypted thumbnail, lazy download)
// =====================================================================

class _ImageBubble extends StatefulWidget {
  final MediaInfo media;
  final AppServices services;
  final bool mine;
  const _ImageBubble(
      {required this.media, required this.services, required this.mine});

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
  late Future<Uint8List> _future;

  Color get _skeletonColor => widget.mine
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);

  @override
  void initState() {
    super.initState();
    _future = _download();
  }

  Future<Uint8List> _download() {
    final m = widget.media;
    return widget.services.mediaService.downloadDecrypted(
      path: m.thumbPath ?? m.path,
      fileKeyB64: m.thumbKey ?? m.fileKey,
      fileNonceB64: m.thumbNonce ?? m.fileNonce,
    );
  }

  void _retry() => setState(() => _future = _download());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              color: _skeletonColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
          return Container(
            width: 220,
            height: 120,
            decoration: BoxDecoration(
              color: _skeletonColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image,
                    color: widget.mine
                        ? Colors.white38
                        : Theme.of(context).disabledColor),
                TextButton(
                  onPressed: _retry,
                  child: const Text('إعادة المحاولة',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 220,
            height: 220,
            child: Image.memory(
              snap.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        );
      },
    );
  }
}

// =====================================================================
// Full-screen encrypted image viewer
// =====================================================================

class _ImageViewer extends StatefulWidget {
  final MediaInfo media;
  final AppServices services;
  const _ImageViewer({required this.media, required this.services});

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    final m = widget.media;
    _future = widget.services.mediaService.downloadDecrypted(
      path: m.path,
      fileKeyB64: m.fileKey,
      fileNonceB64: m.fileNonce,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('صورة مشفرة', style: TextStyle(fontSize: 15)),
      ),
      body: FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white38, size: 40),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () => setState(() {
                      final m = widget.media;
                      _future = widget.services.mediaService.downloadDecrypted(
                        path: m.path,
                        fileKeyB64: m.fileKey,
                        fileNonceB64: m.fileNonce,
                      );
                    }),
                    child: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            );
          }
          return InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.memory(snap.data!, fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }
}

// =====================================================================
// Audio bubble — tiny inline player (just_audio BytesSource)
// =====================================================================

class _AudioBubble extends StatefulWidget {
  final MediaInfo media;
  final AppServices services;
  final bool mine;
  const _AudioBubble(
      {required this.media, required this.services, required this.mine});

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Uint8List? _bytes;
  bool _loaded = false;
  bool _playing = false;
  bool _loading = false;
  double _progress = 0;

  String get _durationLabel {
    final ms = widget.media.durationMs ?? 0;
    if (ms <= 0) return '';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_playing) {
      await _player?.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    try {
      setState(() => _loading = true);
      if (_bytes == null) {
        final m = widget.media;
        _bytes = await widget.services.mediaService.downloadDecrypted(
          path: m.path,
          fileKeyB64: m.fileKey,
          fileNonceB64: m.fileNonce,
        );
      }
      final player = _player ??= AudioPlayer();
      if (!_loaded) {
        await player.setAudioSource(
          BytesAudioSource(_bytes!, mimeType: widget.media.mime),
        );
        _loaded = true;
      }
      _posSub ??= player.positionStream.listen((p) {
        if (!mounted) return;
        final total =
            player.duration?.inMilliseconds ?? (widget.media.durationMs ?? 0);
        if (total > 0) {
          setState(() {
            _progress = (p.inMilliseconds / total).clamp(0.0, 1.0);
          });
        }
      });
      _stateSub ??= player.playerStateStream.listen((st) {
        if (!mounted) return;
        if (st.processingState == ProcessingState.completed) {
          setState(() {
            _playing = false;
            _progress = 0;
          });
          player.seek(Duration.zero);
        } else {
          final playing = st.playing &&
              st.processingState != ProcessingState.loading &&
              st.processingState != ProcessingState.buffering;
          if (playing != _playing) setState(() => _playing = playing);
        }
      });
      await player.play();
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) setState(() => _playing = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('تعذر تشغيل التسجيل الصوتي')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconBg = widget.mine
        ? Colors.white24
        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.14);
    final iconColor =
        widget.mine ? Colors.white : Theme.of(context).colorScheme.primary;
    final trackBg = widget.mine
        ? Colors.white24
        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.18);
    final trackFill =
        widget.mine ? Colors.white : Theme.of(context).colorScheme.primary;
    final labelColor = widget.mine
        ? Colors.white70
        : Theme.of(context).textTheme.bodyMedium?.color;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 2, bottom: 2),
      child: SizedBox(
        width: 210,
        child: Row(
          children: [
            GestureDetector(
              onTap: _toggle,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: _loading
                    ? Padding(
                        padding: const EdgeInsets.all(9),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: iconColor),
                      )
                    : Icon(
                        _playing ? Icons.pause : Icons.play_arrow,
                        color: iconColor,
                        size: 22,
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: _progress <= 0 ? null : _progress,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(3),
                    backgroundColor: trackBg,
                    valueColor: AlwaysStoppedAnimation<Color>(trackFill),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _durationLabel.isEmpty ? 'رسالة صوتية' : _durationLabel,
                    style: TextStyle(fontSize: 10, color: labelColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Video — in-app encrypted playback (v0.1.0).
// Decrypts once to a private temp file, plays with the OS player
// plugin, offers share-out. Any failure falls back to the plain file
// card — video NEVER breaks the chat.
// =====================================================================

class _VideoBubble extends StatefulWidget {
  final MediaInfo media;
  final AppServices services;
  final bool mine;
  const _VideoBubble(
      {required this.media, required this.services, required this.mine});

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  VideoPlayerController? _controller;
  File? _file;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final m = widget.media;
      final bytes = await widget.services.mediaService.downloadDecrypted(
        path: m.path,
        fileKeyB64: m.fileKey,
        fileNonceB64: m.fileNonce,
      );
      final dir = await Directory.systemTemp.createTemp('nexora_video');
      final ext = m.name != null && m.name!.contains('.')
          ? m.name!.substring(m.name!.lastIndexOf('.'))
          : '.mp4';
      final file = File('${dir.path}/video$ext');
      await file.writeAsBytes(bytes, flush: true);
      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _file = file;
        _controller = ctrl;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        await c.play();
      }
    } catch (_) {}
  }

  Future<void> _share() async {
    final f = _file;
    if (f == null) return;
    final name =
        widget.media.name?.isNotEmpty == true ? widget.media.name! : 'فيديو';
    await Share.shareXFiles([XFile(f.path)], text: name);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      // Graceful degradation — the pre-v0.1.0 behaviour.
      return _FileCard(
          media: widget.media, services: widget.services, mine: widget.mine);
    }
    final ctrl = _controller;
    final fg =
        widget.mine ? Colors.white : Theme.of(context).colorScheme.onSurface;
    if (_loading || ctrl == null || !ctrl.value.isInitialized) {
      return Container(
        width: 220,
        height: 140,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.mine
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Container(
      width: 220,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _togglePlay,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AspectRatio(
                  aspectRatio: ctrl.value.aspectRatio == 0
                      ? 16 / 9
                      : ctrl.value.aspectRatio,
                  child: VideoPlayer(ctrl),
                ),
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    ctrl.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: VideoProgressIndicator(
                  ctrl,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                      playedColor: AppTheme.brandSecondary),
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                ),
              ),
              InkWell(
                onTap: _share,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4, end: 10),
                  child: Icon(Icons.share_rounded,
                      size: 17, color: fg.withValues(alpha: 0.8)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Video / generic file card — decrypt then share
// =====================================================================

class _FileCard extends StatefulWidget {
  final MediaInfo media;
  final AppServices services;
  final bool mine;
  const _FileCard(
      {required this.media, required this.services, required this.mine});

  @override
  State<_FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<_FileCard> {
  bool _busy = false;

  IconData get _icon =>
      widget.media.type == 'video' ? Icons.videocam : Icons.insert_drive_file;

  String get _title =>
      widget.media.name?.isNotEmpty == true ? widget.media.name! : 'ملف مشفر';

  static String _fmtSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final m = widget.media;
      final bytes = await widget.services.mediaService.downloadDecrypted(
        path: m.path,
        fileKeyB64: m.fileKey,
        fileNonceB64: m.fileNonce,
      );
      final dir = await Directory.systemTemp.createTemp('nexora_share');
      final ext = m.name != null && m.name!.contains('.')
          ? m.name!.substring(m.name!.lastIndexOf('.'))
          : '.bin';
      final file = File(
          '${dir.path}/share_${DateTime.now().millisecondsSinceEpoch}$ext');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)], text: _title);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('تعذر فك تشفير الملف')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.mine ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final bg =
        widget.mine ? Colors.white.withValues(alpha: 0.12) : Colors.black12;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 2, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _open,
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_icon, color: fg, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmtSize(widget.media.size)} — انقر لفتح ومشاركة',
                      style: TextStyle(
                          fontSize: 10, color: fg.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plays raw decrypted audio bytes via just_audio (no BytesSource in
/// just_audio — this minimal StreamAudioSource covers it).
class BytesAudioSource extends StreamAudioSource {
  final Uint8List bytes;
  final String mimeType;

  BytesAudioSource(this.bytes, {this.mimeType = 'audio/mp4'});

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: bytes.length,
      offset: 0,
      contentType: mimeType,
      stream: Stream.value(bytes),
      rangeRequestsSupported: true,
    );
  }
}
