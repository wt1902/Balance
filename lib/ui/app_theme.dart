import 'package:flutter/material.dart';
import '../domain/appearance.dart';

class BalanceThemes {
  static ThemeData build(Brightness brightness, ColorPreset preset) {
    final oled = brightness == Brightness.dark && preset == ColorPreset.oled;
    var scheme = ColorScheme.fromSeed(
      seedColor: Color(preset.seedArgb),
      brightness: brightness,
    );
    if (oled) {
      scheme = scheme.copyWith(
        surface: Colors.black,
        surfaceDim: Colors.black,
        surfaceBright: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: Colors.black,
        surfaceContainer: Colors.black,
        surfaceContainerHigh: Colors.black,
        surfaceContainerHighest: Colors.black,
        surfaceTint: Colors.transparent,
        primaryContainer: Colors.black,
        onPrimaryContainer: scheme.onSurface,
        secondaryContainer: const Color(0xff171b19),
        outlineVariant: const Color(0xff303633),
      );
    }
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'BalanceRoboto',
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      applyElevationOverlayColor: !oled,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: CardThemeData(
        surfaceTintColor: oled ? Colors.transparent : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: oled
              ? BorderSide(color: scheme.outlineVariant)
              : BorderSide.none,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: oled ? Colors.transparent : null,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: oled ? Colors.black : null,
        surfaceTintColor: oled ? Colors.transparent : null,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: oled ? Colors.black : null,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: oled ? Colors.black : null,
        surfaceTintColor: oled ? Colors.transparent : null,
      ),
    );
  }
}
