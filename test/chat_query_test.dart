import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/features/chats/chat_query.dart';

/// اختبارات v0.1.6 — التصفية المحلية الفورية (كل زر له وظيفة):
/// شريط البحث يصفّي القائمة المعروضة لحظياً بدل فتح شاشة البحث.
void main() {
  Profile peer(String id, String username, String display) => Profile(
        id: id,
        username: username,
        displayName: display,
        bio: '',
        createdAt: '2026-01-01',
        role: 'user',
      );

  Chat direct(Profile p) =>
      Chat(id: 'c-${p.id}', type: 'direct', peer: p, createdAt: 'x');

  Chat mkGroup(String name) =>
      Chat(id: 'g-$name', type: 'group', name: name, createdAt: 'x');

  group('normalizeAr — التطبيع العربي المتسامح', () {
    test('يوحّد الألف والياء والتاء المربوطة', () {
      expect(normalizeAr('أحمد'), normalizeAr('احمد'));
      expect(normalizeAr('إبراهيم'), normalizeAr('ابراهيم'));
      expect(normalizeAr('مستشفى'), normalizeAr('مستشفی'));
      expect(normalizeAr('فاطمة'), normalizeAr('فاطمه'));
    });

    test('يحذف التشكيل ويصغّر اللاتيني', () {
      expect(normalizeAr('مُحَمَّد'), 'محمد');
      expect(normalizeAr('CTO'), 'cto');
    });

    test('يوحّد الياء/الكاف الفارسية مع العربية', () {
      // ی (U+06CC) وک (U+06A9) شائعتان من كيبورد فارسية/أردية —
      // يجب أن تطابقا الياء/الكاف العربية.
      expect(normalizeAr('مستشفی'), 'مستشفي'); // ی ← ي
      expect(normalizeAr('نوک'), normalizeAr('نوك')); // ک ← ك
      expect(normalizeAr('کتاب'), normalizeAr('كتاب'));
    });
  });

  group('chatMatchesQuery — مطابقة المحادثة', () {
    final ali = peer('u1', 'ali_dev', 'علي الحسن');
    final devGroup = mkGroup('فريق التطوير');

    test('الاستعلام الفارغ يطابق كل شيء', () {
      expect(chatMatchesQuery(direct(ali), ''), isTrue);
      expect(chatMatchesQuery(direct(ali), '   '), isTrue);
    });

    test('يطابق اسم الطرف ومعرّفه مع التسامح العربي', () {
      expect(chatMatchesQuery(direct(ali), 'علي'), isTrue);
      expect(chatMatchesQuery(direct(ali), 'الحسَن'), isTrue); // بتشكيل
      expect(chatMatchesQuery(direct(ali), 'ali'), isTrue);
      expect(chatMatchesQuery(direct(ali), 'ALI'), isTrue);
    });

    test('يطابق المجموعات بالاسم والوصف', () {
      expect(chatMatchesQuery(devGroup, 'تطوير'), isTrue);
      expect(chatMatchesQuery(devGroup, 'غير موجود'), isFalse);
    });

    test('اللاصق لا يطابق — substrings فقط', () {
      expect(chatMatchesQuery(direct(ali), 'علي الحسن'), isTrue);
      expect(chatMatchesQuery(direct(ali), 'حسن علي'), isFalse);
    });
  });

  group('filterChats / filterProfiles — التصفية الفعلية', () {
    test('يرجع نسخة كاملة عند فراغ الاستعلام (لا مرجع مشترك)', () {
      final src = <Chat>[direct(peer('u2', 'sara', 'سارة'))];
      final out = filterChats(src, '');
      expect(out, hasLength(1));
      expect(identical(out, src), isFalse);
    });

    test('يصفّي المحادثات والأصدقاء بذات المنطق', () {
      final ali = peer('u1', 'ali_dev', 'علي الحسن');
      final sara = peer('u2', 'sara', 'سارة');
      final chats = [direct(ali), direct(sara), mkGroup('فريق التطوير')];
      expect(filterChats(chats, 'تطوير'), hasLength(1));
      expect(filterChats(chats, 'ساره'), hasLength(1));
      expect(filterProfiles([ali, sara], 'ali'), hasLength(1));
      expect(filterProfiles([ali, sara], 'سارة'), hasLength(1));
    });
  });
}
