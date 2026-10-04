import 'package:flutter/material.dart';

/// LabScribe chat-warm design system.
///
/// Inspired by the world's most-used messaging and learning apps:
/// WhatsApp's warm paper surfaces, deep-green header, glowing action
/// button and chat bubbles; Unacademy's bright-green CTAs and clean
/// card rows. Applied to a research companion: credible, friendly,
/// instantly familiar — never dull.
///
/// Light:  paper background, white cards, deep-green header, bright-green
///          primary actions, pale-green outgoing bubbles.
/// Dark:    WhatsApp-night background and surfaces, mint-green accents.
class LabScribeTheme {
  // WhatsApp greens + Unacademy-bright CTA green (same family).
  static const _waDeepGreen = Color(0xFF008069);
  static const _waBrightGreen = Color(0xFF00A884);
  static const _waBubble = Color(0xFFD9FDD3);
  static const _waBubbleInk = Color(0xFF0B3D2E);
  static const _waNightBubble = Color(0xFF005C4B);
  static const _amber = Color(0xFFB77900);
  static const _signalRed = Color(0xFFD92D20);

  static ThemeData light() {
    final scheme = ColorScheme(
      brightness: Brightness.light,
      primary: _waDeepGreen,
      onPrimary: Colors.white,
      primaryContainer: _waBubble,
      onPrimaryContainer: _waBubbleInk,
      secondary: _waBrightGreen,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFCCEFE3),
      onSecondaryContainer: const Color(0xFF06382F),
      tertiary: _amber,
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFF7E8C3),
      onTertiaryContainer: const Color(0xFF4A3600),
      error: _signalRed,
      onError: Colors.white,
      errorContainer: const Color(0xFFFDE7E5),
      onErrorContainer: const Color(0xFF7A1F1A),
      surface: const Color(0xFFECE5DB),
      onSurface: const Color(0xFF111B21),
      surfaceContainerHighest: const Color(0xFFE2DACA),
      surfaceContainerHigh: const Color(0xFFF1EBDF),
      surfaceContainer: const Color(0xFFF7F3EC),
      surfaceContainerLow: const Color(0xFFFBF8F2),
      surfaceContainerLowest: Colors.white,
      surfaceDim: const Color(0xFFE5DCCd),
      surfaceBright: Colors.white,
      onSurfaceVariant: const Color(0xFF667781),
      outline: const Color(0xFF8A8378),
      outlineVariant: const Color(0xFFD5CFC2),
      shadow: const Color(0xFF111B21),
      scrim: const Color(0xFF111B21),
      inverseSurface: const Color(0xFF111B21),
      onInverseSurface: const Color(0xFFF4EEE3),
      inversePrimary: _waBrightGreen,
    );
    return _build(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _waBrightGreen,
      onPrimary: const Color(0xFF06281F),
      primaryContainer: _waNightBubble,
      onPrimaryContainer: const Color(0xFFD9FDD3),
      secondary: _waBrightGreen,
      onSecondary: const Color(0xFF06281F),
      secondaryContainer: const Color(0xFF0B3D34),
      onSecondaryContainer: const Color(0xFFCFF3E8),
      tertiary: const Color(0xFFE8A100),
      onTertiary: const Color(0xFF2A1D00),
      tertiaryContainer: const Color(0xFF4A3600),
      onTertiaryContainer: const Color(0xFFFFEFC7),
      error: const Color(0xFFFF8A80),
      onError: const Color(0xFF3D0A06),
      errorContainer: const Color(0xFF5C1512),
      onErrorContainer: const Color(0xFFFDE7E5),
      surface: const Color(0xFF0B141A),
      onSurface: const Color(0xFFE9EDEF),
      surfaceContainerHighest: const Color(0xFF2A3942),
      surfaceContainerHigh: const Color(0xFF1F2C34),
      surfaceContainer: const Color(0xFF182229),
      surfaceContainerLow: const Color(0xFF111B21),
      surfaceContainerLowest: const Color(0xFF1F2C34),
      surfaceDim: const Color(0xFF0B141A),
      surfaceBright: const Color(0xFF2A3942),
      onSurfaceVariant: const Color(0xFF8696A0),
      outline: const Color(0xFF8696A0),
      outlineVariant: const Color(0xFF37474F),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: const Color(0xFFE9EDEF),
      onInverseSurface: const Color(0xFF111B21),
      inversePrimary: _waDeepGreen,
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
        backgroundColor: isDark ? const Color(0xFF1F2C34) : _waDeepGreen,
        foregroundColor: isDark ? const Color(0xFFE9EDEF) : Colors.white,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.2,
          color: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
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
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _waBrightGreen,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
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
          borderSide: BorderSide(color: _waBrightGreen, width: 1.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1F2C34) : Colors.white,
        elevation: 0,
        indicatorColor: (isDark ? _waBrightGreen : _waDeepGreen).withValues(alpha: 0.16),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? (isDark ? _waBrightGreen : _waDeepGreen)
                  : null,
            )),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: _waDeepGreen.withValues(alpha: 0.14),
        selectedIconTheme: const IconThemeData(color: _waDeepGreen),
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
            s.contains(WidgetState.selected) ? _waBrightGreen : null),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? _waDeepGreen.withValues(alpha: 0.4) : null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? _waDeepGreen : null),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: _waBrightGreen,
        thumbColor: _waBrightGreen,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.surfaceContainerHighest,
        color: _waBrightGreen,
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
        backgroundColor: _waBrightGreen,
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
