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
      'owner workflow creates account, snapshot, annotations, groups and export',
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
    final budgets = <Map<String, dynamic>>[
      {
        'id': 'budget',
        'category_id': 'cat',
        'month': '2026-11-01',
        'amount_minor': 40000
      }
    ];
    final groups = <Map<String, dynamic>>[];
    var groupsRevision = 7;
    var groupReads = 0;
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
      } else if (path.endsWith('/budgeteer_read') ||
          path.endsWith('/budgeteer_mutate')) {
        if (path.endsWith('/budgeteer_read')) {
          groupReads++;
        } else {
          writes.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['p_operation'], 'group_save');
          expect(body['p_revision'], 0);
          final payload = body['p_payload'] as Map<String, dynamic>;
          expect(payload['schema_version'], 4);
          expect(payload['expected_groups_revision'], groupsRevision);
          expect(payload.containsKey('parent_group_id'), isTrue);
          if (payload['id'] == null) {
            groups.add({
              'id': 'group-${groups.length}',
              'owner_id': 'owner',
              'sort_position': groups.length,
              ...payload,
            });
          } else {
            groups.singleWhere((g) => g['id'] == payload['id']).addAll(payload);
          }
          groupsRevision++;
        }
        result = {
          'schema_version': 4,
          'owner_id': 'owner',
          'groups_revision': groupsRevision,
          'plan': null,
          'groups': groups,
          'entries': [],
          'legacy_labels': [],
          'legacy_entry_labels': [],
          'excluded_source_count': 0,
        };
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
    await tester.tap(find.text('Group manager'));
    await tester.pumpAndSettle();
    expect(groupReads, 1);
    expect(
        writes.where((r) => r.url.path.endsWith('/budgeteer_mutate')), isEmpty);
    expect(find.text('Add category'), findsNothing);
    expect(find.text('Set category budget'), findsNothing);
    await tester.tap(find.text('Add deposit group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Paychecks');
    await tester.tap(find.text('Save deposit group'));
    await tester.pumpAndSettle();
    expect(groups.single['kind'], 'deposit');
    expect(groups.single['parent_group_id'], isNull);
    expect(find.text('Paychecks'), findsOneWidget);
    await tester.tap(find.text('Add withdrawal group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Travel');
    await tester.tap(find.text('Save group'));
    await tester.pumpAndSettle();
    expect(groups.last['kind'], 'withdrawal');
    expect(groups.last['name'], 'Travel');
    await tester.tap(find.byTooltip('Edit group Travel'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Food');
    await tester.tap(find.text('Save group'));
    await tester.pumpAndSettle();
    expect(groups.last['name'], 'Food');
    expect(find.text('Food'), findsOneWidget);
    expect(categories.single['name'], 'Groceries');
    expect(budgets.single['amount_minor'], 40000);
    expect(
        writes.where((r) =>
            r.url.path.endsWith('/categories') ||
            r.url.path.endsWith('/monthly_budgets')),
        isEmpty);
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Reporting settings'), findsNothing);
    await tester.tap(find.text('Import & export'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Export JSON'));
    await tester.tap(find.text('Export JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Export downloaded. Keep it private.'), findsOneWidget);
    expect(writes.length, 6);
    expect(writes.where((r) => r.url.path.endsWith('/profiles')), isEmpty);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text("Welcome to Ben's Budgeteering."), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
