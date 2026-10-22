import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:violet_chat/features/auth/auth_screen.dart';
import 'package:violet_chat/state/auth_controller.dart';
import 'package:violet_chat/theme/app_theme.dart';

/// Reproduces the user-reported "gray box instead of the login form"
/// (release-mode ErrorWidget = gray box when a build/layout throws).
///
/// We pump AuthScreen exactly like NexoraApp does (theme + RTL +
/// provider) and then scan the tree for any widget whose runtimeType
/// is ErrorWidget — plus catch every FlutterError reported.
class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final errors = <FlutterErrorDetails>[];
  bool errorWidgetFound = false;

  testWidgets(
    'AuthScreen builds with zero errors — email/password fields visible',
    (tester) async {
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthController>.value(
              value: _FakeAuthController(),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('ar'),
            // Same delegates as NexoraApp (the real app) — v0.1.0.
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('ar'), Locale('en')],
            builder: (context, child) => Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            ),
            home: const AuthScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Restore first so test failures surface normally.
      FlutterError.onError = originalOnError;

      // Scan for ErrorWidget anywhere in the tree (gray box in release).
      void visit(Element e) {
        if (e.widget.runtimeType.toString() == 'ErrorWidget') {
          errorWidgetFound = true;
        }
        e.visitChildren(visit);
      }

      visit(tester.element(find.byType(Scaffold).first));

      // Dump captured build errors FIRST (root cause of the gray box).
      if (errors.isNotEmpty) {
        // ignore: avoid_print
        print('==== CAPTURED FLUTTER ERRORS (${errors.length}) ====');
        for (final e in errors) {
          // ignore: avoid_print
          print('--- ERROR: ${e.exception}');
          // ignore: avoid_print
          print(e.stack.toString().split('\n').take(14).join('\n'));
        }
      }

      expect(
        errorWidgetFound,
        isFalse,
        reason: 'ErrorWidget (gray box in release) found in the tree!',
      );

      expect(find.text('البريد الإلكتروني'), findsOneWidget,
          reason: 'email field must exist');
      expect(find.text('كلمة المرور'), findsOneWidget,
          reason: 'password field must exist');
      expect(find.text('دخول'), findsOneWidget,
          reason: 'submit button must exist');
      // SegmentedButton<_AuthMode> — generic type is private, so assert
      // on the visible segment labels instead of the widget type.
      expect(find.text('تسجيل الدخول'), findsOneWidget,
          reason: 'login segment must exist');
      expect(find.text('حساب جديد'), findsOneWidget,
          reason: 'signup segment must exist');

      if (errors.isNotEmpty) {
        fail(
          'FlutterErrors during AuthScreen build:\n'
          '${errors.map((e) => '${e.exception}\n${e.stack}').join('\n----\n')}',
        );
      }
    },
  );
}
