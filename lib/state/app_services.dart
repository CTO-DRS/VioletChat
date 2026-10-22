import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/local_database.dart';
import '../core/storage/message_cache.dart';
import '../crypto/identity.dart';
import '../data/repositories/call_repository.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/key_repository.dart';
import '../data/repositories/media_repository.dart';
import '../data/repositories/message_repository.dart';
import '../data/repositories/profile_repository.dart';
import '../services/auth_service.dart';
import '../services/call_service.dart';
import '../services/call_transport.dart';
import '../services/group_call_service.dart';
import '../services/media_service.dart';
import '../services/message_crypto_service.dart';
import '../services/notification_service.dart';
import '../services/presence_service.dart';
import '../services/push_service.dart';
import '../services/realtime_service.dart';
import '../services/session_manager.dart';
import '../services/sync_engine.dart';

/// Composition root — one place builds and owns the service graph.
class AppServices {
  AppServices._();

  static AppServices? _instance;
  static AppServices get I {
    final s = _instance;
    if (s == null) throw StateError('AppServices not initialised');
    return s;
  }

  late final SupabaseClient client;
  late final AuthService auth;
  late final ConnectivityService connectivity;
  late final DeviceIdentity identity;
  late final KeyRepository keys;
  late final ProfileRepository profiles;
  late final ChatRepository chats;
  late final MessageRepository messages;
  late final MediaRepository mediaRepo;
  late final CallRepository calls;
  late final SessionManager sessionMgr;
  late final MessageCryptoService crypto;
  late final MessageCache cache;
  late final SyncEngine sync;
  late final RealtimeService realtime;
  late final NotificationService notifications;
  late final MediaService mediaService;
  late final CallService call;
  late final GroupCallService groupCall;
  late final CallTransport callTransport;
  late final PresenceService presence;

  static bool _booting = false;

  static Future<AppServices> create() async {
    if (_instance != null) return _instance!;
    if (_booting) throw StateError('concurrent bootstrap');
    _booting = true;
    try {
      final s = AppServices._();
      await s._init();
      _instance = s;
      return s;
    } finally {
      _booting = false;
    }
  }

  Future<void> _init() async {
    client = Supabase.instance.client;

    // Local DB + its encryption key bridge.
    IdentityBridge.register(IdentityManager.dbKey);
    await LocalDatabase.instance;
    MessageCache.myId = client.auth.currentUser?.id;

    identity = await IdentityManager.loadOrCreate();

    auth = AuthService(client);
    connectivity = ConnectivityService();
    keys = KeyRepository(client);
    profiles = ProfileRepository(client);
    chats = ChatRepository(client);
    messages = MessageRepository(client);
    mediaRepo = MediaRepository(client);
    calls = CallRepository(client);
    sessionMgr = SessionManager(client, keys, identity);
    crypto = MessageCryptoService(sessionMgr, chats, keys, identity);
    cache = const MessageCache();
    notifications = NotificationService();
    mediaService = MediaService(mediaRepo, crypto);
    callTransport = CallTransport(client);
    call = CallService(client, notifications, callTransport);
    groupCall = GroupCallService(client, notifications, callTransport);
    // One personal signaling channel feeds both call services; each
    // filters by its own scope ('p2p' vs 'group').
    callTransport.onSignal = (msg) {
      unawaited(call.handleSignal(msg));
      unawaited(groupCall.handleSignal(msg));
    };
    presence = PresenceService(client);
    sync = SyncEngine(auth, messages, chats, crypto, cache, connectivity);
    realtime = RealtimeService(client, sync, sessionMgr, crypto);

    await connectivity.start();
    AppLogger.i('boot', 'AppServices ready');
  }

  /// Post-login steps: register device keys, verify identity match,
  /// ensure profile, start sync + realtime.
  Future<void> onSignedIn() async {
    MessageCache.myId = client.auth.currentUser?.id;

    // 1) Register/refresh this device's key bundle.
    final deviceName = await _deviceLabel();
    await keys.registerDevice(identity, deviceName, 'android');
    await keys.topUpOneTimePrekeys(identity);

    // 2) Identity continuity check (local vs server for THIS device).
    //    A mismatch after reinstall means the local identity is new —
    //    the register call above has already replaced the row, and the
    //    security screen surfaces the re-registration state.
    final ok = await keys.verifyLocalIdentityMatchesServer(identity);
    if (!ok) {
      AppLogger.w('boot', 'identity mismatch after registration');
    }

    // 3) Realtime + notifications + presence + sync engine.
    await notifications.init();
    // 4) System push (FCM) — fail-soft: without google-services.json or
    //    with a broken setup, in-app notifications keep working.
    final userId = client.auth.currentUser?.id;
    if (userId != null) {
      await PushService.register(userId, client);
    }
    await realtime.start(connectivity: connectivity.changes);
    // Always-on personal call-signaling channel (v0.1.0) — this is
    // what makes incoming calls actually ring (was broken before).
    await callTransport.start();
    presence.start();
    sync.start();
  }

  Future<void> onSignedOut() async {
    await PushService.deregister(null, client);
    await realtime.stop();
    await callTransport.stop();
    presence.stop();
    sync.stop();
    await notifications.cancelAll();
    await LocalDatabase.wipeAll();
    MessageCache.myId = null;
  }

  Future<String> _deviceLabel() async {
    try {
      final plugin = DeviceInfoPlugin();
      final android = await plugin.androidInfo;
      final brand = android.brand;
      final model = android.model;
      final label = '$brand $model'.trim();
      return label.isEmpty ? 'هاتف Android' : label;
    } catch (_) {
      return 'هاتف Android';
    }
  }
}
