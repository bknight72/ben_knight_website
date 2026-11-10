import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/budgeteer_domain.dart';
import 'workspace_test.dart' show FixtureRepository;

class PlanningRepository extends FixtureRepository {
  int reads = 0;
  @override
  Future<BudgeteerState> budgeteerRead(String month) async {
    reads++;
    return const BudgeteerState.empty();
  }
}

void main() {
  testWidgets('Budgeteer navigation reloads persisted month state',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = PlanningRepository();
    addTearDown(repository.client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LedgerShell(repository: repository, onLogout: () async {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    expect(find.text('Give every dollar a place.'), findsOneWidget);
    expect(repository.reads, 1);
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    expect(repository.reads, 2);
    expect(tester.takeException(), isNull);
  });
}
