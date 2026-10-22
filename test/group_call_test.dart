import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/services/group_call_mesh.dart';

/// Pure mesh bookkeeping tests (v0.1.0) — the deterministic offer rule
/// that makes the WebRTC mesh glare-free by construction:
///   1. joiner offers to incumbents (incumbents only answer presents)
///   2. two simultaneous joiners: the lexicographically smaller id
///      offers; the bigger waits for that offer.
void main() {
  group('GroupCallMesh — incumbent vs joiner', () {
    test('incumbent replies present to a joining peer', () {
      final mesh = GroupCallMesh('aaa');
      mesh.endJoin(); // not collecting → incumbent
      expect(mesh.shouldReplyPresent('bbb'), isTrue);
    });

    test('incumbent never offers first — only the joiner does', () {
      final mesh = GroupCallMesh('aaa');
      mesh.endJoin();
      expect(mesh.shouldOfferToSimultaneousJoiner('bbb'), isFalse);
    });

    test('joiner tracks incumbents via present and dedupes', () {
      final mesh = GroupCallMesh('ccc');
      mesh.beginJoin();
      expect(mesh.onPresent('aaa'), isTrue);
      expect(mesh.onPresent('bbb'), isTrue);
      // duplicate present must not create a second offer target
      expect(mesh.onPresent('aaa'), isFalse);
      expect(mesh.peers, containsAll(['aaa', 'bbb']));
      expect(mesh.peers.contains('ccc'), isFalse);
    });

    test('simultaneous join: smaller id offers, bigger stays quiet', () {
      final smaller = GroupCallMesh('aaa');
      final bigger = GroupCallMesh('bbb');
      smaller.beginJoin();
      bigger.beginJoin();
      // both see the other's join event:
      expect(smaller.shouldOfferToSimultaneousJoiner('bbb'), isTrue);
      expect(bigger.shouldOfferToSimultaneousJoiner('aaa'), isFalse);
      // the bigger id may still reply present (harmless: the smaller
      // side dedupes it), but never offers.
      expect(bigger.shouldReplyPresent('aaa'), isTrue);
      // the smaller one tracked the bigger already from the join event
      expect(smaller.peers.contains('bbb'), isTrue);
      // reordering: a late duplicate join must NOT cause a 2nd offer
      expect(smaller.shouldOfferToSimultaneousJoiner('bbb'), isFalse);
    });
  });

  group('GroupCallMesh — lifecycle bookkeeping', () {
    test('self id and empty ids are never tracked as peers', () {
      final mesh = GroupCallMesh('me');
      expect(mesh.trackPeer('me'), isFalse);
      expect(mesh.trackPeer(''), isFalse);
      expect(mesh.peers, isEmpty);
    });

    test('untrackPeer removes and reports membership', () {
      final mesh = GroupCallMesh('me');
      mesh.trackPeer('p1');
      expect(mesh.untrackPeer('p1'), isTrue);
      expect(mesh.untrackPeer('p1'), isFalse);
      expect(mesh.isAlone, isTrue);
    });

    test('reset clears everything (new call in same chat)', () {
      final mesh = GroupCallMesh('me');
      mesh.beginJoin();
      mesh.trackPeer('p1');
      mesh.reset();
      expect(mesh.collecting, isFalse);
      expect(mesh.peers, isEmpty);
    });

    test('leave of an unknown peer is a no-op', () {
      final mesh = GroupCallMesh('me');
      expect(mesh.untrackPeer('ghost'), isFalse);
    });
  });
}
