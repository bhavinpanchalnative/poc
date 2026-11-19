import 'package:flutter/material.dart';

/// Planora's design system: one place for the brand, colours, type and the
/// shape of every component, used by every screen on Android and iOS.
///
/// Palette: deep navy ink for text and dark surfaces, "plan blue" for actions
/// and the plan itself, "scan teal" for anything the camera detected or
/// measured, on calm neutral backgrounds. Type: Inter (bundled), tight
/// headings, tabular figures for measurements.
class AppTheme {
  // ---------------------------------------------------------------- brand

  static const appName = 'Planora';
  static const tagline = 'Scan. Measure. Plan.';

  // ---------------------------------------------------------------- colours

  /// Deep navy: text, dark panels, the icon background.
  static const ink = Color(0xFF0B1426);
  static const ink2 = Color(0xFF16213A);

  /// Plan blue: primary actions, selection, the floor plan's accent.
  static const brand = Color(0xFF2F5BFF);
  static const brandDeep = Color(0xFF1B3FD8);

  /// Scan teal: detected / measured things, success of a scan.
  static const scan = Color(0xFF12C2A4);

  static const door = Color(0xFFE08A0B);
  static const window = Color(0xFF0EA5E9);
  static const surfaceMark = Color(0xFF8B5CF6);
  static const lineMark = Color(0xFFCA8A04);
  static const success = Color(0xFF16A34A);
  static const danger = Color(0xFFE5484D);

  /// The hero gradient (home, empty states, the icon).
  static const heroGradient = LinearGradient(
    colors: [Color(0xFF2F5BFF), Color(0xFF1A2F8F), ink],
    stops: [0, 0.6, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ---------------------------------------------------------------- shape

  static const radiusS = 10.0;
  static const radiusM = 14.0;
  static const radiusL = 20.0;
  static const radiusXL = 28.0;

  static const fontFamily = 'Inter';

  /// Measurements read better with figures of equal width.
  static const tabular = [FontFeature.tabularFigures()];

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final light = b == Brightness.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: brand,
      brightness: b,
    ).copyWith(
      primary: light ? brand : const Color(0xFF8FA8FF),
      onPrimary: light ? Colors.white : ink,
      primaryContainer: light ? const Color(0xFFE6ECFF) : const Color(0xFF1C2C66),
      onPrimaryContainer: light ? brandDeep : const Color(0xFFDDE5FF),
      secondary: scan,
      onSecondary: Colors.white,
      error: danger,
      surface: light ? Colors.white : const Color(0xFF131A2B),
      onSurface: light ? ink : const Color(0xFFE9EDF6),
      onSurfaceVariant: light ? const Color(0xFF5B6478) : const Color(0xFF9AA4B8),
      outline: light ? const Color(0xFFD5DAE4) : const Color(0xFF2C3650),
      outlineVariant: light ? const Color(0xFFE6E9F0) : const Color(0xFF222B40),
    );
    final bg = light ? const Color(0xFFF4F6FB) : const Color(0xFF0A0F1C);
    final cardColor = scheme.surface;
    final border = scheme.outlineVariant;

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: b,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: bg,
    );
    final t = base.textTheme;
    final text = t.copyWith(
      displaySmall: t.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.0),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4, fontSize: 21),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: t.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: t.bodyMedium?.copyWith(height: 1.45),
      bodySmall: t.bodySmall?.copyWith(height: 1.4),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
      labelMedium: t.labelMedium?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0.1),
      labelSmall: t.labelSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.6),
    );

    return base.copyWith(
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusL),
          side: BorderSide(color: border),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusM)),
          textStyle: text.labelLarge?.copyWith(fontSize: 15),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusM)),
          textStyle: text.labelLarge?.copyWith(fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusS)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusM)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        extendedTextStyle: text.labelLarge?.copyWith(fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusL)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: light ? const Color(0xFFF4F6FB) : const Color(0xFF1A2236),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusM),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusM),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusM),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: cardColor,
        side: BorderSide(color: border),
        labelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXL)),
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXL)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusM),
          side: BorderSide(color: border),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusM)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusM)),
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        dividerColor: border,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 2.5),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        titleTextStyle: text.titleSmall?.copyWith(color: scheme.onSurface),
        subtitleTextStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusM)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }
}
