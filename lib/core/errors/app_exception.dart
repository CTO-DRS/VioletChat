/// Typed application errors — no raw exceptions cross feature boundaries.
class AppException implements Exception {
  final String code;
  final String message;
  final Object? cause;

  const AppException(this.code, this.message, [this.cause]);

  @override
  String toString() => 'AppException($code): $message';

  // ---- Common factories ----
  static const AppException network =
      AppException('network', 'لا يوجد اتصال بالشبكة');
  static const AppException unauthorized =
      AppException('unauthorized', 'انتهت الجلسة — سجّل الدخول من جديد');
  static const AppException notFound =
      AppException('not_found', 'العنصر المطلوب غير موجود');

  static AppException server(Object? cause) =>
      AppException('server', 'خطأ من الخادم — أعد المحاولة', cause);

  static AppException crypto(Object? cause) =>
      AppException('crypto', 'تعذر فك تشفير هذه الرسالة بهذا الجهاز', cause);

  static AppException storage(Object? cause) =>
      AppException('storage', 'تعذر الوصول إلى التخزين', cause);

  static AppException validation(String msg) => AppException('validation', msg);
}
