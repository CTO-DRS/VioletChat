import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/services/translation_service.dart';

/// audit 2026-10-25 — the translation request must never carry message
/// text in the URL. buildRequest is pure, so these are exact contracts:
/// text rides the POST body, the URL carries only parameters, and the
/// hard cap rejects oversized input before any network I/O.
void main() {
  group('TranslationService.buildRequest (POST migration)', () {
    test('text is NOT in the URL — only in the body', () {
      const text = 'مرحبا بالعالم — سر للغاية';
      final (uri, body) = TranslationService.buildRequest(text, 'en');
      expect(uri.toString().contains('مرحبا'), isFalse);
      expect(uri.queryParameters.containsKey('q'), isFalse);
      expect(body, startsWith('q='));
    });

    test('body decodes back to the exact input (UTF-8 round-trip)', () {
      const text = 'نصٌّ عربي with Latin + emoji 🙂';
      final (_, body) = TranslationService.buildRequest(text, 'ar');
      final decoded = Uri.splitQueryString(body);
      expect(decoded['q'], text);
    });

    test('URL still carries the gtx parameters', () {
      final (uri, _) = TranslationService.buildRequest('hi', 'ar');
      final q = uri.queryParameters;
      expect(q['client'], 'gtx');
      expect(q['sl'], 'auto');
      expect(q['tl'], 'ar');
      expect(q['dt'], 't');
    });

    test('hard cap: oversized input rejected before any request is built',
        () {
      final tooBig = 'a' * (TranslationService.maxChars + 1);
      expect(() => TranslationService.buildRequest(tooBig, 'ar'),
          throwsArgumentError);
      // Exactly at the cap is fine.
      final (uri, body) = TranslationService.buildRequest(
          'a' * TranslationService.maxChars, 'ar');
      expect(uri.host, 'translate.googleapis.com');
      expect(body, isNotEmpty);
    });
  });
}
