import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/app.dart';

void main() {
  testWidgets(
      'unconfigured app shows a safe empty state, not fabricated finances',
      (tester) async {
    await tester.pumpWidget(const BudgetApp());
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
        "Ben's Budgeteering");
    expect(find.text('A private place for your money.'), findsOneWidget);
    expect(find.textContaining('No account or financial data'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
    expect(find.textContaining('\$'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
  testWidgets('entry layout works on narrow mobile screens', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const BudgetApp());
    expect(find.text("Ben's Budgeteering"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop entry retains the dedicated product identity',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const BudgetApp());
    expect(find.text('Less noise.\nMore clarity.'), findsOneWidget);
    expect(find.text('PRIVATE BY DESIGN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('landscape entry avoids overflowing the decorative sidebar',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const BudgetApp());
    expect(find.text("Ben's Budgeteering"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final width in [320.0, 360.0, 900.0]) {
    testWidgets('full app name fits entry layout at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const BudgetApp());
      expect(find.text("Ben's Budgeteering"), findsOneWidget);
      final brand = tester.getRect(find.byType(Brand));
      expect(brand.left, greaterThanOrEqualTo(0));
      expect(brand.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    });
  }
}
