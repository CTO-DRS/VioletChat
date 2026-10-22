import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';

/// Connectivity + auth session glue.
class AuthService {
  final SupabaseClient client;
  AuthService(this.client);

  bool get isSignedIn => client.auth.currentUser != null;
  String? get userId => client.auth.currentUser?.id;
  String? get email => client.auth.currentUser?.email;

  /// emailRedirectTo lands the confirmation email link on the hosted
  /// verification site (success/error page in Arabic) instead of the
  /// Supabase default Site URL. The branded email templates also carry
  /// their own redirect_to — this is defence in depth so the flow stays
  /// correct even if a template ever reverts (docs/EMAIL_SETUP.md).
  Future<void> signUp(String email, String password, String username) async {
    await client.auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: AppConfig.emailConfirmRedirectUrl,
      data: {
        'username': username,
      },
    );
  }

  Future<void> signIn(String email, String password) =>
      client.auth.signInWithPassword(email: email, password: password);

  Future<void> signOut() => client.auth.signOut();

  /// redirectTo → hosted reset-password page (set a new password in the
  /// browser, then sign in with it in the app).
  Future<void> resetPassword(String email) => client.auth.resetPasswordForEmail(
        email,
        redirectTo: AppConfig.emailResetRedirectUrl,
      );

  Stream<AuthState> get authChanges => client.auth.onAuthStateChange;
}

/// Reactive connectivity state.
class ConnectivityService {
  final _controller = StreamController<bool>.broadcast();
  bool _online = true;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool get isOnline => _online;
  Stream<bool> get changes => _controller.stream;

  Future<void> start() async {
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet != _online) {
        _online = hasNet;
        AppLogger.i('connectivity', hasNet ? 'online' : 'offline');
        _controller.add(_online);
      }
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
