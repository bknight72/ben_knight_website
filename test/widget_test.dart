// Smoke test for the portfolio home page: verifies the hero headline,
// section titles, and project cards render.

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ben_knight_website2/data/portfolio_data.dart';
import 'package:ben_knight_website2/main.dart';
import 'package:ben_knight_website2/theme/app_theme.dart';
import 'package:ben_knight_website2/widgets/about_section.dart';
import 'package:ben_knight_website2/widgets/featured_work_section.dart';
import 'package:ben_knight_website2/widgets/footer_section.dart';
import 'package:ben_knight_website2/widgets/hero_ascii_art.dart';
import 'package:ben_knight_website2/widgets/nav_bar.dart';
import 'package:ben_knight_website2/widgets/nav_wave.dart';
import 'package:ben_knight_website2/widgets/project_card.dart';

void main() {
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
