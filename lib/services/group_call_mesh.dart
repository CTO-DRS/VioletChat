/// Pure group-call mesh bookkeeping (v0.1.0) — no WebRTC, no I/O.
///
/// Deterministic offer rule (exactly ONE side offers per pair, so
/// offer glare is impossible by construction):
///
/// 1. Incumbent vs joiner  → the JOINER offers to the incumbent.
///    Incumbents announce themselves to a joiner with `group-present`.
/// 2. Joiner vs joiner (simultaneous joins) → the lexicographically
///    SMALLER user id offers; the bigger id stays quiet and waits for
///    that offer (it learns the peer from the offer itself).
///
/// The service layer executes what this class decides; this class
/// stays testable in isolation (see test/group_call_test.dart).
class GroupCallMesh {
  final String myId;

  /// Peers I currently believe are in the call (never includes me).
  final Set<String> peers = {};

  /// Am I in the "just joined, collecting presents" phase?
  bool collecting = false;

  GroupCallMesh(this.myId);

  bool get isAlone => peers.isEmpty;

  /// I accepted/started — mark me as a participant from now on.
  void beginJoin() => collecting = true;

  /// Collect phase over — I offer to everyone I queued.
  void endJoin() => collecting = false;

  void reset() {
    peers.clear();
    collecting = false;
  }

  /// Track a peer discovered via any path (present / offer / join).
  /// Returns true when the peer is NEW to me (caller should react).
  bool trackPeer(String peerId) {
    if (peerId == myId || peerId.isEmpty) return false;
    return peers.add(peerId);
  }

  /// Remove a leaving peer. Returns true when it was tracked.
  bool untrackPeer(String peerId) => peers.remove(peerId);

  /// Receiving `group-join` from [joinerId]:
  /// - as an incumbent, always reply `group-present`;
  /// - while I am ALSO collecting (simultaneous joins), only the
  ///   bigger id replies — the smaller one will offer me directly,
  ///   so an extra present would cause a double offer.
  bool shouldReplyPresent(String joinerId) {
    if (!collecting) return true; // incumbent → announce myself
    return myId.compareTo(joinerId) > 0;
  }

  /// Receiving `group-join` from [joinerId] while I am collecting:
  /// do I offer to them right away (simultaneous-join tie-break)?
  /// Only when they are NEWLY tracked — cross-channel reordering can
  /// deliver their `present` before their `join`, and a duplicate
  /// offer on top of that would trigger pointless renegotiation.
  bool shouldOfferToSimultaneousJoiner(String joinerId) {
    if (!collecting) return false; // incumbents wait for presents
    if (myId.compareTo(joinerId) < 0) {
      // I am smaller → I offer — but only once.
      return trackPeer(joinerId);
    }
    return false; // they will offer me
  }

  /// Receiving `group-present` from [peerId]: a new incumbent that I
  /// must offer to (once my collect window closes — or immediately
  /// if it already closed). Returns true when newly discovered.
  bool onPresent(String peerId) => trackPeer(peerId);
}
