import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../crypto/group_keys.dart';
import '../crypto/identity.dart';
import '../crypto/primitives.dart';
import '../data/models/models.dart';
import '../data/repositories/key_repository.dart';
import '../data/repositories/media_repository.dart';

/// v0.1.10 — encrypted friend stories (حالات).
///
/// Threat model matches the rest of Violet:
///   - ONE random 32-byte story key per story, generated client-side.
///   - The story body (caption + media descriptor) is sealed with that
///     key (AES-256-GCM) into violet_stories.body — the server stores
///     opaque bytes.
///   - The story key is WRAPPED for every device of every friend (plus
///     my own devices) with the same X25519+HKDF scheme used for group
///     keys (GroupKeys.wrapFor, synthetic domain «violet-stories»).
///     Recipients unwrap by trying the author's device identity keys.
///   - Media bytes are encrypted with their own random file key which
///     travels INSIDE the sealed body; the blob sits under
///     media/stories/{authorId}/… guarded by dedicated storage RLS.
///   - Views (who saw my story) are plaintext metadata — the same
///     exposure level as message receipts.
///   - Expiry: 24h server-side default; expired rows are filtered on
///     read and swept opportunistically via purge_expired_stories().
class StoryService {
  final SupabaseClient client;
  final KeyRepository keys;
  final MediaRepository media;
  final DeviceIdentity identity;

  StoryService(this.client, this.keys, this.media, this.identity);

  String get myId => client.auth.currentUser!.id;

  /// HKDF domain separation — MUST stay in sync with GroupKeys usage:
  /// wrap salt is «$chatId|$version» inside GroupKeys.wrapFor.
  static const String storyDomain = 'violet-stories';

  // ==================================================================
  // PUBLISH
  // ==================================================================

  /// Publish a story for [friendIds] (direct-chat peers). [imageBytes]
  /// null => text status; else an encrypted image story with caption.
  Future<StoryItem> publish({
    required List<String> friendIds,
    String? text,
    Uint8List? imageBytes,
    int? width,
    int? height,
  }) async {
    MediaInfo? mediaInfo;
    if (imageBytes != null) {
      final fileKey = Primitives.randomBytes(32);
      final (nonce, encrypted) = await Primitives.sealRandom(imageBytes, fileKey);
      final path = await media.uploadStory(encrypted);
      mediaInfo = MediaInfo(
        type: 'image',
        path: path,
        size: imageBytes.length,
        mime: 'image/jpeg',
        width: width,
        height: height,
        fileKey: Primitives.b64(fileKey),
        fileNonce: Primitives.b64(nonce),
      );
    }

    final bodyJson = jsonEncode({
      'kind': 'story',
      if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
      if (mediaInfo != null) 'media': mediaInfo.toJson(),
    });

    // One fresh key per story — sealed exactly once, no reuse concerns.
    final storyKey = Primitives.randomBytes(32);
    final (nonce, ct) = await Primitives.sealRandom(
        Primitives.bytesOf(bodyJson), storyKey);

    final inserted = await client.from('violet_stories').insert({
      'author_id': myId,
      'body': {'n': Primitives.b64(nonce), 'c': Primitives.b64(ct)},
    }).select('id, author_id, created_at, expires_at').single();

    final storyId = inserted['id'] as String;
    await _publishWraps(storyId, storyKey, [...friendIds, myId]);

    return StoryItem(
      id: storyId,
      authorId: myId,
      createdAt: inserted['created_at'] as String,
      expiresAt: inserted['expires_at'] as String,
      content: StoryContent(
          text: (text == null || text.trim().isEmpty) ? null : text.trim(),
          media: mediaInfo),
      decrypted: true,
    );
  }

  Future<void> _publishWraps(
      String storyId, Uint8List storyKey, List<String> recipientIds) async {
    final envelope = GroupKeyEnvelope(0, storyKey);
    final rows = <Map<String, dynamic>>[];
    for (final uid in recipientIds.toSet()) {
      try {
        final bundles = await keys.fetchBundles(uid);
        for (final b in bundles) {
          final (wrapped, nonce) = await GroupKeys.wrapFor(
            groupKey: envelope,
            wrapperIdentity: identity.ik,
            memberIdentityPubB64: b.identityKey,
            chatId: storyDomain,
          );
          rows.add({
            'story_id': storyId,
            'user_id': uid,
            'device_id': b.deviceId ?? '',
            'wrapped': wrapped,
            'nonce': nonce,
          });
        }
      } catch (_) {
        // A friend without published bundles simply cannot receive this
        // story key — skip instead of failing the whole publish.
      }
    }
    if (rows.isNotEmpty) {
      await client.from('violet_story_wraps').insert(rows);
    }
  }

  // ==================================================================
  // RING FETCH
  // ==================================================================

  /// All non-expired stories authored by me or any of [friendIds],
  /// ascending by created_at. Attempts an opportunistic server sweep
  /// of expired rows (best-effort, never fatal).
  Future<List<StoryItem>> fetchRing(List<String> friendIds) async {
    try {
      await client.rpc('purge_expired_stories');
    } catch (_) {}

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final rows = await client
        .from('violet_stories')
        .select('id, author_id, body, created_at, expires_at')
        .inFilter('author_id', [...friendIds.toSet(), myId])
        .gt('expires_at', nowIso)
        .order('created_at', ascending: true)
        .limit(200);

    final out = <StoryItem>[];
    for (final raw in (rows as List)) {
      final row = raw as Map<String, dynamic>;
      out.add(await _decryptRow(row));
    }
    return out;
  }

  Future<StoryItem> _decryptRow(Map<String, dynamic> row) async {
    final authorId = row['author_id'] as String;
    final body = (row['body'] as Map<String, dynamic>?);
    try {
      if (body == null) throw StateError('missing body');
      final storyKey = await _resolveStoryKey(row['id'] as String, authorId);
      final plain = await Primitives.open(
        Primitives.unb64(body['c'] as String),
        storyKey,
        Primitives.unb64(body['n'] as String),
      );
      final json = jsonDecode(Primitives.utf8s(plain)) as Map<String, dynamic>;
      return StoryItem(
        id: row['id'] as String,
        authorId: authorId,
        createdAt: row['created_at'] as String,
        expiresAt: row['expires_at'] as String,
        content: StoryContent(
          text: json['text'] as String?,
          media: MediaInfo.fromJson(
              json['media'] as Map<String, dynamic>?),
        ),
        decrypted: true,
      );
    } catch (_) {
      return StoryItem(
        id: row['id'] as String,
        authorId: authorId,
        createdAt: row['created_at'] as String,
        expiresAt: row['expires_at'] as String,
        content: null,
        decrypted: false,
      );
    }
  }

  /// My own stories: re-fetch the wrap made for one of MY devices.
  /// Friends' stories: unwrap with the author's device identity keys
  /// (try each bundle — the AEAD auth tag proves the right one).
  Future<Uint8List> _resolveStoryKey(String storyId, String authorId) async {
    final wraps = await client
        .from('violet_story_wraps')
        .select('user_id, device_id, wrapped, nonce')
        .eq('story_id', storyId)
        .eq('user_id', myId)
        .limit(10);
    if (wraps.isEmpty) {
      throw StateError('no wrap for me on story $storyId');
    }

    final authorBundles = await keys.fetchBundles(authorId);
    final authorPubs =
        authorBundles.map((b) => b.identityKey).toSet().toList();

    for (final w in wraps) {
      final wrapped = w['wrapped'] as String;
      final nonce = w['nonce'] as String;
      for (final pub in authorPubs) {
        try {
          final key = await GroupKeys.unwrap(
            wrappedB64: wrapped,
            nonceB64: nonce,
            version: 0,
            myIdentity: identity.ik,
            wrapperIdentityPubB64: pub,
            chatId: storyDomain,
          );
          return key.key;
        } catch (_) {
          // wrong (device) identity — try the next
        }
      }
    }
    throw StateError('story $storyId key unwrap failed');
  }

  // ==================================================================
  // DELETE
  // ==================================================================

  /// Author-only delete (RLS enforced). Media paths inside the body
  /// are best-effort removed as well.
  Future<void> deleteStory(StoryItem s) async {
    if (s.authorId == myId && s.content?.media != null) {
      try {
        await media.delete(s.content!.media!.path);
      } catch (_) {}
    }
    await client.from('violet_stories').delete().eq('id', s.id);
  }

  // ==================================================================
  // VIEWS
  // ==================================================================

  Future<void> markViewed(String storyId) => client
      .from('violet_story_views')
      .upsert({'story_id': storyId, 'user_id': myId});

  /// Viewers of MY stories: storyId -> (userId -> viewedAt).
  Future<Map<String, Map<String, String>>> viewers(List<String> myStoryIds) async {
    if (myStoryIds.isEmpty) return {};
    final rows = await client
        .from('violet_story_views')
        .select('story_id, user_id, viewed_at')
        .inFilter('story_id', myStoryIds);
    final out = <String, Map<String, String>>{};
    for (final raw in (rows as List)) {
      final r = raw as Map<String, dynamic>;
      (out[r['story_id'] as String] ??= {})[r['user_id'] as String] =
          (r['viewed_at'] ?? '') as String;
    }
    return out;
  }

  /// Display names for viewer chips (id -> profile map).
  Future<Map<String, Profile>> profilesOf(Set<String> ids) async {
    if (ids.isEmpty) return {};
    final rows = await client
        .from('profiles')
        .select('id, username, display_name, avatar_path, bio, created_at')
        .inFilter('id', ids.toList());
    final out = <String, Profile>{};
    for (final raw in (rows as List)) {
      final p = Profile.fromJson(raw as Map<String, dynamic>);
      out[p.id] = p;
    }
    return out;
  }
}

/// Decrypted story payload (inside the sealed body).
class StoryContent {
  final String? text;
  final MediaInfo? media;

  const StoryContent({this.text, this.media});

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) && media == null;
}

/// One ring entry. For rows that failed to decrypt, [content] is null
/// and [decrypted] false (rendered as a locked placeholder).
class StoryItem {
  final String id;
  final String authorId;
  final String createdAt;
  final String expiresAt;
  final StoryContent? content;
  final bool decrypted;

  const StoryItem({
    required this.id,
    required this.authorId,
    required this.createdAt,
    required this.expiresAt,
    this.content,
    this.decrypted = true,
  });

  DateTime get createdAtDate =>
      DateTime.tryParse(createdAt)?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0);

  DateTime get expiresAtDate =>
      DateTime.tryParse(expiresAt)?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0);

  bool get isExpired =>
      expiresAtDate.isBefore(DateTime.now().toUtc());
}
