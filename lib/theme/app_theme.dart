import 'package:flutter/material.dart';

/// Violet Chat design system — v0.1.0 «Violet Glass» (تطور «Neon Nebula»
/// القائم): بنفسجية داكنة فاخرة، زجاجية باعتدال، تباين مريح. Full RTL.
class AppTheme {
  AppTheme._();

  // Brand palette
  static const Color brandPrimary = Color(0xFF8B5CF6);
  static const Color brandPrimaryDeep = Color(0xFF7C3AED);
  static const Color brandSecondary = Color(0xFFA78BFA);
  static const Color brandAccent = Color(0xFF22D3EE);

  /// Single source of truth for "my message" bubble gradient.
  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF8B5CF6), Color(0xFFA855F7)],
    begin: AlignmentDirectional.topStart,
    end: AlignmentDirectional.bottomEnd,
  );

  /// Hero-banner gradient (home dashboard) — violet → magenta neon.
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF4C1D95), Color(0xFF6D28D9), Color(0xFF7E22CE)],
    begin: AlignmentDirectional.topStart,
    end: AlignmentDirectional.bottomEnd,
  );

  /// Cyan→violet accent gradient (badges, FAB ring, highlights).
  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF22D3EE), Color(0xFF8B5CF6)],
  );

  // Dark
  static const Color darkBg = Color(0xFF0C0716);
  static const Color darkSurface = Color(0xFF171030);
  static const Color darkSurfaceAlt = Color(0xFF221645);
  static const Color darkBorder = Color(0xFF322560);
  static const Color darkText = Color(0xFFF3F0FF);
  static const Color darkTextDim = Color(0xFFB9AFE0);

  // Light
  static const Color lightBg = Color(0xFFF6F4FC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightText = Color(0xFF1C1430);
  static const Color lightTextDim = Color(0xFF6B6480);

  // Status
  static const Color statusRead = Color(0xFF22D3EE);
  static const Color statusDelivered = Color(0xFF9CA3AF);
  static const Color errorColor = Color(0xFFF87171);
  static const Color successColor = Color(0xFF34D399);
  static const Color onlineColor = Color(0xFF4ADE80);

  static const List<Color> avatarPalette = [
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
    Color(0xFF22D3EE),
    Color(0xFF34D399),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
    Color(0xFF10B981),
  ];

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData light() => _base(Brightness.light);

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: brandPrimaryDeep,
      brightness: brightness,
    );
    final bg = isDark ? darkBg : lightBg;
    final surface = isDark ? darkSurface : lightSurface;
    final text = isDark ? darkText : lightText;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme.copyWith(
        primary: brandPrimary,
        secondary: brandSecondary,
        surface: surface,
        surfaceContainerHighest:
            isDark ? darkSurfaceAlt : const Color(0xFFEDE8FA),
        error: errorColor,
      ),
      scaffoldBackgroundColor: bg,
      textTheme: TextTheme(
        headlineMedium:
            TextStyle(fontWeight: FontWeight.w800, color: text, height: 1.3),
        titleLarge:
            TextStyle(fontWeight: FontWeight.w700, color: text, height: 1.3),
        titleMedium:
            TextStyle(fontWeight: FontWeight.w600, color: text, height: 1.3),
        bodyLarge: TextStyle(color: text, height: 1.5),
        bodyMedium: TextStyle(
            color: isDark ? darkTextDim : const Color(0xFF4B4363), height: 1.5),
        labelLarge: const TextStyle(fontWeight: FontWeight.w700),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: text,
        ),
        iconTheme: IconThemeData(color: text),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkSurface : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: brandPrimary, width: 1.6),
        ),
        hintStyle:
            TextStyle(color: isDark ? darkTextDim : const Color(0xFF9A93B5)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brandPrimary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: brandSecondary,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: brandPrimary),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? brandSecondary : brandPrimaryDeep,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: brandPrimary,
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18))),
        elevation: isDark ? 0 : 4,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? darkSurfaceAlt : const Color(0xFF2A2140),
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? Colors.white.withValues(alpha: 0.07) : Colors.black12,
        thickness: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        titleTextStyle:
            TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: text),
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: brandPrimary),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? darkSurface : Colors.white,
        indicatorColor: brandPrimary.withValues(alpha: 0.22),
        height: 68,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? brandSecondary
                  : (isDark ? darkTextDim : lightTextDim),
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11.5,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? (isDark ? darkText : lightText)
                  : (isDark ? darkTextDim : lightTextDim),
            )),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? darkSurface : Colors.white,
        selectedColor: brandPrimary.withValues(alpha: 0.28),
        side: BorderSide(
            color: isDark ? darkBorder : const Color(0xFFE4DDF6)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? darkText : lightText,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // v0.1.2 design-system helpers — the «Neon Nebula» language
  // -------------------------------------------------------------------

  /// Card decoration: tinted glass panel with a hairline neon border
  /// (dark) or a soft shadowed white card (light).
  static BoxDecoration card(BuildContext context, {double radius = 20}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: isDark ? darkSurface.withValues(alpha: 0.82) : lightSurface,
      borderRadius: BorderRadius.circular(radius),
      border: isDark
          ? Border.all(color: darkBorder.withValues(alpha: 0.55))
          : Border.all(color: const Color(0xFFECE6FA)),
      boxShadow: isDark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
    );
  }

  /// Neon glow shadow for hero elements (FAB, shield, active tabs).
  static List<BoxShadow> glow({Color color = brandPrimary, double alpha = 0.45, double blur = 22}) => [
        BoxShadow(
          color: color.withValues(alpha: alpha),
          blurRadius: blur,
          spreadRadius: 1,
        ),
      ];

  /// Online presence dot widget — the green «متصل الآن» indicator.
  static Widget onlineDot({double size = 12}) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onlineColor,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF0C0716), width: 2),
        ),
      );

  /// Message tick color (read receipts).
  static Color tickColor(bool read) => read ? statusRead : statusDelivered;
}
