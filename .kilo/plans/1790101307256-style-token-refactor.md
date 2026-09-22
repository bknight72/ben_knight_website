# Plan: Extract Modular Style Tokens (Colors, Spacing, Radii/Borders, Fonts, Text Styles)

## Goal

Refactor the existing hardcoded style values scattered across `lib/widgets/*.dart` into a small set of centralized, named token files under `lib/theme/`, so that future style edits (shape, borders, fonts, text styles, spacing) touch one file instead of many. **Pure refactor — no visual/behavioral change**, except the deliberate font swap to DM Mono (decided below). `flutter analyze` and `flutter test` must still pass unchanged in assertions (aside from any text-rendering nuance from the new font, which does not affect `find.text`/`find.textContaining` matches).

## Decisions (confirmed with user)

1. **Scope**: pure token-extraction refactor, not a visual redesign. Existing look stays the same except for the font.
2. **Font**: add `google_fonts` package, use **DM Mono** applied globally via `TextTheme`.
3. **Weight handling**: DM Mono only ships weights 300/400/500. All current `FontWeight.w900/w700/w600` usages are **capped down to `FontWeight.w500`** (or `w400`/`w300` where a lighter look is already intended) — no faux-bold, no leftover w900/w700/w600 requests anywhere in the codebase after this refactor.
4. **Shape/border tokens**: implement as a custom `ThemeExtension<AppShapeTheme>` (not static const class), registered on `ThemeData.extensions` and read via `Theme.of(context).extension<AppShapeTheme>()!`.
5. **Spacing**: included in this pass. Add `AppSpacing` static const token class and replace hardcoded padding/`SizedBox` gap literals across all section widgets.
6. **Colors**: keep the existing `AppColors` static const class as-is (already modular); relocate only if needed for file organization, no behavior change.

## Current Hardcoded Style Inventory (from codebase scan)

- **Text styles** (fontSize/fontWeight literals outside `app_theme.dart`):
  - `project_card.dart:45-56` — title (20/w900), company (12/w500/black54)
  - `project_detail_dialog.dart:47-58` — same title/company pattern (duplicated)
  - `experience_section.dart:34-54` — role (18/w900), company (14/w600/black54), date (12/black45)
  - `nav_bar.dart:55,64,106-109` — brand text (w900), drawer link color, drawer header (w900/22)
  - `hero_section.dart:33,45-49` — subtext weight override (w300), email CTA (accent color/underline/w600)
  - `footer_section.dart:47` — copyright text (white70/12)
  - `contact_section.dart:28` — prompt text (16)
  - `about_section.dart:48` — paragraph line-height override (height:1.5, no explicit size/weight)
- **Borders/shape**:
  - `project_card.dart:24` — `Border.all(color: Colors.black12)` (card outline)
  - `app_theme.dart:72-74` — `RoundedRectangleBorder(borderRadius: BorderRadius.zero)` on `ElevatedButtonTheme`
  - `about_section.dart:29-31` — `BoxShape.circle` avatar (shape literal, not a radius — leave as `BoxShape.circle`, not tokenized)
- **Spacing** (padding/`SizedBox` literals): `section_container.dart:16` (24/64), `hero_section.dart:18,29,37` (24/96, 24, 24), `about_section.dart:22,45,59,69` (32,12,32,24), `experience_section.dart:21,24,49,57,60` (32,28,2,8,4), `featured_work_section.dart:23,28` (32, spacing 24.0), `skills_section.dart:21,23-24` (32,12,12), `contact_section.dart:16,25,32-33` (16,24,16), `footer_section.dart:20,43` (32/24 padding, 8), `nav_bar.dart:52,67,69,71` (24,8,8,24), `project_card.dart:36-38` (16,16,16), `project_detail_dialog.dart:19,44,52,61` (24,20,4,16), `section_container.dart` default itself.

## File Structure

```
lib/theme/
  app_colors.dart        # moved from app_theme.dart (AppColors class, unchanged)
  app_spacing.dart        # NEW: AppSpacing static const double scale
  app_shape_theme.dart     # NEW: AppShapeTheme extends ThemeExtension<AppShapeTheme>
  app_text_styles.dart     # NEW: named TextStyle constants used to build TextTheme
  app_theme.dart         # slimmed: composes AppColors + AppShapeTheme + TextTheme + GoogleFonts into ThemeData; keeps kMobileBreakpoint, kMaxContentWidth
```

No new `widgets/` files needed — this is a token/theme-layer change plus call-site updates in existing widget files.

## Step 1 — `pubspec.yaml`

Add:
```yaml
dependencies:
  google_fonts: ^6.0.0   # verify current stable major on pub.dev at implementation time
```

## Step 2 — `lib/theme/app_spacing.dart` (NEW)

Define a static const spacing scale covering all observed values, e.g.:
```dart
class AppSpacing {
  AppSpacing._();
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 28;
  static const double xxxl = 32;
  static const double huge = 64;
  static const double hero = 96;
}
```
Adjust exact set to cover every literal in the inventory above without inventing unused values — every existing literal must map to one named constant (reuse constants for equal values like the several `24`s and `32`s).

## Step 3 — `lib/theme/app_shape_theme.dart` (NEW)

```dart
@immutable
class AppShapeTheme extends ThemeExtension<AppShapeTheme> {
  final BorderRadius buttonRadius;      // BorderRadius.zero (current button shape)
  final BoxBorder cardBorder;         // Border.all(color: Colors.black12) (current project card outline)

  const AppShapeTheme({
    required this.buttonRadius,
    required this.cardBorder,
  });

  static const AppShapeTheme standard = AppShapeTheme(
    buttonRadius: BorderRadius.zero,
    cardBorder: Border.fromBorderSide(BorderSide(color: Colors.black12)),
  );

  @override
  AppShapeTheme copyWith({BorderRadius? buttonRadius, BoxBorder? cardBorder}) =>
      AppShapeTheme(
        buttonRadius: buttonRadius ?? this.buttonRadius,
        cardBorder: cardBorder ?? this.cardBorder,
      );

  @override
  AppShapeTheme lerp(ThemeExtension<AppShapeTheme>? other, double t) {
    if (other is! AppShapeTheme) return this;
    // Discrete shape values — no meaningful interpolation; snap at t >= 0.5.
    return t < 0.5 ? this : other;
  }
}
```
Register on `ThemeData.extensions: [AppShapeTheme.standard]` in `app_theme.dart`. Every call site currently hardcoding `Border.all(color: Colors.black12)` or `RoundedRectangleBorder(borderRadius: BorderRadius.zero)` reads `Theme.of(context).extension<AppShapeTheme>()!.cardBorder` / `.buttonRadius` instead.

## Step 4 — `lib/theme/app_text_styles.dart` (NEW)

Define named `TextStyle` constants (using plain `TextStyle`, not `GoogleFonts.dmMono(...)` directly here — the font family is applied once at the `TextTheme` level in `app_theme.dart` via `GoogleFonts.dmMonoTextTheme(...).copyWith(...)`, keeping this file font-family-agnostic and only responsible for size/weight/color deltas not already covered by Material's default `TextTheme` slots).

Map every duplicated/one-off inline style to a named `TextTheme` slot or a small set of extra named constants for things that don't fit Material's default slots (e.g. card/dialog title+subtitle, nav brand, footer caption):

| Current inline style | New home |
|---|---|
| `project_card.dart` title (20/w900) + `project_detail_dialog.dart` title (20/w900) — duplicated | Single `AppTextStyles.cardTitle` const (20/w500 per weight-cap decision), used by both |
| `project_card.dart` company (12/w500/black54) + `project_detail_dialog.dart` company (12/w500/black54) — duplicated | Single `AppTextStyles.cardSubtitle` const |
| `experience_section.dart` role (18/w900) | `AppTextStyles.experienceRole` (18/w500) |
| `experience_section.dart` company (14/w600/black54) | `AppTextStyles.experienceMeta` (14/w500/black54) |
| `experience_section.dart` date (12/black45) | `AppTextStyles.experienceDate` (12/w400/black45) |
| `nav_bar.dart` brand text (w900) + drawer header (w900/22) | `AppTextStyles.navBrand` (w500) reused in both places (drawer header adds `fontSize: 22` via `.copyWith`) |
| `hero_section.dart` subtext weight (w300) | Keep as `textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w300, height: 1.5)` — w300 is a real DM Mono weight and intentionally lighter; no new token needed beyond the base `bodyLarge` already coming from the theme |
| `hero_section.dart` email CTA (accent/underline/w600) | `AppTextStyles.emailCta` (accent color, underline, w500) |
| `footer_section.dart` copyright (white70/12) | `AppTextStyles.footerCaption` (12/w400/white70) |
| `contact_section.dart` prompt (16) | Use `textTheme.bodyLarge` directly (no override needed — remove the redundant inline `TextStyle(fontSize: 16)` since Material's `bodyLarge` is already 16) |
| `about_section.dart` paragraph (height:1.5) | `AppTextStyles.bodyRelaxed` = `bodyLarge?.copyWith(height: 1.5)` — resolved against theme at call site since it composes the ambient `bodyLarge`, OR keep as a small helper function `AppTextStyles.relaxed(TextStyle? base)` |

Also extend `AppTheme`'s `TextTheme` (Step 5) to natively cover `displaySmall`/`headlineMedium`/`headlineSmall`/`titleLarge` at the new capped weight (`w500` instead of `w900`/`w700`) so section titles (`'About.'`, `'Experience.'`, etc.) automatically pick up the change with no per-widget edits.

## Step 5 — `lib/theme/app_theme.dart` (rewrite)

- Move `AppColors` out to `app_colors.dart` (identical content); `app_theme.dart` imports it.
- Keep `kMobileBreakpoint` and `kMaxContentWidth` here (unrelated to this refactor).
- Build the theme's `TextTheme` starting from `GoogleFonts.dmMonoTextTheme(base.textTheme)` instead of `base.textTheme`, then apply the same `.copyWith(...)` overrides as today but with every `FontWeight.w900/w700/w600` changed to `FontWeight.w500`.
- Register `extensions: [AppShapeTheme.standard]` on the returned `ThemeData`.
- Update `elevatedButtonTheme` to read `shape: RoundedRectangleBorder(borderRadius: AppShapeTheme.standard.buttonRadius)` (or read from the instance being registered, to avoid a second literal) instead of the inline `BorderRadius.zero`.

## Step 6 — Update call sites (no behavior change beyond font/weight)

For each file below, replace the inline literal(s) with the corresponding token from Steps 2–4:

- `project_card.dart`: title/company `TextStyle` → `AppTextStyles.cardTitle`/`cardSubtitle`; `Border.all(...)` → `Theme.of(context).extension<AppShapeTheme>()!.cardBorder`; `16`s → `AppSpacing.lg`.
- `project_detail_dialog.dart`: same title/company token reuse; `24/20/4/16` → `AppSpacing.xl/xxl?/xs/lg` (pick nearest defined constant, adding one if truly novel — e.g. `20` isn't in the inventory list elsewhere, confirm whether to round to `xl`(24) or add a new `AppSpacing` value; **default: add it as `AppSpacing.xxl = 20` only if reused ≥2 places, otherwise leave the single `20` as a local literal with a `// one-off, not part of the shared scale` comment** to avoid token-scale bloat).
- `experience_section.dart`: role/company/date styles → `AppTextStyles.experienceRole/experienceMeta/experienceDate`; `32/28/2/8/4` → `AppSpacing` constants.
- `nav_bar.dart`: brand `TextStyle` → `AppTextStyles.navBrand`; drawer header → `AppTextStyles.navBrand.copyWith(fontSize: 22)`; `24/8/8/24` → `AppSpacing` constants; drawer link `TextStyle(color: AppColors.text)` stays as-is (already token-based via `AppColors`).
- `hero_section.dart`: email CTA style → `AppTextStyles.emailCta`; `24/96/24/24` → `AppSpacing` constants; subtext w300 override stays inline per Step 4 rationale.
- `footer_section.dart`: caption style → `AppTextStyles.footerCaption`; `32/24/8` → `AppSpacing` constants.
- `contact_section.dart`: prompt style → remove override, use ambient `bodyLarge`; `16/24/16` → `AppSpacing` constants.
- `about_section.dart`: paragraph style → `AppTextStyles.bodyRelaxed`/helper; `32/12/32/24` → `AppSpacing` constants.
- `skills_section.dart`: `32/12/12` → `AppSpacing` constants (no text-style literals here beyond theme-driven `headlineSmall`).
- `featured_work_section.dart`: `32` and `spacing = 24.0` → `AppSpacing` constants.
- `section_container.dart`: default `EdgeInsets.symmetric(horizontal: 24, vertical: 64)` → `EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.huge)`.
- `app_theme.dart`'s `ElevatedButtonThemeData.padding` (`horizontal: 24, vertical: 14`) → `AppSpacing.xl` / a defined `14` constant or documented one-off per the same bloat-avoidance rule as above.

## Step 7 — Validation

1. `flutter analyze` — zero issues (in particular: no unused imports left in `app_theme.dart` after splitting out `AppColors`; every widget file that now references `AppSpacing`/`AppTextStyles`/`AppShapeTheme` has the corresponding import added).
2. `flutter test` — existing `test/widget_test.dart` passes unchanged (it only asserts text content and widget types, not styles, so it should be unaffected by the font/weight change).
3. `flutter run -d chrome` manual check:
   - Confirm DM Mono renders site-wide (monospace look) and no `FontWeight.w900/w700/w600` leftover produces unexpected faux-bold rendering.
   - Confirm section titles, card titles/subtitles, nav brand, footer caption all still look visually consistent with each other (same weight now, per the capped-to-500 decision) — this is an intentional visual change from the current heavy-weight look and should be reviewed once, not treated as a regression.
   - Confirm project card border, button corners (still sharp/zero-radius), and overall spacing/layout are pixel-equivalent to before (spacing values were extracted 1:1, not changed).
4. `grep -rn "FontWeight.w900\|FontWeight.w700\|FontWeight.w600" lib/` returns no results (confirms the weight cap was applied everywhere, not just the files explicitly listed above).
5. `grep -rn "Border.all(color: Colors.black12)\|BorderRadius.zero" lib/widgets lib/theme` — only the token definition itself should remain; no widget file should have its own inline copy.

## Risks / Notes for Implementer

- DM Mono is a monospace font — this is a significant visual departure from the current default sans-serif. Confirm with the user after first render that this is the intended aesthetic (it was explicitly requested, but flag if it looks off given the portfolio's content-heavy sections like Experience/About).
- Capping all headings to `w500` will make headings and body text look closer in visual weight than before (previously `w900` headings vs default-weight body created strong hierarchy). Since hierarchy is otherwise preserved via `fontSize` differences (`displaySmall` > `headlineMedium` > `headlineSmall` > `titleLarge` > body), this should still read as a heading, just less "heavy" — acceptable per the user's explicit weight-cap decision, not a bug.
- `google_fonts` package downloads font files at runtime by default (or bundles via the `google_fonts` asset-bundling opt-in) — for a web target this means a network fetch to Google's CDN on first load unless `GoogleFonts.config.allowRuntimeFetching` is disabled and fonts are bundled as assets. Default (runtime fetch) is acceptable for this refactor; note as a follow-up if offline/self-hosted fonts become a requirement later.
- Where a spacing/size literal appears only once and doesn't cleanly fit the shared scale (e.g. the `20` in `project_detail_dialog.dart`'s image height context, or button padding's `14`), prefer reusing the nearest existing token unless doing so would visibly change the layout — only add a new named constant if the value recurs elsewhere, to avoid an over-large token enum that defeats the "modular" goal.
- Do not introduce `Radius`/corner-rounding anywhere as part of this refactor — the current design has zero rounded corners everywhere (`BorderRadius.zero`, square cards, square buttons); `AppShapeTheme.buttonRadius` should preserve that (`BorderRadius.zero`), not introduce rounding. This refactor centralizes the *existing* shape, it does not change it.
