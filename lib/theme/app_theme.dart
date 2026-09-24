import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_shape_theme.dart';
import 'app_spacing.dart';

export 'app_colors.dart';

/// Layout breakpoint below which the nav switches from inline links to a
/// hamburger + full-screen overlay. Matches the reference site's Bootstrap
/// `navbar-expand-lg` collapse breakpoint (~992px).
const double kMobileBreakpoint = 992.0;

/// Maximum content width for section bodies, mirroring the reference site's
/// Bootstrap container max-width.
const double kMaxContentWidth = 1200.0;

/// Width below which the Hero ASCII-art wordmark switches from the wide
/// single-row layout to the narrower stacked layout. Independent of
/// [kMobileBreakpoint], which governs the nav bar's own collapse point.
const double kHeroArtBreakpoint = 640.0;

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
      fontFamily: 'CircularStd',
    );

    final textTheme = base.textTheme.apply(fontFamily: 'CircularStd');

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: textTheme.apply(
        bodyColor: AppColors.text,
        displayColor: AppColors.text,
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
