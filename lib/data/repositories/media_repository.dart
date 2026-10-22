import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_config.dart';

/// Encrypted media storage access.
/// Path layout (ownership-aware, enforced by storage RLS):
///   media/{chatId}/{userId}/{uuid}.enc
///   media/{chatId}/{userId}/thumb_{uuid}.enc
class MediaRepository {
  final SupabaseClient client;
  MediaRepository(this.client);

  Future<String> upload(String chatId, Uint8List encrypted,
      {bool thumbnail = false}) async {
    final uid = client.auth.currentUser!.id;
    final name = thumbnail
        ? 'thumb_${DateTime.now().millisecondsSinceEpoch}_${_rand(8)}'
        : '${DateTime.now().millisecondsSinceEpoch}_${_rand(8)}';
    final path = 'media/$chatId/$uid/$name.enc';
    await client.storage.from('media').uploadBinary(
          path,
          encrypted,
          fileOptions: const FileOptions(
            contentType: 'application/octet-stream',
            upsert: false,
          ),
        );
    return path;
  }

  Future<Uint8List> download(String path) async {
    final bytes = await client.storage.from('media').download(path);
    return Uint8List.fromList(bytes);
  }

  /// Owner-only delete (storage policy enforces path ownership).
  Future<void> delete(String path) async {
    await client.storage.from('media').remove([path]);
  }

  static final Random _randGen = Random.secure();

  static String _rand(int n) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(n, (_) => chars[_randGen.nextInt(chars.length)])
        .join();
  }

  static int get maxBytes => AppConfig.mediaMaxBytes;
}
