/// v0.1.12 — تنسيق نص الرسائل (تحليل محلي صرف).
///
/// النص يُختم مشفراً كما هو — هذا المحلل يعمل على النص المفكوك فقط
/// على جهاز المستقبل، فلا يتغير أي شيء في التشفير أو على الخادم.
///
/// الصيغ المدعومة (بلا تعشيش — السلوك flat ومحدد):
///   **غامق**   → FontWeight.w800
///   *مائل*     → FontStyle.italic
///   ~~شطب~~    → TextDecoration.lineThrough
///   `كود`      → خط أحادي + خلفية لونية خفيفة
///
/// قواعد الأمان (مُختبرة):
///   - العلامة غير المغلقة تبقى نصاً حرفياً — لا يُبتلع شيء أبداً.
///   - العلامات الفارغة (**** / ``) تبقى نصاً حرفياً.
///   - داخل `الكود` لا تُحلل صيغ أخرى — يُعرض حرفياً.
///   - أولوية التحليل: كود ← غامق ← شطب ← مائل؛ ما بين زوجٍ يُعاد
///     تحليله بالقواعد الأدنى فقط (فلا تتداخل مناطق العلامات).
///   - لا إعادة ترتيب للحروف إطلاقاً — اتجاه RTL محفوظ كما هو.
import 'package:flutter/material.dart';

/// نمط الكود داخل الفقاعة — يُمرر من الخارج ليحترم لون الفقاعة
/// (رسائلي على تدرج بنفسجي / رسائل الآخرين على سطح عادي).
class CodeSpanStyle {
  final String fontFamily;
  final Color background;
  final Color foreground;

  const CodeSpanStyle({
    this.fontFamily = 'monospace',
    required this.background,
    required this.foreground,
  });
}

typedef _Pair = ({
  int start, // بداية العلامة (شاملة علامة الفتح)
  int end, // نهاية حصرية (بعد علامة الغلق)
  int innerStart,
  int innerEnd,
});

sealed _Seg {}

class _Plain extends _Seg {
  final String text;
  _Plain(this.text);
}

class _Styled extends _Seg {
  final String text;
  final String style; // bold | italic | strike | code
  _Styled(this.text, this.style);
}

/// أزواج علامة واحدة متتالية (بلا تداخل). الزوج الفارغ يُتخطى
/// (يبقى حرفياً في النص الأب) — والزوج المفتوح بلا غلق يوقف المسح.
List<_Pair> _pairs(String text, String marker) {
  final out = <_Pair>[];
  var i = 0;
  while (i <= text.length - marker.length) {
    if (text.startsWith(marker, i)) {
      final j = text.indexOf(marker, i + marker.length);
      if (j == -1) break;
      if (j > i + marker.length) {
        out.add((
          start: i,
          end: j + marker.length,
          innerStart: i + marker.length,
          innerEnd: j,
        ));
        i = j + marker.length;
      } else {
        i += marker.length; // زوج فارغ — حرفي، أكمل بعده
      }
    } else {
      i++;
    }
  }
  return out;
}

const List<(String, String)> _rules = [
  ('`', 'code'),
  ('**', 'bold'),
  ('~~', 'strike'),
  ('*', 'italic'),
];

List<_Seg> _segment(String text) {
  for (final (marker, style) in _rules) {
    final ps = _pairs(text, marker);
    if (ps.isEmpty) continue;
    final out = <_Seg>[];
    var cursor = 0;
    for (final p in ps) {
      if (p.start > cursor) {
        out.addAll(_segment(text.substring(cursor, p.start)));
      }
      out.add(_Styled(text.substring(p.innerStart, p.innerEnd), style));
      cursor = p.end;
    }
    if (cursor < text.length) {
      out.addAll(_segment(text.substring(cursor)));
    }
    return out;
  }
  return [_Plain(text)];
}

/// الواجهة النقية: نص رسالة → قائمة قصاصات (نص، نمط).
/// تُستخدم في العرض وفي الاختبارات بلا أي اعتماد على Flutter.
List<({String text, String? style})> parseMessageSegments(String text) =>
    _segment(text)
        .map((s) => s is _Styled
            ? (text: s.text, style: s.style as String?)
            : (text: (s as _Plain).text, style: null))
        .toList();

/// هل يحوي النص أي صيغة على الإطلاق؟ (لتفادي بناء Rich بلا داعٍ).
bool hasMessageFormatting(String text) =>
    parseMessageSegments(text).any((s) => s.style != null);

/// بناء TextSpan جاهز للعرض داخل الفقاعات.
TextSpan buildMessageSpan(
  String text, {
  required TextStyle base,
  required CodeSpanStyle codeStyle,
}) {
  final segs = parseMessageSegments(text);
  if (segs.every((s) => s.style == null)) {
    return TextSpan(text: text, style: base);
  }
  return TextSpan(
    style: base,
    children: [
      for (final s in segs)
        switch (s.style) {
          'bold' => TextSpan(
              text: s.text,
              style: base.copyWith(fontWeight: FontWeight.w800)),
          'italic' => TextSpan(
              text: s.text,
              style: base.copyWith(fontStyle: FontStyle.italic)),
          'strike' => TextSpan(
              text: s.text,
              style: base.copyWith(decoration: TextDecoration.lineThrough)),
          'code' => TextSpan(
              text: s.text,
              style: base.copyWith(
                fontFamily: codeStyle.fontFamily,
                fontSize: base.fontSize != null ? base.fontSize! - 1 : null,
                background: Paint()..color = codeStyle.background,
                color: codeStyle.foreground,
              )),
          _ => TextSpan(text: s.text),
        },
    ],
  );
}
