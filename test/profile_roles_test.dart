import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/widgets/verified_badge.dart';

/// v0.1.1 — platform role + verification badge on the Profile model.
void main() {
  group('Profile role/isVerified mapping', () {
    test('parses admin + verified profile (full row)', () {
      final p = Profile.fromJson({
        'id': 'u1',
        'username': 'CTO.DRS',
        'display_name': 'CTO DRS',
        'role': 'admin',
        'is_verified': true,
        'created_at': '2026-10-21T19:38:19Z',
      });
      expect(p.role, 'admin');
      expect(p.isVerified, isTrue);
      expect(p.isPlatformAdmin, isTrue);
    });

    test('defaults to user/unverified when fields are absent', () {
      // older cached JSON / RPC rows that predate v0.1.1
      final p = Profile.fromJson({
        'id': 'u2',
        'username': 'someone',
        'display_name': '',
        'created_at': '2026-10-01T00:00:00Z',
      });
      expect(p.role, 'user');
      expect(p.isVerified, isFalse);
      expect(p.isPlatformAdmin, isFalse);
    });

    test('regular user stays non-admin', () {
      final p = Profile.fromJson({
        'id': 'u3',
        'username': 'normal',
        'role': 'user',
        'is_verified': false,
        'created_at': '',
      });
      expect(p.isPlatformAdmin, isFalse);
    });
  });

  group('VerifiedBadge / AdminChip widgets', () {
    testWidgets('badge renders an icon and nothing else', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: VerifiedBadge())),
      );
      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('admin chip shows Arabic label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AdminChip())),
      );
      expect(find.text('أدمن'), findsOneWidget);
    });
  });
}
