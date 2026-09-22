import 'package:flutter/material.dart';

/// Shared color and layout constants approximating the reference site's
/// palette (white background, black text, teal accent, dark green footer).
class AppColors {
  AppColors._();

  static const Color background = Colors.white;
  static const Color text = Colors.black;
  static const Color accent = Color(0xFF42776A);
  static const Color darkAccent = Color(0xFF274740);
  static const Color placeholderTile = Color(0xFFEEEEEE);
}

/// Layout breakpoint below which the nav switches from inline links to a
/// hamburger + [Drawer]. Matches the reference site's Bootstrap
/// `navbar-expand-lg` collapse breakpoint (~992px).
const double kMobileBreakpoint = 992.0;

/// Maximum content width for section bodies, mirroring the reference site's
/// Bootstrap container max-width.
const double kMaxContentWidth = 1200.0;

class AppTheme {
  AppTheme._();

  static ThemeData get themeData {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: AppColors.background,
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: base.textTheme.copyWith(
        displaySmall: base.textTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w900,
          color: AppColors.text,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w900,
          color: AppColors.text,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w900,
          color: AppColors.text,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: AppColors.text,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          color: AppColors.text,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: AppColors.text,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
    );
  }
}
