import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// In-chat message translation (v0.1.14).
///
/// PRIVACY (honest design): translation is strictly user-initiated,
/// per message. When the user taps «ترجمة», THAT message's decrypted
/// text is sent over HTTPS to the public Google Translate endpoint and
/// the result is cached in memory only (never persisted, never sent to
/// our server). Nothing is translated automatically — silence by
/// default, exactly like the big messengers' on-demand flows.
class TranslationService {
  TranslationService(this._client);

  static TranslationService? _i;
  static TranslationService get I =>
      _i ??= TranslationService(HttpClient());

  static set instance(TranslationService s) => _i = s;

  final HttpClient _client;
  final Map<String, TranslationResult> _cache = {};

  static const _endpoint = 'https://translate.googleapis.com/translate_a/single';
  static const _timeout = Duration(seconds: 8);
  static const _cacheCap = 200;

  /// Smart target: Arabic text → English, everything else → Arabic
  /// (the app is Arabic-first). Heuristic on Arabic-letter ratio so a
  /// mixed sentence with mostly Latin stays Latin-targeted... inverted:
  /// mostly-Arabic content targets English, otherwise Arabic.
  static String pickTarget(String text) {
    final arabic =
        RegExp(r'[\u0600-\u06FF]').allMatches(text).length;
    final latin = RegExp(r'[A-Za-z]').allMatches(text).length;
    final letters = arabic + latin;
    if (letters == 0) return 'ar';
    return arabic / letters > 0.3 ? 'en' : 'ar';
  }

  /// Parse the public `gtx` payload:
  /// `[[["مرحبا","hello",null,null,10]],null,"en",...]`
  /// Segment chunks are concatenated; index 2 carries the detected
  /// source language. Returns the translated text (empty on a
  /// malformed body — callers treat empty as failure).
  static TranslationResult parseGtx(List<dynamic> decoded, String target) {
    String text = '';
    if (decoded.isNotEmpty && decoded[0] is List) {
      for (final seg in (decoded[0] as List)) {
        if (seg is List && seg.isNotEmpty && seg[0] is String) {
          text += seg[0] as String;
        }
      }
    }
    final source = decoded.length > 2 && decoded[2] is String
        ? decoded[2] as String
        : 'auto';
    return TranslationResult(text: text, source: source, target: target);
  }

  /// Translate [text]. Throws on network/parse failure; the UI maps
  /// that to «تعذرت الترجمة». Results are memoised per (target, text).
  Future<TranslationResult> translate(String text) async {
    final target = pickTarget(text);
    final key = '$target\u0000$text';
    final hit = _cache[key];
    if (hit != null) return hit;

    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'client': 'gtx',
      'sl': 'auto',
      'tl': target,
      'dt': 't',
      'ie': 'UTF-8',
      'oe': 'UTF-8',
      'q': text,
    });
    final req = await _client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Android)');
    final res = await req.close().timeout(_timeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('translate HTTP ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join().timeout(_timeout);
    final decoded = jsonDecode(body);
    if (decoded is! List) throw const FormatException('unexpected gtx body');
    final result = parseGtx(decoded, target);
    if (result.text.isEmpty) throw const FormatException('empty translation');

    if (_cache.length >= _cacheCap) _cache.clear();
    _cache[key] = result;
    return result;
  }
}

/// One translation outcome rendered inside the message bubble.
class TranslationResult {
  final String text;
  final String source;
  final String target;
  const TranslationResult({
    required this.text,
    required this.source,
    required this.target,
  });
}
