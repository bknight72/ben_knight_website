import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';
import 'support.dart';

class ImportRepository extends LedgerRepository {
  final List<String> calls = [];
  final bool invalid;
  ImportRepository({this.invalid = false})
      : super(SupabaseClient('https://example.supabase.co', 'public-key',
            isolate: TestJsonIsolate(),
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  @override
  Future<Json> api(String path, {Json? body, bool get = false}) async {
    calls.add(path);
    expect(body?['mapping']['date'], 'date');
    expect(body?['mapping']['description'], 'description');
    expect(body?['mapping']['amount'], 'amount');
    if (path.endsWith('commit')) return {'inserted': 1, 'duplicates': 0};
    return {
      'rowCount': 1,
      'rows': [
        {
          'transaction_date': '2026-11-01',
          'description': 'Synthetic shop',
          'amount_minor': -1234
        }
      ],
      'errors': invalid
          ? [
              {'row': 2, 'message': 'Invalid date.'}
            ]
          : [],
      'duplicateCandidates': [],
      'overlapRequiresConfirmation': false
    };
  }
}

class OverlapRepository extends ImportRepository {
  @override
  Future<Json> api(String path, {Json? body, bool get = false}) async => {
        'rowCount': 1,
        'rows': [],
        'errors': [],
        'duplicateCandidates': [
          {'date': '2026-11-01', 'amountMinor': -100}
        ],
        'overlapRequiresConfirmation': true,
      };
}

Future<void> choose(WidgetTester tester, String label, String value) async {
  final dropdown = find.ancestor(
      of: find.text(label),
      matching: find.byType(DropdownButtonFormField<String>));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('duplicate candidates require explicit review before commit',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = OverlapRepository();
    addTearDown(repo.client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ImportDialog(
                repository: repo,
                accounts: const [
                  {'id': 'a', 'name': 'Synthetic', 'source': 'manual'}
                ],
                csv: 'date,description,amount\n2026-11-01,Shop,-1',
                headers: const ['date', 'description', 'amount']))));
    await tester.pumpAndSettle();
    await choose(tester, 'Transaction date', 'date');
    await choose(tester, 'Description', 'description');
    await choose(tester, 'Signed amount column', 'amount');
    await tester.tap(find.text('Validate preview'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate candidates: 1'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Commit import'))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Commit import'))
            .onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });
  for (final invalid in [false, true]) {
    testWidgets(
        'CSV requires server preview and ${invalid ? 'blocks invalid' : 'commits valid'} rows',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = ImportRepository(invalid: invalid);
      addTearDown(repo.client.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => ImportDialog(
                              repository: repo,
                              accounts: const [
                                {
                                  'id': 'a',
                                  'name': 'Synthetic',
                                  'source': 'manual'
                                }
                              ],
                              csv:
                                  'date,description,amount\n2026-11-01,Synthetic shop,-12.34',
                              headers: const [
                                'date',
                                'description',
                                'amount'
                              ])),
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Commit import'))
              .onPressed,
          isNull);
      await choose(tester, 'Transaction date', 'date');
      await choose(tester, 'Description', 'description');
      await choose(tester, 'Signed amount column', 'amount');
      await tester.tap(find.text('Validate preview'));
      await tester.pumpAndSettle();
      expect(repo.calls, ['imports/preview']);
      if (invalid) {
        expect(find.text('Row 2: Invalid date.'), findsOneWidget);
        expect(
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Commit import'))
                .onPressed,
            isNull);
      } else {
        expect(
            find.textContaining('Synthetic shop / -\$12.34'), findsOneWidget);
        await choose(tester, 'Date format', 'MM/DD/YYYY');
        expect(
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Commit import'))
                .onPressed,
            isNull);
        await tester.tap(find.text('Validate preview'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Commit import'));
        await tester.pumpAndSettle();
        expect(repo.calls,
            ['imports/preview', 'imports/preview', 'imports/commit']);
        expect(find.text('Map and preview CSV'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
