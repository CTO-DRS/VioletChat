import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_exception.dart';
import '../models/models.dart';

/// Chats (direct + groups), members, invites, join requests.
class ChatRepository {
  final SupabaseClient client;
  ChatRepository(this.client);

  String get myId => client.auth.currentUser!.id;

  /// Race-safe direct chat creation (canonical pair + unique index +
  /// SECURITY DEFINER RPC with ON CONFLICT handling).
  Future<String> getOrCreateDirectChat(String otherUserId) async {
    final res = await client
        .rpc('get_or_create_direct_chat', params: {'p_other': otherUserId});
    if (res is Map && res['chat_id'] != null) return res['chat_id'] as String;
    throw AppException.server(res);
  }

  /// Load all my chats (direct + groups) with my role and unread hint.
  Future<List<Chat>> loadMyChats() async {
    final res = await client.rpc('get_my_chats');
    final rows = (res as List).cast<Map<String, dynamic>>();
    return rows.map((r) {
      final chat = Map<String, dynamic>.from(r);
      return Chat.fromJson(chat, myId);
    }).toList();
  }

  /// v0.1.0: flip MY OWN per-chat flags (pin / mute / archive) via
  /// SECURITY DEFINER RPC — chat_members intentionally has no UPDATE
  /// policy. Tri-state: true = set, false = clear, null = untouched.
  Future<void> setChatFlags(
    String chatId, {
    bool? pinned,
    bool? muted,
    bool? archived,
  }) =>
      client.rpc('set_chat_flags', params: {
        'p_chat_id': chatId,
        if (pinned != null) 'p_pinned': pinned,
        if (muted != null) 'p_muted': muted,
        if (archived != null) 'p_archived': archived,
      });

  Future<List<ChatMember>> loadMembers(String chatId) async {
    final rows = await client
        .from('chat_members')
        .select(
            'role, joined_at, profile:profiles!chat_members_user_id_fkey(*)')
        .eq('chat_id', chatId);
    return (rows as List)
        .map((r) => ChatMember.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------------------
  // Groups
  // ------------------------------------------------------------------
  Future<String> createGroup({
    required String name,
    String? description,
  }) async {
    final res = await client.rpc('create_group',
        params: {'p_name': name, 'p_description': description});
    if (res is Map && res['chat_id'] != null) return res['chat_id'] as String;
    throw AppException.server(res);
  }

  Future<void> updateGroupInfo({
    required String chatId,
    String? name,
    String? description,
    String? avatarPath,
  }) async {
    await client.rpc('update_group_info', params: {
      'p_chat_id': chatId,
      'p_name': name,
      'p_description': description,
      'p_avatar_path': avatarPath,
    });
  }

  /// Admin flow: add members then rotate the group key (the rotation
  /// wraps are uploaded via [uploadGroupKeyWraps] by the caller).
  Future<void> addGroupMembers(String chatId, List<String> userIds) async {
    await client.rpc('group_add_members',
        params: {'p_chat_id': chatId, 'p_user_ids': userIds});
  }

  Future<void> removeGroupMember(String chatId, String userId) async {
    await client.rpc('group_remove_member',
        params: {'p_chat_id': chatId, 'p_user_id': userId});
  }

  Future<void> leaveGroup(String chatId) async {
    await client.rpc('group_leave', params: {'p_chat_id': chatId});
  }

  Future<void> setMemberRole(String chatId, String userId, String role) async {
    await client.rpc('group_set_role',
        params: {'p_chat_id': chatId, 'p_user_id': userId, 'p_role': role});
  }

  /// Publish wraps of a NEW group key version for CURRENT members.
  /// wraps: List of {user_id, wrapped, nonce} — validated against
  /// actual current membership on the server.
  Future<int> startKeyVersion(String chatId) async {
    final res = await client
        .rpc('group_start_key_version', params: {'p_chat_id': chatId});
    return (res as num).toInt();
  }

  Future<void> uploadGroupKeyWraps(
      String chatId, int version, List<Map<String, dynamic>> wraps) async {
    await client.rpc('group_publish_wraps', params: {
      'p_chat_id': chatId,
      'p_version': version,
      'p_wraps': wraps,
    });
  }

  Future<int> latestKeyVersion(String chatId) async {
    final rows = await client
        .from('group_key_versions')
        .select('version')
        .eq('chat_id', chatId)
        .order('version', ascending: false)
        .limit(1);
    if ((rows as List).isEmpty) return 1;
    return (rows.first['version'] as num).toInt();
  }

  Future<({String wrapped, String nonce, int version})?> fetchMyWrap(
      String chatId, int version) async {
    final row = await client
        .from('group_key_wraps')
        .select('wrapped, nonce, version')
        .eq('chat_id', chatId)
        .eq('version', version)
        .eq('user_id', myId)
        .maybeSingle();
    if (row == null) return null;
    return (
      wrapped: row['wrapped'] as String,
      nonce: row['nonce'] as String,
      version: (row['version'] as num).toInt(),
    );
  }

  /// Who wrapped this version (to derive the wrap KEK we need the
  /// wrapper's identity public key -> fetch their device identity).
  Future<String?> wrapAuthorIdentityKey(String chatId, int version) async {
    final row = await client
        .from('group_key_wraps')
        .select('wrapped_by')
        .eq('chat_id', chatId)
        .eq('version', version)
        .eq('user_id', myId)
        .maybeSingle();
    final authorId = row?['wrapped_by'] as String?;
    if (authorId == null) return null;
    final dev = await client
        .from('devices')
        .select('identity_key')
        .eq('user_id', authorId)
        .order('created_at', ascending: true)
        .limit(1);
    if ((dev as List).isEmpty) return null;
    return dev.first['identity_key'] as String?;
  }

  // ------------------------------------------------------------------
  // Invite links + join requests
  // ------------------------------------------------------------------
  Future<String> createInviteLink(String chatId) async {
    final res =
        await client.rpc('group_create_invite', params: {'p_chat_id': chatId});
    return res as String;
  }

  Future<String> joinByInvite(String code) async {
    final res =
        await client.rpc('group_join_by_invite', params: {'p_code': code});
    if (res is Map && res['chat_id'] != null) return res['chat_id'] as String;
    throw AppException.server(res);
  }

  Future<List<JoinRequest>> listJoinRequests(String chatId) async {
    final rows = await client
        .from('join_requests')
        .select(
            'id, chat_id, status, created_at, profile:profiles!join_requests_user_id_fkey(*)')
        .eq('chat_id', chatId)
        .eq('status', 'pending')
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => JoinRequest.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> respondJoinRequest(String requestId, bool accept) async {
    await client.rpc('group_respond_join_request', params: {
      'p_request_id': requestId,
      'p_accept': accept,
    });
  }

  /// Group deletion (owner only) — cascades server-side.
  Future<void> deleteGroup(String chatId) =>
      client.rpc('group_delete', params: {'p_chat_id': chatId});
}
