/// Global constants shared across features.
class AppConstants {
  AppConstants._();

  // Message kinds
  static const String kindText = 'text';
  static const String kindSystem = 'system';
  static const String kindMedia = 'media';

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
