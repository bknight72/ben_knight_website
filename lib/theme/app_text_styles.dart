import 'package:flutter/material.dart';

/// Named text styles for spots that don't map onto one of Material's default
/// [TextTheme] slots (e.g. the duplicated card/dialog title+subtitle pair,
/// the nav brand, the footer caption).
///
class AppTextStyles {
  AppTextStyles._();

  /// Project card / project detail dialog title shared from one definition.
  static const TextStyle cardTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w500,
  );

  /// Project card / project detail dialog company/subtitle line (was
  /// 12/w500/black54 in both places before this refactor).
  static const TextStyle cardSubtitle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: Colors.black54,
  );

  /// Experience entry role/title line.
  static const TextStyle experienceRole = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w500,
  );

  /// Experience entry company/meta line (was 14/w600/black54).
  static const TextStyle experienceMeta = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: Colors.black54,
  );

  /// Experience entry date range line (was 12/black45, no explicit weight).
  static const TextStyle experienceDate = TextStyle(
    fontSize: 12,
    color: Colors.black45,
  );

  /// Nav bar brand text / drawer header brand text. The drawer header
  /// additionally sets fontSize: 22 via `.copyWith`.
  static const TextStyle navBrand = TextStyle(fontWeight: FontWeight.w800);

  /// Hero section email CTA (was accent/underline/w600).
  static const TextStyle emailCta = TextStyle(
    color: Colors.black,
    fontSize: 20,
    decoration: TextDecoration.underline,
    fontWeight: FontWeight.w400,
  );

  /// Footer copyright/placeholder caption (was white70/12).
  static const TextStyle footerCaption = TextStyle(
    color: Colors.white70,
    fontSize: 12,
  );

  /// Applies the relaxed line-height used by About section body paragraphs
  /// on top of an ambient text style (e.g. `textTheme.bodyLarge`).
  static TextStyle? relaxed(TextStyle? base) {
    return base?.copyWith(height: 1.5);
  }
}
