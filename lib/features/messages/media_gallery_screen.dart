import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/smart_date.dart';
import '../../data/models/models.dart';
import '../../state/app_services.dart';
import '../../theme/app_theme.dart';

/// v0.1.0 — in-chat media gallery: every cached media row of the chat
/// rendered as a grid of DECRYPTED thumbnails (same decrypt path as
/// the image bubble). Audio/video/file rows show as labelled tiles.
///
/// HONEST BOUNDARY: the gallery reads the local cache (decrypted
/// on-device). Rows not yet synced to this device appear after the
/// chat is scrolled/synced.
class MediaGalleryScreen extends StatelessWidget {
  final Chat chat;
  const MediaGalleryScreen({super.key, required this.chat});

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_forward),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('وسائط المحادثة',
                style: TextStyle(fontSize: 17)),
            Text(
              chat.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      body: FutureBuilder<List<Message>>(
        future: services.cache.media(chat.id),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <Message>[];
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.photo_library_outlined,
                        size: 44,
                        color: Theme.of(context).disabledColor),
                    const SizedBox(height: 12),
                    const Text('لا توجد وسائط محفوظة بعد',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => _GalleryTile(
              message: items[i],
              services: services,
            ),
          );
        },
      ),
    );
  }
}

class _GalleryTile extends StatefulWidget {
  final Message message;
  final AppServices services;
  const _GalleryTile({required this.message, required this.services});

  @override
  State<_GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<_GalleryTile> {
  late Future<Uint8List?> _future;

  MediaInfo get m => widget.message.media!;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Uint8List?> _load() async {
    // Images/videos decrypt the thumbnail (fallback: full blob);
    // audio/file tiles have no thumbnail — they render an icon.
    if (m.type != 'image' && m.type != 'video') return null;
    try {
      return await widget.services.mediaService.downloadDecrypted(
        path: m.thumbPath ?? m.path,
        fileKeyB64: m.thumbKey ?? m.fileKey,
        fileNonceB64: m.thumbNonce ?? m.fileNonce,
      );
    } catch (_) {
      return null;
    }
  }

  void _retry() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final isVisual = m.type == 'image' || m.type == 'video';
    return GestureDetector(
      onTap: widget.message.isDeletedForAll ? null : _retry,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isVisual)
              FutureBuilder<Uint8List?>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Container(color: Colors.black12);
                  }
                  final data = snap.data;
                  if (data == null || data.isEmpty) {
                    return Container(
                      color: Colors.black12,
                      child: const Icon(Icons.broken_image_outlined),
                    );
                  }
                  return Image.memory(data, fit: BoxFit.cover);
                },
              )
            else
              Container(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                child: Center(
                  child: Icon(
                    switch (m.type) {
                      'audio' => Icons.audiotrack_rounded,
                      'video' => Icons.videocam_rounded,
                      _ => Icons.insert_drive_file_rounded,
                    },
                    size: 34,
                    color: AppTheme.brandSecondary,
                  ),
                ),
              ),
            if (m.type == 'video' && isVisual)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    size: 34, color: Colors.white70),
              ),
            PositionedDirectional(
              start: 4,
              bottom: 4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  SmartDate.dayLabel(DateTime.tryParse(widget
                              .message.createdAt)
                          ?.toLocal() ??
                      DateTime.now()),
                  style: const TextStyle(
                      fontSize: 9.5, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
