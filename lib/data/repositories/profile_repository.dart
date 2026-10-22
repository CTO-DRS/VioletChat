import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_exception.dart';
import '../models/models.dart';

/// Profiles, blocks, settings, avatars, account management.
class ProfileRepository {
  final SupabaseClient client;
  ProfileRepository(this.client);

  String get myId => client.auth.currentUser!.id;

  Future<Profile> getMyProfile() async {
    final row =
        await client.from('profiles').select().eq('id', myId).maybeSingle();
    if (row == null) throw const AppException('no_profile', 'لا يوجد ملف شخصي');
    return Profile.fromJson(row);
  }

  Future<void> updateMyProfile({
    String? displayName,
    String? bio,
    String? avatarPath,
  }) async {
    final patch = <String, dynamic>{
      if (displayName != null) 'display_name': displayName.trim(),
      if (bio != null) 'bio': bio.trim(),
      if (avatarPath != null) 'avatar_path': avatarPath,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (patch.isEmpty) return;
    await client.from('profiles').update(patch).eq('id', myId);
  }

  // ------------------------------------------------------------------
  // Username (v0.1.0) — RLS allows self-update; unique index on
  // lower(username) rejects duplicates with Postgres 23505.
  // ------------------------------------------------------------------
  static final RegExp usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');

  Future<void> updateUsername(String username) async {
    final u = username.trim();
    if (!usernamePattern.hasMatch(u)) {
      throw const AppException('validation',
          'اسم المستخدم: 3-20 حرفاً إنجليزياً أو أرقام أو _ فقط');
    }
    try {
      await client.from('profiles').update({
        'username': u,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', myId);
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        throw const AppException('username_taken',
            'اسم المستخدم محجوز مسبقاً — اختر اسماً آخر');
      }
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // Avatar (v0.1.0) — private 'avatars' bucket, path avatars/{uid}/{file}.
  // Storage RLS: insert/delete only under our own uid prefix; any
  // authenticated user may READ (avatars are meant to be seen by peers).
  // New upload gets a fresh timestamped filename, so every device's
  // avatar cache key changes naturally (no stale images).
  // ------------------------------------------------------------------
  Future<String> uploadAvatar(Uint8List jpegBytes) async {
    final uid = myId;
    final path = 'avatars/$uid/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await client.storage.from('avatars').uploadBinary(
          path,
          jpegBytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );
    // Fetch the previous path BEFORE overwriting the column, then clean
    // up all old avatar files best-effort (list+delete under our uid).
    try {
      final row = await client
          .from('profiles')
          .select('avatar_path')
          .eq('id', myId)
          .maybeSingle();
      final old = row?['avatar_path'] as String?;
      final objects = <String>[
        if (old != null && old.isNotEmpty) old,
      ];
      try {
        final listed = await client.storage.from('avatars').list(path: uid);
        for (final f in listed) {
          if (f.name.isNotEmpty) objects.add('avatars/$uid/${f.name}');
        }
      } catch (_) {/* listing is optional hygiene */}
      if (objects.isNotEmpty) {
        await client.storage.from('avatars').remove(objects);
      }
    } catch (_) {/* old-file cleanup is best-effort; never block upload */}
    await updateMyProfile(avatarPath: path);
    return path;
  }

  Future<void> removeAvatar() async {
    final row = await client
        .from('profiles')
        .select('avatar_path')
        .eq('id', myId)
        .maybeSingle();
    final old = row?['avatar_path'] as String?;
    await client.from('profiles').update({
      'avatar_path': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', myId);
    if (old != null && old.isNotEmpty) {
      try {
        await client.storage.from('avatars').remove([old]);
      } catch (_) {}
    }
  }

  /// Bytes of any user's avatar (authenticated read, RLS allows it).
  Future<Uint8List> downloadAvatar(String path) async {
    final bytes = await client.storage.from('avatars').download(path);
    return Uint8List.fromList(bytes);
  }

  // ------------------------------------------------------------------
  // Account (v0.1.0) — password + email via GoTrue updateUser.
  // ------------------------------------------------------------------
  /// Requires an authenticated session. Minimum length enforced by the
  /// caller (UI); GoTrue enforces its own server-side policy too.
  Future<void> changePassword(String newPassword) =>
      client.auth.updateUser(UserAttributes(password: newPassword));

  /// Sends a confirmation link to the NEW address (mailer_autoconfirm is
  /// false on this project); the email column only flips after the user
  /// clicks it. Subject to Supabase's mail rate limit (429).
  Future<void> changeEmail(String newEmail) =>
      client.auth.updateUser(UserAttributes(email: newEmail));

  Future<List<Profile>> searchUsers(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final rows = await client
        .from('profiles')
        .select()
        .or('username.ilike.%$q%,display_name.ilike.%$q%')
        .neq('id', myId)
        .limit(limit);
    return (rows as List)
        .map((r) => Profile.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<Profile?> getUser(String userId) async {
    final row =
        await client.from('profiles').select().eq('id', userId).maybeSingle();
    if (row == null) return null;
    return Profile.fromJson(row);
  }

  // ------------------------------------------------------------------
  // Blocks
  // ------------------------------------------------------------------
  Future<void> block(String userId) => client
      .from('blocked_users')
      .insert({'blocker_id': myId, 'blocked_id': userId});

  Future<void> unblock(String userId) => client
      .from('blocked_users')
      .delete()
      .eq('blocker_id', myId)
      .eq('blocked_id', userId);

  Future<List<Profile>> listBlocked() async {
    final rows = await client
        .from('blocked_users')
        .select('blocked:profiles!blocked_users_blocked_id_fkey(*)')
        .eq('blocker_id', myId);
    return (rows as List)
        .map((r) => Profile.fromJson(
            ((r as Map<String, dynamic>)['blocked'] as Map<String, dynamic>)))
        .toList();
  }

  // ------------------------------------------------------------------
  // Settings
  // ------------------------------------------------------------------
  Future<UserSettings> getSettings() async {
    try {
      final row = await client
          .from('user_settings')
          .select('settings')
          .eq('user_id', myId)
          .maybeSingle();
      final s = row?['settings'];
      if (s is Map<String, dynamic>) return UserSettings.fromJson(s);
      return const UserSettings();
    } catch (_) {
      return const UserSettings();
    }
  }

  Future<void> saveSettings(UserSettings s) async {
    await client.from('user_settings').upsert({
      'user_id': myId,
      'settings': s.toJson(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ------------------------------------------------------------------
  // Devices / sessions
  // ------------------------------------------------------------------
  Future<List<Device>> listDevices() async {
    final rows = await client
        .from('devices')
        .select()
        .eq('user_id', myId)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Device.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Sign out on OTHER devices (revoke their refresh tokens).
  Future<void> signOutOtherSessions() =>
      client.auth.signOut(scope: SignOutScope.others);

  /// Revoke a device row (its crypto sessions become unusable for
  /// future messages; the user must also sign out from it manually).
  Future<void> revokeDevice(String deviceId) => client
      .from('devices')
      .update({'revoked_at': DateTime.now().toUtc().toIso8601String()})
      .eq('user_id', myId)
      .eq('device_id', deviceId);

  // ------------------------------------------------------------------
  // Account deletion (SECURITY DEFINER RPC on the server)
  // ------------------------------------------------------------------
  Future<void> deleteMyAccount() async {
    await client.rpc('delete_own_account');
  }
}
