import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/financial_history_chart.dart';

MonthlyFinancialHistory sample({
  String month = '2026-10',
  bool current = false,
  int? netWorth = 150000,
  int? debt = 25000,
  int spending = 12345,
}) {
  final observed = DateTime.utc(2026, 10, 15, 18);
  return MonthlyFinancialHistory(
    month: month,
    isCurrent: current,
    netWorth: netWorth,
    totalDebt: debt,
    spending: spending,
    accountCount: 2,
    creditAccountCount: 1,
    observedCreditAccountCount: debt == null ? 0 : 1,
    observations: netWorth == null ? {} : {'cash': observed, 'card': observed},
    oldestObservation: netWorth == null ? null : observed,
    oldestCreditObservation: debt == null ? null : observed,
  );
}

Future<void> mount(WidgetTester tester, List<MonthlyFinancialHistory> history,
    {double width = 800, double textScale = 1}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: SingleChildScrollView(
          child: FinancialHistoryChart(history: history),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder get value => find.byKey(const ValueKey('financial-history-value'));
Finder get plot => find.byKey(const ValueKey('financial-history-plot'));

void main() {
  testWidgets(
      'shows current values, toggles metrics, and explains observations',
      (tester) async {
    await mount(tester, [sample(), sample(month: '2026-11', current: true)]);
    expect(find.text('Financial history'), findsOneWidget);
    expect(
        find.text('Nov 2026 (so far): Net worth: \$1,500.00'), findsOneWidget);
    expect(find.textContaining('property, investments, or untracked loans'),
        findsOneWidget);
    expect(find.textContaining('2 of 2 tracked accounts'), findsOneWidget);
    expect(find.textContaining('2026-10-15 12:00 MDT (America/Denver)'),
        findsOneWidget);
    expect(find.textContaining('Current observations, not month-end'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Total debt'));
    await tester.pumpAndSettle();
    expect(
        find.text('Nov 2026 (so far): Total debt: \$250.00'), findsOneWidget);
    expect(
        find.textContaining('1 of 1 tracked credit accounts'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Monthly spending'));
    await tester.pumpAndSettle();
    expect(find.text('Nov 2026 (so far): Monthly spending: \$123.45'),
        findsOneWidget);
    expect(find.textContaining('through the current reporting date'),
        findsOneWidget);
    expect(find.textContaining('Transfers, card payments'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropdown exposes chronological months and missing values',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await mount(tester, [
      sample(netWorth: null, debt: null),
      sample(month: '2026-11', current: true)
    ]);
    expect(find.bySemanticsLabel(RegExp('Net worth chart')), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oct 2026').last);
    await tester.pumpAndSettle();
    expect(find.text('Oct 2026: Net worth: Unavailable'), findsOneWidget);
    expect(find.textContaining('required balance observations are missing'),
        findsOneWidget);
    expect(find.textContaining('0 of 2 tracked accounts'), findsOneWidget);
    expect(find.textContaining('earlier observations are carried forward'),
        findsOneWidget);
    expect(find.textContaining('Gaps mean unavailable balances, not zero'),
        findsOneWidget);
    semantics.dispose();
  });

  testWidgets('tap, hover, and arrow keys select an accessible month value',
      (tester) async {
    await mount(tester,
        [sample(netWorth: -12345), sample(month: '2026-11', current: true)]);
    final rect = tester.getRect(plot);
    await tester.tapAt(Offset(rect.left + 84, rect.top + 60));
    await tester.pumpAndSettle();
    expect(find.text('Oct 2026: Net worth: -\$123.45'), findsOneWidget);
    final node = Focus.of(tester.element(plot));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
        find.text('Nov 2026 (so far): Net worth: \$1,500.00'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('Oct 2026: Net worth: -\$123.45'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(rect.right - 68, rect.top + 80));
    await mouse.moveTo(Offset(rect.right - 69, rect.top + 81));
    await tester.pumpAndSettle();
    expect(
        find.text('Nov 2026 (so far): Net worth: \$1,500.00'), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('single zero, unknown, and empty history paint without errors',
      (tester) async {
    for (final history in <List<MonthlyFinancialHistory>>[
      [sample(netWorth: 0, debt: 0, spending: 0)],
      [sample(netWorth: null, debt: null)],
      [
        sample(),
        sample(month: '2026-11', netWorth: null),
        sample(month: '2026-12', netWorth: -50000)
      ],
      [],
    ]) {
      await mount(tester, history);
      expect(tester.takeException(), isNull);
      if (history.isEmpty) {
        expect(find.text('Financial history starts in October 2026.'),
            findsOneWidget);
      } else {
        expect(value, findsOneWidget);
        expect(plot, findsOneWidget);
      }
    }
  });

  testWidgets(
      '320px history scrolls horizontally without overflow, even with larger text',
      (tester) async {
    final history = List.generate(15, (i) {
      final date = DateTime(2026, 10 + i);
      return sample(
          month: '${date.year}-${date.month.toString().padLeft(2, '0')}',
          current: i == 14,
          netWorth: i.isEven ? -50000 : 200000);
    });
    await mount(tester, history, width: 320, textScale: 1.3);
    expect(tester.takeException(), isNull);
    final horizontal = find.byWidgetPredicate((widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal);
    expect(horizontal, findsOneWidget);
    expect(tester.getSize(plot).width, greaterThan(320));
    await tester.drag(horizontal, const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Monthly spending'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
