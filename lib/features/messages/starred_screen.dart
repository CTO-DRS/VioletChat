import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/smart_date.dart';
import '../../data/models/models.dart';
import '../../routing/app_router.dart';
import '../../state/app_services.dart';
import '../../state/chats_controller.dart';
import '../../theme/app_theme.dart';

/// v0.1.0 — «الرسائل المحفوظة» screen: messages I starred, across all
/// chats, from the decrypted local cache — resynced against the server
/// `message_stars` table on every open.
///
/// HONEST BOUNDARY: this view is device-scoped. Stars made on another
/// device appear here after the resync pulls the ids from the server
/// (the messages themselves must already be in this device's cache).
class StarredScreen extends StatefulWidget {
  const StarredScreen({super.key});

  @override
  State<StarredScreen> createState() => _StarredScreenState();
}

class _StarredScreenState extends State<StarredScreen> {
  Future<List<Message>>? _future;
  String? _resyncError;
  final Set<String> _missingIds = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Message>> _load() async {
    final services = context.read<AppServices>();
    // Resync star flags against the server (best-effort).
    try {
      final serverIds =
          (await services.messages.starredIds()).toSet();
      final local = await services.cache.starred();
      for (final m in local) {
        final onServer = serverIds.contains(m.id);
        if (onServer && m.starred) continue;
        await services.cache.setStarred(m.id, onServer);
      }
      // Stars on the server for rows we don't have cached yet are
      // surfaced as ids-only placeholders so the count stays honest.
      final cachedIds = local.map((m) => m.id).toSet();
      _missingIds.addAll(serverIds.difference(cachedIds));
    } catch (_) {
      _resyncError = 'تعذر المزامنة مع الخادم — عرض الحالة المحلية';
    }
    return services.cache.starred();
  }

  String _preview(Message m) {
    if (m.isDeletedForAll) return '🚫 تم حذف هذه الرسالة';
    final text = m.text?.trim();
    if (text != null && text.isNotEmpty) return text;
    return switch (m.media?.type) {
      'image' => '📷 صورة',
      'audio' => '🎤 رسالة صوتية',
      'video' => '🎬 فيديو',
      _ => '📎 ملف',
    };
  }

  Future<void> _unstar(Message m) async {
    final services = context.read<AppServices>();
    await services.cache.setStarred(m.id, false);
    try {
      await services.messages.toggleStar(m.id, false);
    } catch (_) {}
    setState(() => _future = _load());
  }

  void _openChat(Message m) {
    final chats = context.read<ChatsController>().chats;
    Chat? match;
    for (final c in chats) {
      if (c.id == m.chatId) {
        match = c;
        break;
      }
    }
    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المحادثة غير موجودة في قائمتك')),
      );
      return;
    }
    Navigator.pushNamed(context, AppRoutes.chat, arguments: match);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_forward),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('الرسائل المحفوظة',
            style: TextStyle(fontSize: 17)),
      ),
      body: FutureBuilder<List<Message>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <Message>[];
          if (items.isEmpty && _missingIds.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bookmark_border_rounded,
                        size: 44, color: Theme.of(context).disabledColor),
                    const SizedBox(height: 12),
                    const Text(
                      'لا رسائل محفوظة بعد\nاضغط مطولاً على أي رسالة واختر «حفظ»',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: items.length + (_missingIds.isEmpty ? 0 : 1),
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == items.length) {
                return ListTile(
                  leading: const Icon(Icons.sync_problem,
                      color: Colors.amber),
                  title: Text(
                    '${_missingIds.length} رسالة محفوظة على الخادم لم تصل لهذا الجهاز بعد',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: _resyncError == null
                      ? null
                      : Text(_resyncError!,
                          style: const TextStyle(fontSize: 11)),
                );
              }
              final m = items[i];
              final chats = context.read<ChatsController>().chats;
              String chatTitle = 'محادثة';
              for (final c in chats) {
                if (c.id == m.chatId) {
                  chatTitle = c.title;
                  break;
                }
              }
              final at =
                  DateTime.tryParse(m.createdAt)?.toLocal();
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      AppTheme.brandPrimary.withValues(alpha: 0.14),
                  child: const Icon(Icons.bookmark_rounded,
                      size: 20, color: AppTheme.brandPrimary),
                ),
                title: Text(
                  _preview(m),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '$chatTitle${at != null ? ' • ${SmartDate.dayLabel(at)}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: 'إلغاء الحفظ',
                  icon: const Icon(Icons.bookmark_remove_outlined,
                      color: Colors.grey),
                  onPressed: () => _unstar(m),
                ),
                onTap: () => _openChat(m),
              );
            },
          );
        },
      ),
    );
  }
}
