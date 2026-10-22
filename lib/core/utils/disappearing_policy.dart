/// v0.1.0 — disappearing messages policy helpers (pure, testable).
///
/// The SERVER stamps `messages.expires_at` at INSERT from the chat's
/// current `disappear_ttl_seconds` (see supabase patch 2026-10-08-v010).
/// This class is only the client-side mirror: hiding expired bubbles,
/// labelling the TTL picker, and comparing choices.
class DisappearingPolicy {
  DisappearingPolicy._();

  /// Picker choices (WhatsApp-like defaults): 24h / 7d / 90d.
  static const List<int> ttlChoices = [86400, 604800, 7776000];

  /// A message is expired when its server-stamped expiry has passed.
  /// Null/unparseable expiry = never expires (we never invent one).
  static bool isExpired(String? expiresAtIso, DateTime nowUtc) {
    if (expiresAtIso == null || expiresAtIso.isEmpty) return false;
    final exp = DateTime.tryParse(expiresAtIso);
    if (exp == null) return false;
    return exp.isBefore(nowUtc) || exp.isAtSameMomentAs(nowUtc);
  }

  /// Arabic label for a TTL in seconds (null/<=0 = OFF).
  static String label(int? ttlSeconds) {
    final t = ttlSeconds ?? 0;
    if (t <= 0) return 'إيقاف';
    if (t == 86400) return '24 ساعة';
    if (t == 604800) return '7 أيام';
    if (t == 7776000) return '90 يوماً';
    if (t < 3600) return '$t ثانية';
    if (t < 86400) return '${t ~/ 3600} ساعة';
    return '${t ~/ 86400} يوماً';
  }

  /// True when [ttl] is one of the canonical picker choices.
  static bool isKnownChoice(int? ttl) => ttl != null && ttlChoices.contains(ttl);
}
