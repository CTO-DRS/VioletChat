import 'package:flutter/material.dart';

/// v0.1.1 — platform verification badge (the blue check).
///
/// Rendered next to usernames whose profile row carries
/// `profiles.is_verified = true`. The flag lives server-side and can
/// only be granted/revoked by a platform admin (admin_set_verified RPC
/// guarded by is_current_admin), so the badge is as trustworthy as the
/// backend it is read from.
class VerifiedBadge extends StatelessWidget {
  final double size;

  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Directional: in RTL layouts the badge sits to the LEFT of the
      // name (i.e. visually "after" it, matching Arabic reading flow).
      padding: const EdgeInsetsDirectional.only(start: 3),
      child: Icon(
        Icons.verified_rounded,
        size: size,
        color: const Color(0xFF38BDF8), // sky-400 — verification blue
      ),
    );
  }
}

/// v0.1.1 — small «أدمن» chip shown for platform admins next to names.
class AdminChip extends StatelessWidget {
  final double fontSize;

  const AdminChip({super.key, this.fontSize = 10});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFF7C3AED).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFF7C3AED).withValues(alpha: 0.5),
          width: 0.8,
        ),
      ),
      child: Text(
        'أدمن',
        style: TextStyle(
          fontSize: fontSize,
          height: 1.35,
          fontWeight: FontWeight.w700,
          color: const Color(0xFFA78BFA),
        ),
      ),
    );
  }
}
