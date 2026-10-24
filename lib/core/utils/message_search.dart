import '../../data/models/models.dart';
import '../../features/chats/chat_query.dart' show normalizeAr;

/// v0.1.13 — in-chat message search (البحث داخل المحادثة).
///
/// Pure logic only (no Flutter) so it is directly unit-testable.
/// Matching reuses [normalizeAr] — the same tolerant Arabic
/// normalization as the chats-list filter (hamza/alef forms, taa
/// marbuta, tashkeel, Persian yeh/kaf, latin case) — so «أحمد» matches
/// «احمد» and «درس» matches «درْس».
///
/// The haystack covers every decrypted, user-visible text of a message:
///   - the text/caption
///   - the media file name
///   - the poll question and its options
///   - the location label
///   - the contact card display name / username
///
/// The server stores none of these (E2E) — search runs entirely over
/// the decrypted local cache (MessageCache.searchInChat).

/// Build the searchable haystack of [m]. Never throws — a row that
/// fails to decode contributes an empty haystack.
String messageHaystack(Message m) {
  final parts = <String>[
    m.text ?? '',
    m.media?.name ?? '',
    m.poll?.question ?? '',
    ...(m.poll?.options ?? const <String>[]),
    m.location?.label ?? '',
    m.contact?.displayName ?? '',
    m.contact?.username ?? '',
  ];
  return parts.map(normalizeAr).join('\n');
}

/// Does [m] match the raw user query [rawQuery]? Empty/whitespace
/// queries match everything (the UI treats that as "clear").
bool messageMatchesQuery(Message m, String rawQuery) {
  final q = normalizeAr(rawQuery.trim());
  if (q.isEmpty) return true;
  return messageHaystack(m).contains(q);
}
