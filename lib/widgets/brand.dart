import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/config/app_config.dart';
import '../data/models/models.dart';
import '../theme/app_theme.dart';
import 'avatar_image.dart';

/// Violet Chat brand mark — purple rounded square with a white shield
/// carrying a chat bubble (v0.1.0: matches the new adaptive launcher
/// icon — shield + bubble + presence dot).
///
/// [size] controls the square side; when [showName] is true the app
/// name (from [AppConfig.appName]) is drawn beside the mark.
class BrandLogo extends StatelessWidget {
  final double size;
  final bool showName;
  final TextStyle? nameStyle;

  const BrandLogo({
    super.key,
    this.size = 40,
    this.showName = false,
    this.nameStyle,
  });

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [AppTheme.brandSecondary, AppTheme.brandPrimary],
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: AppTheme.brandPrimary.withValues(alpha: 0.30),
            blurRadius: size * 0.45,
            offset: Offset(0, size * 0.10),
          ),
        ],
      ),
      child: Stack(
        alignment: const Alignment(0, 0.04),
        children: [
          Icon(
            Icons.shield_rounded,
            color: Colors.white,
            size: size * 0.58,
          ),
          Icon(
            Icons.chat_rounded,
            color: AppTheme.brandPrimary,
            size: size * 0.26,
          ),
        ],
      ),
    );

    if (!showName) return mark;

    return Row(
      textDirection: TextDirection.rtl,
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: size * 0.28),
        Text(
          AppConfig.appName,
          style: nameStyle ??
              Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: size * 0.52,
                    letterSpacing: 0.5,
                  ),
        ),
      ],
    );
  }
}

/// Unified avatar everywhere in the app (v0.1.0: one shape, one
/// resolution order — previously three competing implementations).
///
/// Resolution order (v0.1.0): uploaded avatar IMAGE (profile.avatarPath,
/// fetched from the private avatars bucket through AvatarImageCache) >
/// [emoji] > first letter of [label] / [profile] > '؟'.
/// Background color resolution: [color] > palette entry derived from
/// [Profile.colorSeed] > palette entry hashed from [seedId] > brand primary.
class AvatarWidget extends StatelessWidget {
  final Profile? profile;
  final String? emoji;
  final Color? color;
  final double radius;

  /// Free-form display text when there is no [Profile] (chat title,
  /// group title, call peer name...).
  final String? label;

  /// Stable color seed (any id string) when there is no [Profile] —
  /// hashes exactly like the old per-screen implementations so existing
  /// identity colors are preserved.
  final String? seedId;

  const AvatarWidget({
    super.key,
    this.profile,
    this.emoji,
    this.color,
    this.radius = 24,
    this.label,
    this.seedId,
  });

  Color get _background {
    if (color != null) return color!;
    final p = profile;
    if (p != null) {
      return AppTheme
          .avatarPalette[p.colorSeed % AppTheme.avatarPalette.length];
    }
    final sid = seedId;
    if (sid != null && sid.isNotEmpty) {
      var seed = 0;
      for (var i = 0; i < sid.length; i++) {
        seed = (seed * 31 + sid.codeUnitAt(i)) & 0x7fffffff;
      }
      return AppTheme.avatarPalette[seed % AppTheme.avatarPalette.length];
    }
    return AppTheme.brandPrimary;
  }

  String get _text {
    if (emoji != null && emoji!.isNotEmpty) return emoji!;
    final p = profile;
    if (p != null && p.initial.isNotEmpty) return p.initial;
    final l = label?.trim();
    if (l != null && l.isNotEmpty) return l.substring(0, 1).toUpperCase();
    return '؟';
  }

  @override
  Widget build(BuildContext context) {
    final isEmoji = emoji != null && emoji!.isNotEmpty;

    final decoration = BoxDecoration(
      color: _background,
      borderRadius: BorderRadius.circular(radius * 0.72),
    );

    // v0.1.0 — a real uploaded picture wins over letter/emoji. The
    // FutureBuilder is fed by the deduplicating AvatarImageCache, so
    // one download serves every widget showing this profile, and the
    // letter fallback renders instantly while bytes are in flight.
    final path = profile?.avatarPath;
    if (path != null && path.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius * 0.72),
        child: Container(
          width: radius * 2,
          height: radius * 2,
          decoration: decoration,
          child: FutureBuilder<Uint8List?>(
            future: AvatarImageCache.load(path),
            builder: (ctx, snap) {
              final bytes = snap.data;
              if (snap.connectionState == ConnectionState.done &&
                  bytes != null) {
                return Image.memory(
                  bytes,
                  width: radius * 2,
                  height: radius * 2,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                );
              }
              return Center(
                child: Text(
                  _text,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize:
                        isEmoji ? radius * 0.95 : radius * 0.85,
                    fontWeight:
                        isEmoji ? FontWeight.w400 : FontWeight.w800,
                    height: 1.0,
                  ),
                ),
              );
            },
          ),
        ),
      );
    }

    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: decoration,
      child: Text(
        _text,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          color: Colors.white,
          fontSize: isEmoji ? radius * 0.95 : radius * 0.85,
          fontWeight: isEmoji ? FontWeight.w400 : FontWeight.w800,
          height: 1.0,
        ),
      ),
    );
  }
}
