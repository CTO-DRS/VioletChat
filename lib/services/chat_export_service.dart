import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models/models.dart';

/// v0.1.0 — chat export: builds a readable text transcript from the
/// DECRYPTED local cache and shares it as a .txt file via the system
/// share sheet.
///
/// HONEST BOUNDARY: exports text content + media *placeholders* only
/// ([صورة] / [صوت] …) — media blobs are NOT re-encrypted or attached,
/// and the export covers the messages currently in the local cache.
class ChatExportService {
  ChatExportService._();

  /// Pure transcript builder (testable). [nameOf] resolves sender ids
  /// to display names; [now] injectable for deterministic tests.
  static String buildTranscript({
    required String title,
    required List<Message> messages,
    required String Function(String senderId) nameOf,
    DateTime? now,
  }) {
    final stamp = DateFormat('yyyy-MM-dd HH:mm').format(now ?? DateTime.now());
    final buf = StringBuffer()
      ..writeln('Violet Chat — تصدير محادثة')
      ..writeln('المحادثة: $title')
      ..writeln('وقت التصدير: $stamp')
      ..writeln('عدد الرسائل: ${messages.length}')
      ..writeln('تنبيه: هذه نسخة نصية محلية — الوسائط تظهر كوصف فقط.')
      ..writeln('———————————————');

    final ts = DateFormat('yyyy-MM-dd, HH:mm');
    for (final m in messages) {
      final at = DateTime.tryParse(m.createdAt)?.toLocal();
      final time = at == null ? '' : ts.format(at);
      if (m.isDeletedForAll) {
        buf.writeln('[$time] ${nameOf(m.senderId)}: 🚫 تم حذف هذه الرسالة');
        continue;
      }
      final body = m.text?.trim();
      final mediaBit = switch (m.media?.type) {
        'image' => '📷 صورة',
        'audio' => '🎤 رسالة صوتية',
        'video' => '🎬 فيديو',
        'file' => '📎 ملف',
        _ => null,
      };
      final text = (body == null || body.isEmpty)
          ? (mediaBit ?? '')
          : (mediaBit == null ? body : '$mediaBit — $body');
      final edited = m.editedAt != null ? ' (معدّلة)' : '';
      buf.writeln('[$time] ${nameOf(m.senderId)}: $text$edited');
    }
    return buf.toString();
  }

  /// Write the transcript to a temp .txt file and open the system
  /// share sheet. Returns false when sharing failed/absent.
  static Future<bool> shareTranscript({
    required String title,
    required String safeFileName,
    required String transcript,
  }) async {
    final dir = await getTemporaryDirectory();
    final f = File(
        '${dir.path}/nexora_export_${safeFileName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.txt');
    await f.writeAsString(transcript, flush: true);
    // share_plus 10.x — shareXFiles (plural) is the supported API here;
    // dismissed still counts as "handled" (the user saw the sheet).
    final result = await Share.shareXFiles(
      [XFile(f.path, mimeType: 'text/plain')],
      text: 'تصدير محادثة: $title',
    );
    return result.status == ShareResultStatus.success ||
        result.status == ShareResultStatus.dismissed;
  }
}
