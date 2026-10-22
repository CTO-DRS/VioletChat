/// Smart date helpers shared by the chats list and chat date
/// separators (v0.1.0). Locale-aware wording in Arabic with compact
/// numeric fallbacks; digits stay Western to match the rest of the UI.
class SmartDate {
  SmartDate._();

  static String _two(int n) => n.toString().padLeft(2, '0');

  static int _dayDiff(DateTime a, DateTime b) {
    return DateTime(a.year, a.month, a.day)
        .difference(DateTime(b.year, b.month, b.day))
        .inDays;
  }

  /// Compact stamp for chat-list rows: `HH:mm` today, `أمس` yesterday,
  /// `d/M` within the current year, `y/M/d` otherwise.
  static String listStamp(DateTime t, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final diff = _dayDiff(n, t);
    if (diff == 0) return '${_two(t.hour)}:${_two(t.minute)}';
    if (diff == 1) return 'أمس';
    if (n.year == t.year) return '${t.day}/${t.month}';
    return '${t.year}/${t.month}/${t.day}';
  }

  /// Pill label for chat date separators: `اليوم` / `أمس` /
  /// `d/M` this year / `d/M/y` otherwise.
  static String dayLabel(DateTime d, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final diff = _dayDiff(n, d);
    if (diff == 0) return 'اليوم';
    if (diff == 1) return 'أمس';
    if (n.year == d.year) return '${d.day}/${d.month}';
    return '${d.day}/${d.month}/${d.year}';
  }

  /// v0.1.0: last-seen subtitle for the 1:1 chat AppBar:
  /// `آخر ظهور 14:32` today, `آخر ظهور أمس 21:05` yesterday,
  /// `آخر ظهور 3/10` older (this year) — digits stay Western.
  static String lastSeen(DateTime t, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final diff = _dayDiff(n, t);
    final hm = '${_two(t.hour)}:${_two(t.minute)}';
    if (diff == 0) return 'آخر ظهور $hm';
    if (diff == 1) return 'آخر ظهور أمس $hm';
    if (n.year == t.year) return 'آخر ظهور ${t.day}/${t.month}';
    return 'آخر ظهور ${t.day}/${t.month}/${t.year}';
  }
}
