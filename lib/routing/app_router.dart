import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/models.dart';
import '../features/calls/call_screen.dart';
import '../features/calls/group_call_screen.dart';
import '../features/chats/chats_screen.dart';
import '../features/groups/create_group_screen.dart';
import '../features/groups/group_info_screen.dart';
import '../features/messages/media_gallery_screen.dart';
import '../features/messages/chat_screen.dart';
import '../features/messages/starred_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/security_screen.dart';
import '../features/settings/settings_screen.dart';
import '../state/chats_controller.dart';

/// Named routes — simple and explicit.
class AppRoutes {
  static const String chats = '/';
  static const String chat = '/chat';
  static const String search = '/search';
  static const String profile = '/profile';
  static const String createGroup = '/groups/new';
  static const String groupInfo = '/groups/info';
  static const String settings = '/settings';
  static const String security = '/settings/security';
  static const String starred = '/starred';
  static const String mediaGallery = '/chat/media';
  static const String call = '/call';
  static const String groupCall = '/group-call';
}

class AppRouter {
  /// v0.1.0: global navigator key — notification taps deep-link into
  /// a chat from outside the widget tree (local notif + FCM taps).
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'nexora-nav');

  /// Deep-link helper: open a chat by id using the chats already
  /// cached in memory. Returns false when unknown (e.g. chat list not
  /// loaded yet) — the caller decides whether to fall back to boot.
  static bool openChatById(String chatId) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    final chats = ctx.read<ChatsController>().chats;
    Chat? match;
    for (final c in chats) {
      if (c.id == chatId) {
        match = c;
        break;
      }
    }
    if (match == null) return false;
    navigatorKey.currentState
        ?.pushNamedAndRemoveUntil(AppRoutes.chat, (r) => r.isFirst,
            arguments: match);
    return true;
  }

  static Route<dynamic> route(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.chats:
        return _root(const ChatsScreen(), settings);
      case AppRoutes.chat:
        final chat = settings.arguments as Chat;
        return _detail(ChatScreen(chat: chat), settings);
      case AppRoutes.search:
        // v0.1.6: وسيط اختياري — استعلام مبدئي (مثلاً معرّف صديق من
        // ورقة «إضافة صديق بالمعرّف») يُعبّأ ويُشغّل البحث عند الفتح.
        final initialQuery = settings.arguments is String
            ? settings.arguments as String
            : null;
        return _detail(SearchScreen(initialQuery: initialQuery), settings);
      case AppRoutes.profile:
        return _detail(const ProfileScreen(), settings);
      case AppRoutes.createGroup:
        return _detail(const CreateGroupScreen(), settings);
      case AppRoutes.groupInfo:
        final chat = settings.arguments as Chat;
        return _detail(GroupInfoScreen(chat: chat), settings);
      case AppRoutes.settings:
        return _detail(const SettingsScreen(), settings);
      case AppRoutes.security:
        return _detail(const SecurityScreen(), settings);
      case AppRoutes.starred:
        return _detail(const StarredScreen(), settings);
      case AppRoutes.mediaGallery:
        final chat = settings.arguments as Chat;
        return _detail(MediaGalleryScreen(chat: chat), settings);
      case AppRoutes.call:
        final args = settings.arguments as CallRouteArgs;
        return _fade(
            CallScreen(
                chat: args.chat, outgoing: args.outgoing, video: args.video),
            settings);
      case AppRoutes.groupCall:
        final args = settings.arguments as GroupCallRouteArgs;
        return _fade(
            GroupCallScreen(
              chat: args.chat,
              outgoing: args.outgoing,
              video: args.video,
              memberIds: args.memberIds,
            ),
            settings);
      default:
        return _root(const ChatsScreen(), settings);
    }
  }

  /// v0.1.0 — detail pages slide in from the leading edge (left in RTL)
  /// with a subtle parallax offset + fade, so «into the conversation»
  /// reads as forward motion. Previously every route was the same fade.
  static PageRouteBuilder _detail(Widget page, RouteSettings s) {
    return PageRouteBuilder(
      settings: s,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic);
        // RTL-aware: forward motion enters from the left edge and slides
        // right into place (the app is fixed-RTL, Arabic-first).
        final slide =
            Tween<Offset>(begin: const Offset(-0.12, 0), end: Offset.zero)
                .animate(curved);
        return SlideTransition(
          position: slide,
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  /// Root (chats) gets a gentle fade+scale so back navigation settles.
  static PageRouteBuilder _root(Widget page, RouteSettings s) {
    return PageRouteBuilder(
      settings: s,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        final scale = Tween<double>(begin: 0.98, end: 1).animate(curved);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
    );
  }

  /// Call screens stay a pure fade — full-screen dark surfaces where a
  /// slide would feel wrong.
  static PageRouteBuilder _fade(Widget page, RouteSettings s) {
    return PageRouteBuilder(
      settings: s,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    );
  }
}

class CallRouteArgs {
  final Chat chat;
  final bool outgoing;
  final bool video;
  const CallRouteArgs(this.chat, this.outgoing, this.video);
}

class GroupCallRouteArgs {
  final Chat chat;
  final bool outgoing;
  final bool video;
  final List<String> memberIds;
  const GroupCallRouteArgs(
    this.chat, {
    required this.outgoing,
    required this.video,
    required this.memberIds,
  });
}
