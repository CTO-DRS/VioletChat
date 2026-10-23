import '../constants/app_constants.dart';
import '../../data/models/models.dart';

/// v0.1.10 — pure client-side poll tallying.
///
/// The server never sees ballots (they are E2E-encrypted 'pollVote'
/// rows), so counting happens here, on every member's device:
///   - a ballot counts for [pollMsg] when its plaintext reply_to
///     matches the poll's server row id (or the creator's client-side
///     pollId — identical semantics, covers optimistic placeholders);
///   - one voter = one vote: the LAST ballot in the list wins (senders
///     can change their vote by casting again — WhatsApp semantics);
///   - deleted-for-all ballots are ignored;
///   - ballots carrying an out-of-range option index are ignored
///     (defensive: foreign/legacy clients, version drift).
class PollTally {
  PollTally._();

  /// [pollMsg] is the decrypted poll row (kind == poll, poll != null);
  /// [votes] is the chat's message list (any order — ties are broken by
  /// created_at, then by list position for identical timestamps).
  /// Returns option index -> voter user ids (one entry per voter).
  static Map<int, List<String>> tally(Message pollMsg, List<Message> votes) {
    final poll = pollMsg.poll;
    if (poll == null) return const {};
    final latestByVoter = <String, Message>{};
    for (final v in votes) {
      if (v.kind != AppConstants.kindPollVote) continue;
      if (v.isDeletedForAll) continue;
      if (!_refersToPoll(v, pollMsg, poll)) continue;
      final option = v.pollVote;
      if (option == null || !poll.isValidOption(option)) continue;
      final prev = latestByVoter[v.senderId];
      if (prev == null || !prev.createdAtAsTime.isAfter(v.createdAtAsTime)) {
        latestByVoter[v.senderId] = v;
      }
    }
    final out = <int, List<String>>{};
    for (final e in latestByVoter.entries) {
      (out[e.value.pollVote!] ??= []).add(e.key);
    }
    return out;
  }

  /// A ballot counts when it references THIS poll through either the
  /// encrypted pollRef (always present — the primary link) or the
  /// plaintext reply_to (set when the poll row id was known).
  static bool _refersToPoll(Message v, Message pollMsg, PollInfo poll) =>
      v.chatId == pollMsg.chatId &&
      (v.pollRef == poll.pollId ||
          v.replyTo == pollMsg.id ||
          v.replyTo == poll.pollId);

  /// Total number of counted voters.
  static int totalVoters(Map<int, List<String>> tally) =>
      tally.values.fold(0, (a, l) => a + l.length);

  /// Percentage of an option (0..100), safe on zero total.
  static int percent(Map<int, List<String>> tally, int optionIndex) {
    final total = totalVoters(tally);
    if (total == 0) return 0;
    return (((tally[optionIndex]?.length ?? 0) / total) * 100).round();
  }

  /// My current ballot option (null = not voted).
  static int? myVote(Map<int, List<String>> tally, String myId) {
    for (final e in tally.entries) {
      if (e.value.contains(myId)) return e.key;
    }
    return null;
  }
}

/// Local helper kept off the Message model to stay additive.
extension PollMessageTimeX on Message {
  DateTime get createdAtAsTime =>
      DateTime.tryParse(createdAt)?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0);
}
