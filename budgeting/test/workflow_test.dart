import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/app.dart';
import 'package:supabase/supabase.dart';
import 'auth_test.dart' show session;
import 'support.dart';

void main() {
  testWidgets(
      'owner workflow creates account, snapshot, annotations, budgets and export',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final writes = <http.Request>[];
    final accounts = <Map<String, dynamic>>[];
    final snapshots = <Map<String, dynamic>>[];
    final categories = <Map<String, dynamic>>[
      {'id': 'cat', 'name': 'Groceries', 'kind': 'expense'}
    ];
    final budgets = <Map<String, dynamic>>[];
    final annotations = <Map<String, dynamic>>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      final path = request.url.path;
      Object result;
      if (path.endsWith('/token')) {
        result = session('aal2');
      } else if (path.endsWith('/is_budget_owner')) {
        result = true;
      } else if (path.endsWith('/usage')) {
        result = {
          'month': '2026-11',
          'reservedAttempts': 1,
          'limit': 50,
          'remainingAttempts': 49,
          'accounts': []
        };
      } else if (path.endsWith('/export')) {
        result = {'version': 1, 'accounts': accounts};
      } else if (path.endsWith('/logout')) {
        result = {};
      } else {
        final table = path.split('/').last;
        final data = switch (table) {
          'accounts' => accounts,
          'balance_snapshots' => snapshots,
          'categories' => categories,
          'monthly_budgets' => budgets,
          'transaction_annotations' => annotations,
          'transactions' => [
              {
                'id': 'tx',
                'account_id': 'account',
                'amount_minor': -1234,
                'description': 'Synthetic purchase',
                'transaction_date': '2026-11-01',
                'posted_date': '2026-11-01',
                'status': 'posted'
              }
            ],
          'profiles' => <Map<String, dynamic>>[],
          _ => <Map<String, dynamic>>[],
        };
        if (request.method != 'GET') {
          writes.add(request);
          final row =
              Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          if (request.method == 'PATCH' && data.isNotEmpty) {
            data.first.addAll(row);
          } else {
            data.add({
              'id': table == 'accounts' ? 'account' : 'row-${data.length}',
              ...row
            });
          }
          result = {};
        } else {
          result = data;
        }
      }
      return http.Response(jsonEncode(result), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'owner@example.test');
    await tester.enterText(find.byType(TextField).last, 'synthetic-password');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add your first account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Synthetic checking');
    await tester.enterText(find.byType(TextField).at(1), 'Synthetic bank');
    await tester.enterText(find.byType(TextField).at(2), '1234');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(accounts.single['kind'], 'cash');
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record balance'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '2500.45');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(snapshots.single['current_minor'], 250045);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synthetic purchase'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'Synthetic note');
    await tester.tap(find.text('Card payment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(annotations.single['note'], 'Synthetic note');
    expect(annotations.single['is_card_payment'], true);
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set category budget'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '400.00');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(budgets.single['amount_minor'], 40000);
    await tester.tap(find.text('Add category'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Travel');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(categories.any((c) => c['name'] == 'Travel'), true);
    await tester.tap(find.text('Rename').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Food');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(categories.first['name'], 'Food');
    await tester.tap(find.byTooltip('Reporting settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Import & export'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Export JSON'));
    await tester.tap(find.text('Export JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Export downloaded. Keep it private.'), findsOneWidget);
    expect(writes.length, greaterThanOrEqualTo(7));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to your ledger.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
