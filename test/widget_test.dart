// Smoke test for the portfolio home page: verifies the hero headline,
// section titles, and project cards render.

import 'package:flutter_test/flutter_test.dart';

import 'package:ben_knight_website2/main.dart';
import 'package:ben_knight_website2/widgets/hero_ascii_art.dart';
import 'package:ben_knight_website2/widgets/project_card.dart';

void main() {
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
