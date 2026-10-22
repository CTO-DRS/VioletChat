import 'package:flutter/foundation.dart';

/// Internal structured logger.
///
/// SECURITY RULES (enforced by review, see SECURITY.md):
/// - NEVER log: passwords, private keys, plaintext message bodies,
///   session secrets, tokens, ratchet state.
/// - Only metadata (ids, sizes, states) is allowed.
class AppLogger {
  AppLogger._();

  static const String _redacted = '[REDACTED]';

  static void d(String tag, String message) {
    if (kDebugMode) debugPrint('🟦 [$tag] $message');
  }

  static void i(String tag, String message) {
    if (kDebugMode) debugPrint('🟩 [$tag] $message');
  }

  static void w(String tag, String message, [Object? error]) {
    if (kDebugMode) {
      debugPrint('🟨 [$tag] $message${error == null ? '' : ' err=$_redacted'}');
    }
  }

  static void e(String tag, String message, [Object? error, StackTrace? st]) {
    if (kDebugMode) {
      debugPrint('🟥 [$tag] $message err=$_redacted');
      if (st != null) debugPrint('$st');
    }
  }

  /// Wrap any secret-bearing value before logging.
  static String secret(Object? _) => _redacted;
}
