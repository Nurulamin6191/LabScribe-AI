import 'package:flutter/material.dart';

/// LabScribe BlackHole-inspired design system.
///
/// Takes its cues from the BlackHole music app: pure-black AMOLED dark
/// theme, clean white light theme, one confident red accent, generous
/// rounding, and a setup-first onboarding flow. Familiar, high-contrast,
/// never dull.
///
/// Dark:  near-black background, charcoal cards, signal-red accents.
/// Light: white background and cards, deep-red header and actions.
class LabScribeTheme {
  // Signature reds (primary actions, record, highlights).
  static const _red = Color(0xFFE53935);
  static const _redBright = Color(0xFFFF5252);
  static const _redDeep = Color(0xFFB71C1C);
  static const _redInk = Color(0xFF7F0000);
  static const _amber = Color(0xFFB77900);
  static const _signalRed = Color(0xFFD92D20);

  static ThemeData light() {
    final scheme = ColorScheme(
      brightness: Brightness.light,
      primary: _red,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFFFCDD2),
      onPrimaryContainer: _redInk,
      secondary: const Color(0xFF424242),
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFE0E0E0),
      onSecondaryContainer: const Color(0xFF212121),
      tertiary: _amber,
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFF7E8C3),
      onTertiaryContainer: const Color(0xFF4A3600),
      error: _signalRed,
      onError: Colors.white,
      errorContainer: const Color(0xFFFDE7E5),
      onErrorContainer: const Color(0xFF7A1F1A),
      surface: const Color(0xFFF5F5F5),
      onSurface: const Color(0xFF111111),
      surfaceContainerHighest: const Color(0xFFE0E0E0),
      surfaceContainerHigh: const Color(0xFFEEEEEE),
      surfaceContainer: const Color(0xFFF5F5F5),
      surfaceContainerLow: const Color(0xFFFAFAFA),
      surfaceContainerLowest: Colors.white,
      surfaceDim: const Color(0xFFE8E8E8),
      surfaceBright: Colors.white,
      onSurfaceVariant: const Color(0xFF757575),
      outline: const Color(0xFF9E9E9E),
      outlineVariant: const Color(0xFFE0E0E0),
      shadow: const Color(0xFF111111),
      scrim: const Color(0xFF111111),
      inverseSurface: const Color(0xFF111111),
      onInverseSurface: const Color(0xFFF5F5F5),
      inversePrimary: _redBright,
    );
    return _build(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _redBright,
      onPrimary: const Color(0xFF1A0000),
      primaryContainer: const Color(0xFF5C1010),
      onPrimaryContainer: const Color(0xFFFFCDD2),
      secondary: const Color(0xFFBDBDBD),
      onSecondary: const Color(0xFF111111),
      secondaryContainer: const Color(0xFF2A2A2A),
      onSecondaryContainer: const Color(0xFFE0E0E0),
      tertiary: const Color(0xFFE8A100),
      onTertiary: const Color(0xFF2A1D00),
      tertiaryContainer: const Color(0xFF4A3600),
      onTertiaryContainer: const Color(0xFFFFEFC7),
      error: const Color(0xFFFF8A80),
      onError: const Color(0xFF3D0A06),
      errorContainer: const Color(0xFF5C1512),
      onErrorContainer: const Color(0xFFFDE7E5),
      surface: const Color(0xFF000000),
      onSurface: const Color(0xFFF5F5F5),
      surfaceContainerHighest: const Color(0xFF2E2E2E),
      surfaceContainerHigh: const Color(0xFF242424),
      surfaceContainer: const Color(0xFF1A1A1A),
      surfaceContainerLow: const Color(0xFF111111),
      surfaceContainerLowest: const Color(0xFF1E1E1E),
      surfaceDim: const Color(0xFF000000),
      surfaceBright: const Color(0xFF2E2E2E),
      onSurfaceVariant: const Color(0xFF9E9E9E),
      outline: const Color(0xFF757575),
      outlineVariant: const Color(0xFF2C2C2C),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: const Color(0xFFEDEDED),
      onInverseSurface: const Color(0xFF111111),
      inversePrimary: _red,
    );
    return _build(scheme);
  }

  static ThemeData _build(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final accent = isDark ? _redBright : _red;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      textTheme: _textTheme(scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF000000) : Colors.white,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
        actionsIconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide.none,
        labelStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: isDark ? const Color(0xFF1A0000) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: _red,
        foregroundColor: Colors.white,
        shape: CircleBorder(),
        elevation: 4,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? scheme.surfaceContainerLow : scheme.surfaceContainerLow,
        hintStyle: TextStyle(color: scheme.outline, fontSize: 13),
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: _red, width: 1.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF000000) : Colors.white,
        elevation: 0,
        indicatorColor: accent.withValues(alpha: 0.16),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected) ? accent : null,
            )),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: accent.withValues(alpha: 0.16),
        selectedIconTheme: IconThemeData(color: accent),
        unselectedIconTheme: IconThemeData(color: scheme.outline),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.outline, fontSize: 11),
      ),
      tabBarTheme: const TabBarThemeData(
        labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : null),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent.withValues(alpha: 0.4) : null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : null),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        thumbColor: accent,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.surfaceContainerHighest,
        color: accent,
      ),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      badgeTheme: const BadgeThemeData(
        backgroundColor: _red,
        textColor: Colors.white,
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme) {
    const tight = -0.3;
    TextStyle base(Color? c, double s, FontWeight w, [double h = 1.35]) =>
        TextStyle(color: c, fontSize: s, fontWeight: w, height: h, letterSpacing: tight);
    return TextTheme(
      displaySmall: base(scheme.onSurface, 30, FontWeight.w800, 1.1),
      headlineMedium: base(scheme.onSurface, 24, FontWeight.w800, 1.15),
      headlineSmall: base(scheme.onSurface, 19, FontWeight.w800, 1.2),
      titleLarge: base(scheme.onSurface, 17, FontWeight.w800),
      titleMedium: base(scheme.onSurface, 15, FontWeight.w700),
      titleSmall: base(scheme.onSurface, 13, FontWeight.w700),
      bodyLarge: base(scheme.onSurface, 14.5, FontWeight.w400, 1.6),
      bodyMedium: base(scheme.onSurface, 13.5, FontWeight.w400, 1.55),
      bodySmall: base(scheme.onSurfaceVariant, 12, FontWeight.w500, 1.45),
      labelLarge: base(scheme.onSurface, 13, FontWeight.w700),
      labelSmall: base(scheme.onSurfaceVariant, 11, FontWeight.w700, 1.3),
    );
  }
}
