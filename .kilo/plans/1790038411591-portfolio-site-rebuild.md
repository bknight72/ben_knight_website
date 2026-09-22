# Plan: Convert Flutter Boilerplate into a Portfolio Website (brianatiyeh.com structure, placeholder content)

## Context / Research Findings

**Current state:** `lib/main.dart` is the unmodified `flutter create` counter-app boilerplate (`MyApp` → `MyHomePage` with a `FloatingActionButton` incrementing `_counter`). `test/widget_test.dart` tests that counter behavior. `pubspec.yaml` name is `ben_knight_website2`. Web-only target (no android/ios/macos/windows/linux folders). A separate plan (`.kilo/plans/1790034587543-flutter-web-docker-dev.md`) covers modernizing the Flutter/Dart syntax and adding Docker dev tooling — **not duplicated here**; this plan assumes the project already runs (`flutter run -d chrome` or the Docker workflow) and focuses purely on replacing the counter app with portfolio content + a new icon.

**Reference site structure** (fetched and analyzed from `https://www.brianatiyeh.com/`): it's a Gatsby/React SPA. Only the **Nav** and **Hero** are present in server-rendered markup; the "Featured Work" section is an empty `<div id="featured-work"><h2>Featured Work.</h2></div>` shell (project cards are injected client-side, not visible in the static fetch), and **no About/Experience/Skills/Contact/Footer markup exists in the source at all**. Confirmed structural details used below:
- Fixed/pinned top nav: brand name link + `github` / `linkedin` / `twitter` links + a styled `hire me` (mailto) button.
- Hero: large bold headline ("Hey, I'm [Name] - A [Role] Engineer from [City]."), a lighter-weight subtext paragraph (2–3 career highlights), and a plain-text underlined email link as CTA.
- Featured Work: section heading + project cards; CSS (unused in the static fetch but present) implies each card = full-width tile with image, title, company/client name, hover overlay, and tapping opens a modal with a larger image + name/company/description.
- Color palette found in CSS: white background (`#fff`), black text, accent teal `#42776A` (buttons/hover overlays), dark green `#274740` (mobile nav overlay background), light gray `#eee` (image placeholder tiles).
- Bootstrap 4 based, `navbar-expand-lg` collapse breakpoint (~992px), full-screen overlay mobile menu (~project-specific — **per your decision below, we use a standard Flutter `Drawer` instead of replicating this custom overlay**).

**User decisions from clarification round:**
1. **Extended portfolio** — go beyond the reference site's confirmed Nav+Hero+Work-shell and add typical portfolio sections not present in the source: About, Experience, Skills, Contact, Footer.
2. **Mobile nav** — use a standard Flutter `Drawer` (hamburger icon in `AppBar`) rather than recreating the custom full-screen overlay menu.
3. **Project cards** — tapping a card opens a detail modal (`showDialog`) with larger image + title/company/description, matching the reference site's behavior.
4. **App icon** — generate an initials-monogram icon (solid accent-color background + bold white initials), not a custom illustration.

All actual text, images, and links are **explicit placeholders** — clearly fake (e.g. `placeholder@example.com`, `github.com/placeholder`) so nothing is mistaken for real personal data, ready for the user to swap in real content later.

## Goals

1. Replace the counter-app boilerplate with a single-page, vertically scrolling portfolio layout: Nav → Hero → Featured Work → About → Experience → Skills → Contact → Footer.
2. Nav links smooth-scroll to their matching section (anchor-style navigation); collapses to a `Drawer` below a responsive breakpoint.
3. Populate every section with clearly-labeled placeholder content (text, "images" as styled placeholder boxes, and placeholder URLs).
4. Apply a simple theme approximating the reference site's palette (white bg, black text, teal `#42776A` accent, dark green `#274740` for secondary surfaces).
5. Replace the default Flutter icon/favicon/manifest icons with a generated initials-monogram matching the new accent color, and update `web/manifest.json` / `web/index.html` metadata to match.
6. Update `test/widget_test.dart` so it tests the new home page instead of the removed counter.

Out of scope: real personal content, custom web font licensing/bundling (CircularStd), Docker/CI setup (covered by the other plan), non-web platforms, backend/contact-form functionality (mailto/external links only).

## File Structure to Create

```
lib/
  main.dart                          (rewritten: MaterialApp + theme + HomeScreen)
  theme/
    app_theme.dart                   (color constants + ThemeData)
  data/
    portfolio_data.dart              (all placeholder text/links/project list as simple const data classes)
  models/
    project.dart                     (Project data class: title, company, description, placeholderColor/icon)
    experience_entry.dart            (ExperienceEntry: role, company, dates, bullets)
  widgets/
    nav_bar.dart                     (AppBar-based fixed nav: brand, section links, social icons, hire-me button; builds Drawer for narrow layouts)
    section_container.dart           (shared padding/max-width wrapper + GlobalKey-friendly section scaffold)
    hero_section.dart
    featured_work_section.dart
    project_card.dart
    project_detail_dialog.dart
    about_section.dart
    experience_section.dart
    skills_section.dart
    contact_section.dart
    footer_section.dart
  screens/
    home_screen.dart                 (assembles all sections in a scrollable column; owns ScrollController + section GlobalKeys; handles nav-tap-to-scroll)
```

Keeping section widgets separate (rather than one giant `main.dart`) keeps each piece testable/editable independently when the user swaps in real content later.

## Step 1 — Theme (`lib/theme/app_theme.dart`)

Define constants:
- `kBackgroundColor = Colors.white`
- `kTextColor = Colors.black`
- `kAccentColor = Color(0xFF42776A)` (teal, from reference CSS)
- `kDarkAccentColor = Color(0xFF274740)` (dark green, from reference CSS — use for footer background)
- `kPlaceholderTileColor = Color(0xFFEEEEEE)` (light gray, for image placeholders)
- `AppTheme.themeData` — `ThemeData` with white scaffold background, black-on-white `AppBarTheme`, `ColorScheme` seeded from `kAccentColor`, bold headline text theme (approximate the reference's heavy-weight display font using `fontWeight: FontWeight.w900` on default sans-serif — do not add a custom font package to keep scope minimal; note as optional future enhancement in README, not required here).
- Define a `kMobileBreakpoint = 800.0` constant used by both `nav_bar.dart` and any responsive layout checks.

## Step 2 — Placeholder data (`lib/data/portfolio_data.dart`, `lib/models/*.dart`)

Create `Project` and `ExperienceEntry` classes, then a `PortfolioData` holder (or top-level consts) with:

- `name = 'Ben Knight'`
- `roleTagline = "Hey, I'm Ben — A Software Engineer from [Your City]."`
- `heroSubtext = "I've built [placeholder achievement one], contributed to [placeholder achievement two], and am currently working on [placeholder achievement three]."`
- `email = 'placeholder@example.com'`
- `githubUrl = 'https://github.com/placeholder'`
- `linkedinUrl = 'https://linkedin.com/in/placeholder'`
- `twitterUrl = 'https://twitter.com/placeholder'`
- `projects`: 3 `Project` entries, each with `title` (e.g. "Placeholder Project One"), `company` (e.g. "Placeholder Company"), `description` (2-sentence placeholder blurb), and a distinct placeholder tile color/icon (no real images/network calls — see Step 5).
- `aboutText`: 1–2 placeholder paragraphs + a placeholder avatar (see Step 5).
- `experience`: 2–3 `ExperienceEntry` items (role, company, date range placeholder, 2–3 bullet points each).
- `skills`: ~10 placeholder skill strings (e.g. "Flutter", "Dart", "Placeholder Skill", ...).
- `footerText = '© 2026 Ben Knight. Built with Flutter. Placeholder content — replace before publishing.'`

Keeping all copy in one data file means later real-content edits touch only this file, not widget logic.

## Step 3 — Nav bar (`lib/widgets/nav_bar.dart`)

- Build as the `Scaffold.appBar` (`PreferredSizeWidget`) so it's pinned/fixed while the body scrolls — matches the reference's `fixed-top` nav without needing custom sliver-pinning code.
- Desktop/wide (`MediaQuery.of(context).size.width >= kMobileBreakpoint`): show brand text on the left, then inline `TextButton`s for each section (`About`, `Work`, `Experience`, `Skills`, `Contact`) that call the scroll-to-section callback, then 3 social `IconButton`s (use built-in `Icons` as stand-ins: e.g. `Icons.code` for GitHub, `Icons.business_center` for LinkedIn, `Icons.alternate_email` for Twitter/X — clearly generic placeholders, avoids adding an icon-font dependency just for branding marks), then an accent-colored `hire me` button that launches `mailto:` via `url_launcher`.
- Narrow (`< kMobileBreakpoint`): show brand text + a `Builder`-wrapped hamburger `IconButton` that calls `Scaffold.of(context).openDrawer()`. `Scaffold.drawer` contains the same section links + social icons + hire-me button stacked vertically (`ListView` of `ListTile`s).
- Section-link taps: call a passed-in `void Function(SectionKey)` (or similar) supplied by `HomeScreen`, which resolves to `Scrollable.ensureVisible` / `ScrollController.animateTo` for that section's `GlobalKey`.

## Step 4 — Section widgets

Each section widget accepts a `GlobalKey` (passed from `HomeScreen`) attached to its outer container for scroll-targeting, and wraps content in the shared `SectionContainer` (max content width ~1200px like the reference's Bootstrap container, horizontal padding, vertical spacing).

- **`hero_section.dart`**: Large bold headline (`roleTagline`), subtext paragraph, plain underlined email `InkWell`/`TextButton` CTA (launches `mailto:` via `url_launcher`). Left-aligned, matches reference's text-only hero (no image).
- **`featured_work_section.dart`**: "Featured Work." section title, then a responsive grid/wrap of `ProjectCard`s (single column on narrow width, e.g. 2–3 columns via `Wrap`/`GridView` on wide width).
- **`project_card.dart`**: Fixed-height tile (~300–400px), `kPlaceholderTileColor` background, centered placeholder `Icon` (e.g. `Icons.image_outlined`) standing in for a screenshot, title + company text overlaid/below, `InkWell` `onTap` opens `ProjectDetailDialog`.
- **`project_detail_dialog.dart`**: `AlertDialog` or custom `Dialog` showing a larger placeholder image box, project title, company, and full description text, plus a close button — mirrors the reference's project modal.
- **`about_section.dart`**: Section title "About.", a `CircleAvatar` placeholder (icon, not a real photo) + `aboutText` paragraph(s) beside/below it.
- **`experience_section.dart`**: Section title "Experience.", vertical list of `ExperienceEntry` cards (role/company/dates header + bullet list).
- **`skills_section.dart`**: Section title "Skills.", `Wrap` of `Chip` widgets for each skill string.
- **`contact_section.dart`**: Section title "Contact.", short placeholder prompt text, prominent "hire me" / email button (same `mailto:` launcher), row of the same 3 social icon buttons.
- **`footer_section.dart`**: `kDarkAccentColor` background, white text, `footerText`, and a repeated small row of social icons — always at the bottom, not scroll-targeted by nav.

## Step 5 — Placeholder "images"

No network image dependency (keeps `flutter test`/offline builds reliable). Represent all images/photos as styled `Container`s: `kPlaceholderTileColor` (or a light variant of the accent color) background, centered `Icon` + small caption text like `"Project Screenshot Placeholder"` / `"Headshot Placeholder"`. This is visually obvious as a placeholder and swappable later for `Image.asset(...)` once real images are added to a new `assets/images/` folder (note this extension point in code comments, but do not create the folder/assets now since no real images exist yet).

## Step 6 — `HomeScreen` (`lib/screens/home_screen.dart`)

- Holds one `GlobalKey` per section (`heroKey` is not needed as a nav target, but `aboutKey`, `workKey`, `experienceKey`, `skillsKey`, `contactKey` are) and a `ScrollController`.
- `Scaffold(appBar: NavBar(...), drawer: ..., body: SingleChildScrollView(child: Column(children: [HeroSection(), FeaturedWorkSection(key: workKey), AboutSection(key: aboutKey), ExperienceSection(key: experienceKey), SkillsSection(key: skillsKey), ContactSection(key: contactKey), FooterSection()])))`.
- `scrollToSection(GlobalKey key)` method using `Scrollable.ensureVisible(key.currentContext!, duration: ..., curve: ...)`; passed down to `NavBar`.

## Step 7 — `lib/main.dart` rewrite

- Keep `usePathUrlStrategy()` call.
- `MyApp` → rename to `PortfolioApp` (or keep `MyApp` name to minimize diff — implementer's choice, but update the `title:` and remove all counter-related code/comments).
- `MaterialApp(title: 'Ben Knight — Portfolio (Placeholder)', theme: AppTheme.themeData, home: const HomeScreen(), debugShowCheckedModeBanner: false)`.
- Delete `MyHomePage`/`_MyHomePageState` entirely (counter logic no longer needed).

## Step 8 — Dependencies (`pubspec.yaml`)

Add:
```yaml
dependencies:
  url_launcher: ^6.3.0   # verify current stable major on pub.dev at implementation time; used for mailto: and social links
```
No other new dependencies required (deliberately avoiding a custom-font package and a brand-icon-font package to keep the diff minimal — both are called out above as optional future enhancements).

## Step 9 — Update `test/widget_test.dart`

Replace the counter smoke test (`find.text('0')`, tap `Icons.add`, etc. — this widget tree no longer exists) with a minimal smoke test appropriate to the new home page, e.g.:
- Pump `PortfolioApp`/`MyApp`.
- Assert the hero headline text (or a stable substring/`Key`) is found via `find.textContaining(...)`.
- Assert the "Featured Work." section title is found.
- (Optional) Assert 3 `ProjectCard` widgets are present via `find.byType(ProjectCard)`.

Since sections render inside a `SingleChildScrollView`, all should be locatable by `find.text`/`find.byType` without needing to actually scroll for a basic existence check.

## Step 10 — App icon replacement

**Design:** Solid rounded-square background in `kAccentColor` (`#42776A`), centered bold white initials `"BK"`, sized to fill each target canvas (with extra transparent/background padding on the maskable variants per PWA maskable-icon safe-zone guidance — keep the "BK" glyph within the inner ~80% to avoid clipping when the OS applies a circular/squircle mask).

**Files to regenerate** (replace in place, same paths/dimensions as existing):
| File | Size | Notes |
|---|---|---|
| `web/favicon.png` | 32×32 (upgrade from current 16×16 for sharper rendering; browsers accept it) | full-bleed, no safe-zone padding needed |
| `web/icons/Icon-192.png` | 192×192 | full-bleed |
| `web/icons/Icon-512.png` | 512×512 | full-bleed |
| `web/icons/Icon-maskable-192.png` | 192×192 | ~20% safe-zone padding around glyph |
| `web/icons/Icon-maskable-512.png` | 512×512 | ~20% safe-zone padding around glyph |

**Generation method:** at implementation time, check what's available in the environment (in order of preference): a small one-off Dart script using the `image` package (add as a temporary `dev_dependency`, run via `dart run`, then remove the dependency once icons are generated — keeps it Flutter-native and reproducible without extra tooling), or ImageMagick (`magick`/`convert`), or Python + Pillow if present. Do not leave whichever generator script/tool as a permanent project dependency — it's a one-time asset-generation step; only the resulting PNGs should remain in the repo.

**Also update:**
- `web/manifest.json`: `background_color` → `"#FFFFFF"`, `theme_color` → `"#42776A"` (replacing the default Flutter blue `#0175C2` in both fields), `name`/`short_name`/`description` → portfolio-appropriate placeholder strings (e.g. `"Ben Knight — Portfolio"` / `"Ben Knight"` / `"Placeholder portfolio site for Ben Knight"`).
- `web/index.html`: `<title>`, `<meta name="description">`, `apple-mobile-web-app-title` → same portfolio placeholder strings as above (currently all say `ben_knight_website2` / `ben knight web site`).
- `<meta name="theme-color">` if present/added — align with `#42776A`.

## Validation

1. `flutter analyze` — zero issues.
2. `flutter test` — updated `widget_test.dart` passes.
3. `flutter run -d chrome` (or the Docker web workflow from the other plan):
   - Confirm the page loads with Nav → Hero → Featured Work → About → Experience → Skills → Contact → Footer, top to bottom, no counter/FAB remnants.
   - Resize the browser window across `kMobileBreakpoint` (800px): confirm nav switches from inline links to hamburger+Drawer and back.
   - Click each nav section link; confirm smooth-scroll to the correct section.
   - Tap a project card; confirm the detail dialog opens with placeholder title/company/description and closes correctly.
   - Click the `hire me` button and a social icon; confirm `url_launcher` attempts to open `mailto:`/the placeholder URL (won't resolve since URLs are fake — that's expected).
   - Check the browser tab title/favicon reflect the new title and new monogram icon (not the Flutter logo).
4. Confirm `web/manifest.json` icons render correctly if "Add to Home Screen"/PWA install is tested (optional, browser-dependent).

## Risks / Notes for Implementer

- `url_launcher` on Flutter Web opens links via `window.open`; `mailto:` links will only do something meaningful if the browser/OS has a mail client handler configured — this is expected/inherent, not a bug to fix.
- Exact current stable `url_launcher` version must be verified on pub.dev at implementation time (pin what `flutter pub add url_launcher` resolves to).
- If the companion Docker dev-environment plan (`1790034587543-flutter-web-docker-dev.md`) is implemented first, run all `flutter` commands above through `docker compose run --rm web flutter ...` per that plan's README instructions instead of a bare local `flutter` CLI.
- Maskable icon safe-zone padding is a visual judgment call during generation — verify by eye (or a maskable-icon preview tool) that the "BK" glyph isn't clipped when previewed as a circle.
- No custom font (CircularStd) is bundled; heading "boldness" is approximated via `FontWeight.w900` on the default platform sans-serif. Bundling a real display font is a reasonable follow-up but out of scope here.
