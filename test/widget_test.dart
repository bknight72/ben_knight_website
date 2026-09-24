// Smoke test for the portfolio home page: verifies the hero headline,
// section titles, and project cards render.

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ben_knight_website2/data/portfolio_data.dart';
import 'package:ben_knight_website2/main.dart';
import 'package:ben_knight_website2/theme/app_theme.dart';
import 'package:ben_knight_website2/widgets/about_section.dart';
import 'package:ben_knight_website2/widgets/featured_work_section.dart';
import 'package:ben_knight_website2/widgets/footer_section.dart';
import 'package:ben_knight_website2/widgets/hero_ascii_art.dart';
import 'package:ben_knight_website2/widgets/hero_section.dart';
import 'package:ben_knight_website2/widgets/nav_bar.dart';
import 'package:ben_knight_website2/widgets/nav_wave.dart';
import 'package:ben_knight_website2/widgets/project_card.dart';
import 'package:ben_knight_website2/widgets/project_detail_dialog.dart';
import 'package:ben_knight_website2/widgets/section_container.dart';

void main() {
  testWidgets('Section margins increase on mobile only', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<double> leftMarginAt(double width) async {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionContainer(
              child: SizedBox(
                key: ValueKey('margin-probe'),
                width: double.infinity,
                child: Text('Margin probe'),
              ),
            ),
          ),
        ),
      );
      return tester.getTopLeft(find.byKey(const ValueKey('margin-probe'))).dx;
    }

    expect(await leftMarginAt(400), 32);
    expect(await leftMarginAt(1200), 24);
  });

  testWidgets('Hero art ramps up initial characters before reaching its cap', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: HeroAsciiArt()),
      ),
    );
    final firstRow = find
        .descendant(of: find.byType(HeroAsciiArt), matching: find.byType(Text))
        .first;
    int visibleCharacters() =>
        tester.widget<Text>(firstRow).data!.replaceAll(' ', '').length;

    expect(visibleCharacters(), 1);
    await tester.pump(const Duration(milliseconds: 73));
    expect(visibleCharacters(), 7);
    await tester.pump(const Duration(milliseconds: 96));
    expect(visibleCharacters(), 15);
    await tester.pump(const Duration(milliseconds: 12));
    expect(visibleCharacters(), 15);
    expect(tester.takeException(), isNull);
  });

  for (final width in [400.0, 1200.0]) {
    testWidgets('Hero art reveals rows top-down at width $width', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HeroAsciiArt(maxConcurrentPerRow: 1)),
        ),
      );
      final rows = find.descendant(
        of: find.byType(HeroAsciiArt),
        matching: find.byType(Text),
      );
      String row(int index) => tester.widget<Text>(rows.at(index)).data!;

      expect(row(0)[0], isNot(' '));
      expect(row(0)[1], ' ');
      expect(row(1).trim(), isEmpty);

      await tester.pump(const Duration(milliseconds: 55));
      expect(row(1)[0], isNot(' '));
      expect(row(1)[1], ' ');
      expect(row(2).trim(), isEmpty);

      await tester.pump(const Duration(milliseconds: 55));
      expect(row(2)[0], isNot(' '));
      expect(row(3).trim(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Hero art fits without horizontal scrolling across breakpoints', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<double> renderedWidthAt(double width) async {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: HeroSection())),
        ),
      );
      await tester.pump();

      final art = find.byType(HeroAsciiArt);
      expect(
        find.descendant(of: art, matching: find.byType(SingleChildScrollView)),
        findsNothing,
      );
      final lines = tester.widgetList<Text>(
        find.descendant(of: art, matching: find.byType(Text)),
      );
      final artLeft = tester.getTopLeft(art).dx;
      final artRight = tester.getTopRight(art).dx;
      final lineFinder = find.descendant(of: art, matching: find.byType(Text));
      for (var i = 0; i < lines.length; i++) {
        expect(tester.getTopLeft(lineFinder.at(i)).dx, greaterThan(artLeft));
        expect(tester.getTopRight(lineFinder.at(i)).dx,
            lessThanOrEqualTo(artRight + 0.01));
      }
      expect(tester.takeException(), isNull);
      return tester.getSize(find.byType(FittedBox)).width;
    }

    expect(
        await renderedWidthAt(1200), greaterThan(await renderedWidthAt(800)));
    expect(await renderedWidthAt(500), greaterThan(await renderedWidthAt(320)));
  });

  testWidgets('Hero art renders neighboring dots in separate monospace cells', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: HeroAsciiArt())),
      ),
    );

    final style = tester
        .widget<Text>(
          find
              .descendant(
                of: find.byType(HeroAsciiArt),
                matching: find.byType(Text),
              )
              .first,
        )
        .style!;
    expect(style.fontFeatures, contains(const FontFeature.disable('liga')));
    expect(style.fontFeatures, contains(const FontFeature.disable('clig')));
    expect(style.fontFeatures, contains(const FontFeature.disable('calt')));

    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    expect(widthOf('..'), closeTo(widthOf('.') * 2, 0.01));
    expect(widthOf('...'), closeTo(widthOf('.') * 3, 0.01));
  });

  testWidgets('About portrait uses the uploaded image in a vertical pill', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.themeData,
        home:
            const Scaffold(body: SingleChildScrollView(child: AboutSection())),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName,
        'web/assets/images/benoutdoors.jpg');
    expect(image.width, 160);
    expect(image.height, 240);
    expect(image.fit, BoxFit.cover);
    final clip = tester.widget<ClipRRect>(
      find.ancestor(of: find.byType(Image), matching: find.byType(ClipRRect)),
    );
    expect(clip.borderRadius, BorderRadius.circular(80));
    final border = tester.widget<DecoratedBox>(
      find.ancestor(
          of: find.byType(Image), matching: find.byType(DecoratedBox)),
    );
    expect(border.position, DecorationPosition.foreground);
    expect((border.decoration as BoxDecoration).border,
        Border.all(color: AppColors.accent, width: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mobile About heading aligns with portrait top', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: AboutSection())),
      ),
    );

    final heading = find.text('About.');
    final portrait = find.byType(Image);
    expect(tester.getTopLeft(heading).dy,
        closeTo(tester.getTopLeft(portrait).dy, 0.01));
    expect(tester.getTopLeft(portrait).dx,
        greaterThan(tester.view.physicalSize.width / 2 - 160 / 2));
    expect(tester.getTopRight(portrait).dx,
        lessThanOrEqualTo(tester.view.physicalSize.width));
    expect(tester.takeException(), isNull);
  });

  testWidgets('About email is underlined and highlights on hover', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.themeData,
        home:
            const Scaffold(body: SingleChildScrollView(child: AboutSection())),
      ),
    );

    final email = find.text(PortfolioData.email);
    final link = find.ancestor(of: email, matching: find.byType(InkWell));
    final highlight = find.ancestor(
      of: email,
      matching: find.byType(AnimatedContainer),
    );
    expect(email, findsOneWidget);
    expect(
        tester.widget<Text>(email).style?.decoration, TextDecoration.underline);
    expect(tester.widget<InkWell>(link).onTap, isNotNull);

    await tester.ensureVisible(email);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(0, 0));
    await mouse.moveTo(tester.getCenter(email));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<AnimatedContainer>(highlight).decoration as BoxDecoration)
          .color,
      AppColors.accent.withValues(alpha: 0.15),
    );

    await mouse.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<AnimatedContainer>(highlight).decoration as BoxDecoration)
          .color,
      Colors.transparent,
    );
  });

  testWidgets('Navbar renders a wave at its bottom edge', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(appBar: NavBar(onSectionTap: (_) {})),
      ),
    );

    final bar = tester.widget<NavBar>(find.byType(NavBar));
    expect(bar.preferredSize.height, 64 + NavWave.height);
    final clip = tester.widget<ClipPath>(
      find.ancestor(of: find.byType(AppBar), matching: find.byType(ClipPath)),
    );
    final shape = clip.clipper!.getClip(Size(800, bar.preferredSize.height));
    final edge = 64 + NavWave.height / 2;
    expect(shape.contains(Offset(NavWave.wavelength / 4, edge)), isTrue);
    expect(shape.contains(Offset(NavWave.wavelength * 3 / 4, edge)), isFalse);
    // Include a width that is not divisible by the path sampling interval.
    const width = 803.0;
    final clippedEdge = NavWave.edgePath(Size(width, bar.preferredSize.height));
    final paintedEdge = NavWave.edgePath(
      const Size(width, NavWave.height),
      inset: NavWave.strokeWidth / 2,
    );
    final clipEnd = clippedEdge
        .computeMetrics()
        .single
        .getTangentForOffset(
          clippedEdge.computeMetrics().single.length,
        )!
        .position;
    final paintEnd = paintedEdge
        .computeMetrics()
        .single
        .getTangentForOffset(
          paintedEdge.computeMetrics().single.length,
        )!
        .position;
    expect(clipEnd.dx, width);
    expect(paintEnd.dx, width);
    expect(
        clipEnd.dy - 64, closeTo(paintEnd.dy + NavWave.strokeWidth / 2, 0.001));
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
    expect(find.text(PortfolioData.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mobile menu covers the screen and closes from the header', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MyApp());
    final menuIcon = find.byKey(const ValueKey('mobile-menu-open-icon'));
    expect(menuIcon, findsOneWidget);
    expect(tester.getSize(menuIcon), const Size(28, 28));
    expect(tester.widget<CustomPaint>(menuIcon).painter, isNotNull);
    final open = find.ancestor(
      of: menuIcon,
      matching: find.byType(IconButton),
    );
    final openPosition = tester.getCenter(open);
    expect(tester.widget<IconButton>(open).tooltip, isNull);
    await tester.tap(open);
    await tester.pump();
    final overlay = find.byType(MobileNavOverlay);
    final fade = find.ancestor(
      of: overlay,
      matching: find.byType(FadeTransition),
    ).first;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        greaterThan(0));
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        lessThan(1));
    await tester.pumpAndSettle();

    expect(overlay, findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    expect(tester.getTopLeft(overlay), Offset.zero);
    expect(tester.getSize(overlay), const Size(400, 900));
    expect(
      tester
          .widget<Material>(
            find.descendant(of: overlay, matching: find.byType(Material)).first,
          )
          .color,
      AppColors.accent.withValues(alpha: 0.88),
    );
    final labels = ['github', 'linkedin', 'substack', 'email'];
    for (final label in labels) {
      final link = find.descendant(of: overlay, matching: find.text(label));
      expect(link, findsOneWidget);
      final style = tester
          .widget<AnimatedDefaultTextStyle>(
            find.byKey(ValueKey('mobile-menu-style-$label')),
          )
          .style;
      expect(style.fontSize, 36);
      expect(style.fontWeight, FontWeight.w900);
      expect(style.fontFamily, 'CircularStd');
      expect(style.color, AppColors.text);
      expect(style.decoration, TextDecoration.none);
      expect(
        (tester
                .widget<AnimatedContainer>(
                  find.byKey(ValueKey('mobile-menu-underline-$label')),
                )
                .decoration as BoxDecoration)
            .color,
        Colors.transparent,
      );
    }
    expect(
      tester
          .getTopLeft(
              find.descendant(of: overlay, matching: find.text('github')))
          .dy,
      lessThan(tester
          .getTopLeft(
              find.descendant(of: overlay, matching: find.text('linkedin')))
          .dy),
    );
    expect(
      tester
          .getTopLeft(
              find.descendant(of: overlay, matching: find.text('linkedin')))
          .dy,
      lessThan(tester
          .getTopLeft(
              find.descendant(of: overlay, matching: find.text('substack')))
          .dy),
    );
    expect(
      tester
          .getTopLeft(
              find.descendant(of: overlay, matching: find.text('substack')))
          .dy,
      lessThan(tester
          .getTopLeft(
              find.descendant(of: overlay, matching: find.text('email')))
          .dy),
    );
    final github = find.descendant(of: overlay, matching: find.text('github'));
    final githubStyle = find.byKey(const ValueKey('mobile-menu-style-github'));
    final githubUnderline =
        find.byKey(const ValueKey('mobile-menu-underline-github'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(0, 0));
    await mouse.moveTo(tester.getCenter(github));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final halfway = tester.renderObject<RenderParagraph>(github).text.style!;
    expect(halfway.color, isNot(AppColors.text));
    expect(halfway.color, isNot(Colors.white));
    expect(halfway.decoration, TextDecoration.none);
    final halfwayUnderline = tester.widget<DecoratedBox>(
      find.descendant(of: githubUnderline, matching: find.byType(DecoratedBox)),
    );
    final halfwayColor = (halfwayUnderline.decoration as BoxDecoration).color;
    expect(halfwayColor, isNot(Colors.transparent));
    expect(halfwayColor, isNot(Colors.white));
    await tester.pumpAndSettle();
    final hovered = tester.renderObject<RenderParagraph>(github).text.style!;
    expect(hovered.color, Colors.white);
    expect(hovered.decoration, TextDecoration.none);
    expect(
        (tester.widget<AnimatedContainer>(githubUnderline).decoration
                as BoxDecoration)
            .color,
        Colors.white);
    expect(tester.widget<AnimatedDefaultTextStyle>(githubStyle).style.color,
        Colors.white);
    final closeColor = find.byKey(const ValueKey('mobile-menu-close-color'));
    final closeTween = tester.widget<TweenAnimationBuilder<Color?>>(closeColor);
    expect(closeTween.duration, const Duration(milliseconds: 220));
    expect(closeTween.tween.end, AppColors.text);
    final close =
        find.descendant(of: overlay, matching: find.byType(IconButton));
    await mouse.moveTo(tester.getCenter(close));
    await tester.pump();
    expect(tester.widget<TweenAnimationBuilder<Color?>>(closeColor).tween.end,
        Colors.white);
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();
    final unhovered = tester.renderObject<RenderParagraph>(github).text.style!;
    expect(unhovered.color, AppColors.text);
    expect(unhovered.decoration, TextDecoration.none);
    expect(
        (tester.widget<AnimatedContainer>(githubUnderline).decoration
                as BoxDecoration)
            .color,
        Colors.transparent);
    expect(tester.widget<TweenAnimationBuilder<Color?>>(closeColor).tween.end,
        AppColors.text);
    expect(tester.getCenter(close).dx, closeTo(openPosition.dx, 0.01));
    expect(tester.getCenter(close).dy, closeTo(openPosition.dy + 4, 0.01));
    expect(tester.widget<IconButton>(close).tooltip, isNull);
    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(overlay, findsOneWidget);
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        greaterThan(0));
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        lessThan(1));
    await tester.pumpAndSettle();
    expect(overlay, findsNothing);
    expect(open, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Footer clips and outlines its top with the navbar wave', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FooterSection())),
    );

    final clip = tester.widget<ClipPath>(
      find.descendant(
          of: find.byType(FooterSection), matching: find.byType(ClipPath)),
    );
    final size = tester.getSize(find.byType(FooterSection));
    final shape = clip.clipper!.getClip(size);
    expect(
        shape
            .contains(const Offset(NavWave.wavelength / 4, NavWave.height / 2)),
        isFalse);
    expect(
        shape.contains(
            const Offset(NavWave.wavelength * 3 / 4, NavWave.height / 2)),
        isTrue);
    final paint = tester.widget<CustomPaint>(
      find.descendant(
          of: find.byType(FooterSection), matching: find.byType(CustomPaint)),
    );
    expect(paint.foregroundPainter, isA<NavWavePainter>());
    expect((paint.foregroundPainter! as NavWavePainter).topEdge, isTrue);
    expect(find.text(PortfolioData.footerText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('Projects use the five uploaded placeholder images in order', () {
    expect(
      PortfolioData.projects.map((project) => project.imagePath),
      [
        'web/assets/images/placeholder1.jpg',
        'web/assets/images/placeholder2.jpg',
        'web/assets/images/placeholder3.jpg',
        'web/assets/images/placeholder4.jpeg',
        'web/assets/images/placeholder5.jpg',
      ],
    );
  });

  testWidgets('Project card and dialog show the project photo', (
    WidgetTester tester,
  ) async {
    final project = PortfolioData.projects.first;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProjectCard(project: project)),
      ),
    );

    final cardImage = find.descendant(
      of: find.byType(ProjectCard),
      matching: find.byType(Image),
    );
    expect((tester.widget<Image>(cardImage).image as AssetImage).assetName,
        project.imagePath);
    expect(tester.widget<Image>(cardImage).fit, BoxFit.cover);

    await tester.tap(find.byType(ProjectCard));
    await tester.pumpAndSettle();
    final dialogImage = find.descendant(
      of: find.byType(ProjectDetailDialog),
      matching: find.byType(Image),
    );
    expect((tester.widget<Image>(dialogImage).image as AssetImage).assetName,
        project.imagePath);
    expect(tester.widget<Image>(dialogImage).fit, BoxFit.cover);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Project card reveals white text on accent tint on hover', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: ProjectCard(project: PortfolioData.projects.first),
            ),
          ),
        ),
      ),
    );

    final overlay = find.descendant(
      of: find.byType(ProjectCard),
      matching: find.byType(AnimatedOpacity),
    );
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(ProjectCard),
        matching: find.byType(ClipRRect),
      ),
    );
    final inkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(ProjectCard),
        matching: find.byType(InkWell),
      ),
    );
    expect(clip.borderRadius, const BorderRadius.all(Radius.circular(50)));
    expect(inkWell.borderRadius, clip.borderRadius);
    expect(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: find.byType(Material),
      ),
      findsOneWidget,
    );
    expect(tester.widget<AnimatedOpacity>(overlay).opacity, 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(0, 0));
    await mouse.moveTo(tester.getCenter(find.byType(ProjectCard)));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(overlay).opacity, 1);
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(of: overlay, matching: find.byType(ColoredBox)),
          )
          .color,
      AppColors.accent.withValues(alpha: 0.7),
    );
    expect(
      tester
          .widget<Text>(find.text(PortfolioData.projects.first.title))
          .style
          ?.color,
      Colors.white,
    );
    expect(
      tester
          .widget<Text>(find.text(PortfolioData.projects.first.company))
          .style
          ?.color,
      Colors.white,
    );

    await mouse.moveTo(const Offset(500, 500));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(overlay).opacity, 0);
  });

  testWidgets('Featured work shows two cards per row on wide screens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FeaturedWorkSection())),
    );

    final cards = find.byType(ProjectCard);
    expect(cards, findsNWidgets(3));
    expect(
        tester.getTopLeft(cards.at(0)).dy, tester.getTopLeft(cards.at(1)).dy);
    expect(
      tester.getTopLeft(cards.at(2)).dy,
      greaterThan(tester.getTopLeft(cards.at(1)).dy),
    );
  });

  testWidgets('Home page renders hero and section titles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.byType(HeroAsciiArt), findsOneWidget);
    expect(find.text('Featured Work.'), findsOneWidget);
    expect(find.text('About.'), findsOneWidget);
    expect(find.text('Experience.'), findsOneWidget);
    expect(find.text('Skills.'), findsOneWidget);
    expect(find.text('Contact.'), findsOneWidget);
    expect(find.byType(ProjectCard), findsNWidgets(3));
  });
}
