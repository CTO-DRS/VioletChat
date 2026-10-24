// v0.1.13 — voice-note playback speeds (سرعات تشغيل الرسائل الصوتية).
//
// Pure logic (no Flutter) for direct unit-testing. The audio bubble
// cycles through the ladder 1× → 1.5× → 2× → 1× via
// [nextPlaybackSpeed] and applies it with just_audio's `setSpeed` —
// pitch-preserving on all supported Android versions.

const List<double> playbackSpeeds = [1.0, 1.5, 2.0];

/// Next speed in the cycle after [current]. An unknown [current] (e.g.
/// a future speed value) restarts the cycle at 1× — deterministic and
/// always returns a member of [playbackSpeeds].
double nextPlaybackSpeed(double current) {
  final i = playbackSpeeds.indexOf(current);
  if (i < 0 || i >= playbackSpeeds.length - 1) return playbackSpeeds.first;
  return playbackSpeeds[i + 1];
}

/// Compact chip label: 1× / 1.5× / 2× (never «1.0×»).
String playbackSpeedLabel(double speed) {
  var s = speed.toStringAsFixed(1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return '$s×';
}
