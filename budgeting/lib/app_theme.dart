import 'package:material_ui/material_ui.dart';

/// Edit these roles to retheme every budgeting screen, including custom charts.
/// Keep web/index.html and web/manifest.json browser colors in sync.
abstract final class BudgetColors {
  static const primary = Color(0xff188818);
  static const leaf = Color(0xff288808);
  static const forest = Color(0xff124D24);
  static const background = Color(0xff291900);
  static const surface = Color(0xfff7ebdb);
  static const inputBackground = Color(0xfff7ebdb);
  static const dropdownBackground = Color(0xfff7ebdb);
  static const transactionBackground = Color(0xfff7ebdb);
  static const text = Color(0xff142c1b);
  static const muted = Color(0xff53694f);
  static const border = Color(0xffceddc6);
  static const selection = Color(0xffdeedd5);
  static const onPrimary = Color(0xffffffff);
  static const onDark = Color(0xfff2f6ef);
  static const onDarkMuted = Color(0xffbed3b3);
  static const darkSelection = Color(0xff205d34);
  static const darkBorder = Color(0xff4b7952);
  static const darkHighlight = Color(0xffc6eca9);
  static const success = primary;
  static const warning = Color(0xff985000);
  static const error = Color(0xffa53d43);
  static const errorSurface = Color(0xfffff1ed);
  static const deficit = Color(0xff7f1d1d);
  static const chartLine = primary;
  static const chartGrid = border;
  static const chartMissing = muted;
  static const qrBackground = Color(0xffffffff);
  static const colorPickerWhite = Color(0xffffffff);
  static const colorPickerBlack = Color(0xff000000);

  // Persisted group presets are data colors, independent of the brand palette.
  static const groupTeal = Color(0xff17695c);
  static const groupBlue = Color(0xff426c9b);
  static const groupAmber = Color(0xffa87522);
  static const groupRose = Color(0xffa45371);
  static const groupViolet = Color(0xff77629c);
  static const groupSlate = Color(0xff657782);
}

abstract final class BudgetTheme {
  static ThemeData get data {
    final scheme = ColorScheme.fromSeed(
      seedColor: BudgetColors.primary,
      brightness: Brightness.light,
      primary: BudgetColors.primary,
      onPrimary: BudgetColors.onPrimary,
      primaryContainer: BudgetColors.selection,
      onPrimaryContainer: BudgetColors.text,
      secondary: BudgetColors.forest,
      onSecondary: BudgetColors.onPrimary,
      secondaryContainer: BudgetColors.selection,
      onSecondaryContainer: BudgetColors.text,
      tertiary: BudgetColors.leaf,
      surface: BudgetColors.surface,
      onSurface: BudgetColors.text,
      onSurfaceVariant: BudgetColors.muted,
      outline: BudgetColors.muted,
      outlineVariant: BudgetColors.border,
      error: BudgetColors.error,
      onError: BudgetColors.onPrimary,
      errorContainer: BudgetColors.errorSurface,
      onErrorContainer: BudgetColors.deficit,
      surfaceContainerLowest: BudgetColors.surface,
      surfaceContainerLow: BudgetColors.surface,
      surfaceContainer: BudgetColors.surface,
      surfaceContainerHigh: BudgetColors.selection,
      surfaceContainerHighest: BudgetColors.selection,
      inverseSurface: BudgetColors.forest,
      onInverseSurface: BudgetColors.onDark,
      inversePrimary: BudgetColors.darkHighlight,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: BudgetColors.background,
      fontFamily: 'CircularStd',
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            color: BudgetColors.text,
            letterSpacing: -1.3),
        headlineSmall: TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.w700,
            color: BudgetColors.text),
        titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: BudgetColors.text),
        bodyMedium:
            TextStyle(fontSize: 14, color: BudgetColors.text, height: 1.5),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BudgetColors.inputBackground,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: BudgetColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        backgroundColor: BudgetColors.primary,
        foregroundColor: BudgetColors.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 19),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      )),
      cardTheme: const CardThemeData(
          elevation: 0, color: BudgetColors.surface, margin: EdgeInsets.zero),
      appBarTheme: const AppBarTheme(
          backgroundColor: BudgetColors.background,
          foregroundColor: BudgetColors.text,
          surfaceTintColor: Colors.transparent),
      dividerColor: BudgetColors.border,
      iconTheme: const IconThemeData(color: BudgetColors.primary),
    );
  }
}
