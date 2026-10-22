// v0.1.2 — compile smoke: the release build compiles every screen
// library, but `flutter test` only compiles what tests transitively
// import. The v0.1.2 build failed at Gradle (after 4 minutes) on
// screen-only errors that tests never saw. Importing ALL screen
// libraries here forces the VM to compile them during the 1-minute
// test step — build-breaking typos fail fast, before Gradle runs.
import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/features/chats/chats_screen.dart';
import 'package:violet_chat/features/contacts/new_chat_picker_screen.dart';
import 'package:violet_chat/features/messages/chat_screen.dart';
import 'package:violet_chat/features/messages/media_gallery_screen.dart';
import 'package:violet_chat/features/messages/starred_screen.dart';
import 'package:violet_chat/features/profile/profile_screen.dart';
import 'package:violet_chat/features/search/search_screen.dart';
import 'package:violet_chat/features/settings/settings_screen.dart';
import 'package:violet_chat/features/settings/security_screen.dart';
import 'package:violet_chat/features/groups/create_group_screen.dart';
import 'package:violet_chat/features/groups/group_info_screen.dart';
import 'package:violet_chat/features/admin/admin_panel_screen.dart';
import 'package:violet_chat/features/auth/auth_screen.dart';
import 'package:violet_chat/features/calls/call_screen.dart';
import 'package:violet_chat/features/calls/group_call_screen.dart';
import 'package:violet_chat/routing/app_router.dart';
import 'package:violet_chat/theme/app_theme.dart';

// Touch the imported symbols so nothing is tree-shaken pre-compile.
void main() {
  test('screens compile (smoke)', () {
    expect(ChatsScreen, isNotNull);
    expect(NewChatPickerScreen, isNotNull); // v0.1.7 «محادثة جديدة»
    expect(ChatScreen, isNotNull);
    expect(MediaGalleryScreen, isNotNull);
    expect(StarredScreen, isNotNull);
    expect(ProfileScreen, isNotNull);
    expect(SearchScreen, isNotNull);
    expect(SettingsScreen, isNotNull);
    expect(SecurityScreen, isNotNull);
    expect(CreateGroupScreen, isNotNull);
    expect(GroupInfoScreen, isNotNull);
    expect(AdminPanelScreen, isNotNull);
    expect(AuthScreen, isNotNull);
    expect(CallScreen, isNotNull);
    expect(GroupCallScreen, isNotNull);
    expect(AppRoutes.chats, isNotEmpty);
    expect(AppRoutes.newChat, isNotEmpty); // v0.1.7 المسار الجديد
    expect(AppTheme.dark(), isNotNull);
  });
}
