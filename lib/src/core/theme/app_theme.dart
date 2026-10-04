import 'package:flutter/material.dart';

/// LabScribe Aurora Lab design system.
/// Premium scientific companion aesthetic: deep lab ink, living teal,
/// compliance indigo, signal amber. Calm surfaces, high legibility,
/// generous radii, zero clutter.
class LabScribeTheme {
  static const _seedTeal = Color(0xFF0A7C6B);
  static const _labIndigo = Color(0xFF3B5BFF);
  static const _signalAmber = Color(0xFFB77900);
  static const _signalRed = Color(0xFFD92D20);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seedTeal,
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(0xFF0A7C6B),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFCFF3E8),
      onPrimaryContainer: const Color(0xFF06382F),
      secondary: const Color(0xFF3B5BFF),
      secondaryContainer: const Color(0xFFE2E7FF),
      onSecondaryContainer: const Color(0xFF1A2566),
      tertiary: const Color(0xFFB77900),
      tertiaryContainer: const Color(0xFFFFEFC7),
      surface: const Color(0xFFFAFBF9),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF1F4F2),
      surfaceContainerHighest: const Color(0xFFE6ECEA),
      outlineVariant: const Color(0xFFD3DBD8),
      error: _signalRed,
    );
    return _build(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4ED6B8),
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFF4ED6B8),
      onPrimary: const Color(0xFF052E27),
      primaryContainer: const Color(0xFF0B3D34),
      onPrimaryContainer: const Color(0xFFCFF3E8),
      secondary: const Color(0xFF9DAFFF),
      secondaryContainer: const Color(0xFF232D6B),
      onSecondaryContainer: const Color(0xFFE2E7FF),
      tertiary: const Color(0xFFFFC53D),
      tertiaryContainer: const Color(0xFF4A3600),
      surface: const Color(0xFF080F14),
      surfaceContainerLowest: const Color(0xFF0B151C),
      surfaceContainerLow: const Color(0xFF111D24),
      surfaceContainerHighest: const Color(0xFF1B2C34),
      outlineVariant: const Color(0xFF2A3E46),
      error: const Color(0xFFFF8A80),
    );
    return _build(scheme);
  }

  static ThemeData _build(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      textTheme: _textTheme(scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
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
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: isDark ? scheme.surfaceContainerLow : scheme.surfaceContainerLowest,
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
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
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.outline),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.outline, fontSize: 11),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? scheme.primary : null),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.surfaceContainerHighest,
        color: scheme.primary,
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
      bodySmall: base(scheme.outline, 12, FontWeight.w500, 1.45),
      labelLarge: base(scheme.onSurface, 13, FontWeight.w700),
      labelSmall: base(scheme.outline, 11, FontWeight.w700, 1.3),
    );
  }
}
