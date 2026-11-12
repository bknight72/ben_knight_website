import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real browser loads bundled config and responsive standalone app',
      (tester) async {
    final config = await AppConfig.load();
    expect(config.currency, 'USD');
    expect(config.reportingTimezone, 'America/Denver');
    await tester.pumpWidget(BudgetApp(config: config));
    await tester.pumpAndSettle();
    expect(find.text("Ben's Budgeteering"), findsOneWidget);
    expect(find.textContaining('No account or financial data'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('invalid public config never initializes financial service',
      (tester) async {
    await tester.pumpWidget(const BudgetApp(configurationError: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('No financial service was initialized'),
        findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
