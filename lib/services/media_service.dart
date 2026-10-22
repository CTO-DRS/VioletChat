import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/config/app_config.dart';
import '../crypto/primitives.dart';
import '../core/errors/app_exception.dart';
import '../core/logging/app_logger.dart';
import '../data/models/models.dart';
import '../data/repositories/media_repository.dart';
import 'message_crypto_service.dart';

/// Encrypted media pipeline:
///   pick -> validate -> [thumbnail] -> encrypt(AES-GCM, random key)
///        -> upload(.enc) -> reference key+nonce travel INSIDE the
///        encrypted message body.
///
/// Download: fetch .enc -> decrypt with key from message -> cache.
class MediaService {
  final MediaRepository repo;
  final MessageCryptoService crypto;

  /// Per-message media cache: "path" -> decrypted bytes.
  final Map<String, Uint8List> _memoryCache = {};

  MediaService(this.repo, this.crypto);

  // ------------------------------------------------------------------
  // Upload path
  // ------------------------------------------------------------------
  Future<MediaUploadResult> uploadMedia({
    required String chatId,
    required String type, // image | audio | video | file
    required Uint8List bytes,
    String? originalName,
    String? mime,
    int? width,
    int? height,
    int? durationMs,
  }) async {
    if (bytes.length > AppConfig.mediaMaxBytes) {
      throw AppException.validation('الملف أكبر من الحد المسموح (50 ميجابايت)');
    }
    _validateMime(mime);

    // Random file key — never reused, travels encrypted in the message.
    final fileKey = Primitives.randomBytes(32);
    final (nonce, encrypted) = await Primitives.sealRandom(bytes, fileKey);
    final path = await repo.upload(chatId, encrypted);

    String? thumbPath;
    String? thumbKeyB64;
    String? thumbNonceB64;
    if (type == 'image' && bytes.length < 8 * 1024 * 1024) {
      try {
        final thumb = _makeThumbnail(bytes);
        if (thumb != null) {
          final tkey = Primitives.randomBytes(32);
          final (tnonce, tenc) = await Primitives.sealRandom(thumb, tkey);
          thumbPath = await repo.upload(chatId, tenc, thumbnail: true);
          thumbKeyB64 = Primitives.b64(tkey);
          thumbNonceB64 = Primitives.b64(tnonce);
        }
      } catch (e) {
        AppLogger.w('media', 'thumbnail generation failed', e);
      }
    }

    return MediaUploadResult(
      type: type,
      path: path,
      size: bytes.length,
      mime: mime ?? 'application/octet-stream',
      name: originalName,
      width: width,
      height: height,
      durationMs: durationMs,
      fileKey: Primitives.b64(fileKey),
      fileNonce: Primitives.b64(nonce),
      thumbPath: thumbPath,
      thumbKey: thumbKeyB64,
      thumbNonce: thumbNonceB64,
    );
  }

  Uint8List? _makeThumbnail(Uint8List imageBytes) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return null;
    final resized = img.copyResize(decoded, width: 320);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 70));
  }

  void _validateMime(String? mime) {
    // Encrypted blobs are always octet-stream server-side; the MIME
    // check applies to the ORIGINAL file type for safety messaging.
    if (mime != null && mime.startsWith('text/html')) {
      throw AppException.validation('نوع ملف غير مسموح');
    }
  }

  // ------------------------------------------------------------------
  // Download path
  // ------------------------------------------------------------------
  Future<Uint8List> downloadDecrypted({
    required String path,
    required String fileKeyB64,
    required String fileNonceB64,
  }) async {
    final cached = _memoryCache[path];
    if (cached != null) return cached;

    final fileCache = await _readFileCache(path);
    if (fileCache != null) {
      _memoryCache[path] = fileCache;
      return fileCache;
    }

    final enc = await repo.download(path);
    final plain = await Primitives.open(
      enc,
      Primitives.unb64(fileKeyB64),
      Primitives.unb64(fileNonceB64),
    );
    _memoryCache[path] = plain;
    await _writeFileCache(path, plain);
    return plain;
  }

  Future<void> clearCache() async {
    _memoryCache.clear();
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory(p.join(dir.path, 'media_cache'));
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  }

  Future<Uint8List?> _readFileCache(String path) async {
    try {
      final dir = await getTemporaryDirectory();
      final f =
          File(p.join(dir.path, 'media_cache', path.replaceAll('/', '_')));
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  Future<void> _writeFileCache(String path, Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(dir.path, 'media_cache'));
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final f = File(p.join(cacheDir.path, path.replaceAll('/', '_')));
      await f.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }
}

class MediaUploadResult {
  final String type;
  final String path;
  final int size;
  final String mime;
  final String? name;
  final int? width;
  final int? height;
  final int? durationMs;
  final String fileKey;
  final String fileNonce;
  final String? thumbPath;
  final String? thumbKey;
  final String? thumbNonce;

  const MediaUploadResult({
    required this.type,
    required this.path,
    required this.size,
    required this.mime,
    required this.fileKey,
    required this.fileNonce,
    this.name,
    this.width,
    this.height,
    this.durationMs,
    this.thumbPath,
    this.thumbKey,
    this.thumbNonce,
  });

  MediaInfo toMediaInfo() => MediaInfo(
        type: type,
        path: path,
        size: size,
        mime: mime,
        name: name,
        width: width,
        height: height,
        durationMs: durationMs,
        fileKey: fileKey,
        fileNonce: fileNonce,
        thumbPath: thumbPath,
        thumbKey: thumbKey,
        thumbNonce: thumbNonce,
      );
}
