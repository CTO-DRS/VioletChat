/// Global constants shared across features.
class AppConstants {
  AppConstants._();

  // Message kinds
  static const String kindText = 'text';
  static const String kindSystem = 'system';
  static const String kindMedia = 'media';

  /// v0.1.10: encrypted poll message — question+options live INSIDE the
  /// ciphertext (E2E). Votes ride as kind=pollVote rows replying to it.
  static const String kindPoll = 'poll';

  /// v0.1.10: one encrypted ballot (option index) — reply_to = poll row.
  /// Hidden from the transcript; tallied client-side (last vote wins).
  static const String kindPollVote = 'pollVote';

  /// v0.1.11: a reply to a friend's story, delivered INSIDE the direct
  /// chat with the story author. The reply text + the story reference
  /// travel INSIDE the ciphertext; the server sees just another row.
  static const String kindStoryReply = 'storyReply';

  /// v0.1.12: encrypted location point — coordinates INSIDE the
  /// ciphertext; the server only sees kind='location'. Rendered as a
  /// map-preview bubble (tiles fetched anonymously from OSM).
  static const String kindLocation = 'location';

  /// v0.1.12: encrypted contact card — username+display name INSIDE
  /// the ciphertext; tapping resolves through the search path (same
  /// flow as QR add, camera-free).
  static const String kindContact = 'contact';

  // Media subtypes (stored inside the encrypted payload)
  static const String mediaImage = 'image';
  static const String mediaAudio = 'audio';
  static const String mediaVideo = 'video';
  static const String mediaFile = 'file';

  // Chat types
  static const String chatDirect = 'direct';
  static const String chatGroup = 'group';

  // Member roles
  static const String roleOwner = 'owner';
  static const String roleAdmin = 'admin';
  static const String roleMember = 'member';

  // Message states (client-side state machine)
  static const String stateQueued = 'queued';
  static const String stateSending = 'sending';
  static const String stateSent = 'sent';
  static const String stateDelivered = 'delivered';
  static const String stateRead = 'read';
  static const String stateFailed = 'failed';

  // Outbox actions
  static const String outboxSend = 'send';
  static const String outboxEdit = 'edit';
  static const String outboxDelete = 'delete';

  // Call statuses
  static const String callRinging = 'ringing';
  static const String callActive = 'active';
  static const String callEnded = 'ended';
  static const String callMissed = 'missed';
  static const String callDeclined = 'declined';
}
