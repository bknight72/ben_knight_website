import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
import 'app_shape_theme.dart';
import 'app_spacing.dart';

export 'app_colors.dart';

/// Layout breakpoint below which the nav switches from inline links to a
/// hamburger + [Drawer]. Matches the reference site's Bootstrap
/// `navbar-expand-lg` collapse breakpoint (~992px).
const double kMobileBreakpoint = 992.0;

/// Maximum content width for section bodies, mirroring the reference site's
/// Bootstrap container max-width.
const double kMaxContentWidth = 1200.0;

/// Width below which the Hero ASCII-art wordmark switches from the wide
/// single-row layout to the narrower stacked layout. Independent of
/// [kMobileBreakpoint], which governs the nav bar's own collapse point.
const double kHeroArtBreakpoint = 600.0;

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

    // DM Mono only ships weights 300 (Light), 400 (Regular), and 500
    // (Medium) — every heading below is capped at w500 instead of the
    // w900/w700 used previously, since DM Mono has no bolder weight to
    // request.
    final monoTextTheme = GoogleFonts.dmMonoTextTheme(base.textTheme);

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: monoTextTheme.copyWith(
        displaySmall: monoTextTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.text,
        ),
        headlineMedium: monoTextTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.text,
        ),
        headlineSmall: monoTextTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.text,
        ),
        titleLarge: monoTextTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.text,
        ),
        bodyLarge: monoTextTheme.bodyLarge?.copyWith(
          color: AppColors.text,
        ),
        bodyMedium: monoTextTheme.bodyMedium?.copyWith(
          color: AppColors.text,
        ),
      ),
      extensions: const [AppShapeTheme.standard],
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: AppShapeTheme.standard.buttonRadius,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: 14,
          ),
        ),
      ),
    );
  }
}
