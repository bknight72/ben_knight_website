import 'package:flutter/material.dart';

/// Centralizes shape/border tokens that aren't natively covered by
/// [ThemeData] (e.g. [ButtonStyle.shape], the project card's hairline
/// outline). Registered on [ThemeData.extensions] and read anywhere via
/// `Theme.of(context).extension<AppShapeTheme>()!`.
///
/// This refactor intentionally preserves the site's current shape — square
/// corners everywhere, a subtle hairline card border — it does not introduce
/// any new rounding.
@immutable
class AppShapeTheme extends ThemeExtension<AppShapeTheme> {
  /// Corner radius applied to primary buttons (currently sharp/zero).
  final BorderRadius buttonRadius;

  /// Hairline outline used around [ProjectCard] tiles.
  final BoxBorder cardBorder;

  const AppShapeTheme({
    required this.buttonRadius,
    required this.cardBorder,
  });

  static const AppShapeTheme standard = AppShapeTheme(
    buttonRadius: BorderRadius.zero,
    cardBorder: Border.fromBorderSide(BorderSide(color: Colors.black12)),
  );

  @override
  AppShapeTheme copyWith({
    BorderRadius? buttonRadius,
    BoxBorder? cardBorder,
  }) {
    return AppShapeTheme(
      buttonRadius: buttonRadius ?? this.buttonRadius,
      cardBorder: cardBorder ?? this.cardBorder,
    );
  }

  @override
  AppShapeTheme lerp(ThemeExtension<AppShapeTheme>? other, double t) {
    if (other is! AppShapeTheme) return this;
    // Shape values here are discrete (not numerically interpolatable in a
    // meaningful way beyond BorderRadius itself), so snap at the midpoint
    // rather than attempting a partial blend.
    return t < 0.5 ? this : other;
  }
}
