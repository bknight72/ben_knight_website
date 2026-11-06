import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';
import 'support.dart';

class FixtureRepository extends LedgerRepository {
  final bool empty;
  final bool fail;
  final bool stripe;
  FixtureRepository(
      {this.empty = false, this.fail = false, this.stripe = false})
      : super(SupabaseClient('https://example.supabase.co', 'test-public-key',
            isolate: TestJsonIsolate(),
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  @override
  Future<Json> api(String path, {Json? body, bool get = false}) async => {
        'month': '2026-11',
        'reservedAttempts': 2,
        'limit': 50,
        'remainingAttempts': 48,
        'accounts': [
          {'accountId': 'a', 'nextEligibleRefreshAt': '2026-11-07T00:00:00Z'}
        ]
      };
  @override
  Future<List<Json>> rows(String table) async {
    if (fail) throw Exception('must never display this financial content');
    if (empty) return [];
    return switch (table) {
      'accounts' => [
          {
            'id': 'a',
            'name': 'Synthetic checking',
            'source': stripe ? 'stripe' : 'manual',
            'kind': 'cash',
            'institution': 'Test bank',
            'last_four': '1234'
          }
        ],
      'balance_snapshots' => [
          {
            'id': 's',
            'account_id': 'a',
            'current_minor': 200000,
            'observed_at': '2026-11-01T12:00:00Z'
          }
        ],
      'transactions' => [
          {
            'id': 't1',
            'account_id': 'a',
            'amount_minor': -2500,
            'description': 'Synthetic groceries',
            'status': 'posted',
            'transaction_date': '2026-11-02',
            'posted_date': '2026-11-02'
          },
          {
            'id': 't2',
            'account_id': 'a',
            'amount_minor': -1500,
            'description': 'Synthetic pending',
            'status': 'pending',
            'transaction_date': '2026-11-03'
          },
        ],
      'transaction_annotations' => [
          {
            'transaction_id': 't1',
            'category_id': 'c',
            'note': 'Test annotation'
          }
        ],
      'categories' => [
          {'id': 'c', 'name': 'Groceries', 'kind': 'expense'}
        ],
      'monthly_budgets' => [
          {
            'id': 'b',
            'category_id': 'c',
            'month': '2026-11-01',
            'amount_minor': 40000
          }
        ],
      _ => [],
    };
  }
}

Future<void> mount(WidgetTester tester,
    {bool mobile = false, bool empty = false, bool fail = false}) async {
  tester.view.physicalSize = Size(mobile ? 390 : 1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = FixtureRepository(empty: empty, fail: fail);
  addTearDown(repo.client.dispose);
  await tester.pumpWidget(
      MaterialApp(home: LedgerShell(repository: repo, onLogout: () async {})));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'connected account actions disclose costs, cooldowns, and preserve confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = FixtureRepository(stripe: true);
    addTearDown(repo.client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LedgerShell(repository: repo, onLogout: () async {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-11-07T00:00:00Z'), findsOneWidget);
    await tester.tap(find.text('Request paid refresh'));
    await tester.pumpAndSettle();
    expect(find.textContaining('approximately \$0.10'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Refresh requested.'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'dashboard reports real repository snapshot without pending double count',
      (tester) async {
    await mount(tester);
    expect(find.text('\$2,000.00'), findsWidgets);
    expect(find.text('Synthetic checking'), findsOneWidget);
    expect(find.text('TRACKED NET POSITION'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('transactions search and status filter use in-memory results',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('2 transactions'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'groceries');
    await tester.pumpAndSettle();
    expect(find.text('1 transactions'), findsOneWidget);
    expect(find.text('Synthetic pending'), findsNothing);
    expect(find.text('Synthetic groceries'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('accounts show manual snapshot and disabled live bank linking',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Record balance'), findsOneWidget);
    expect(find.textContaining('Bank linking is disabled'), findsOneWidget);
    expect(find.textContaining('1234'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'manual account dialog validates required name before network writes',
      (tester) async {
    await mount(tester, empty: true);
    await tester.tap(find.text('Add your first account'));
    await tester.pumpAndSettle();
    expect(find.text('Add a manual account'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an account name.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('refresh allowance is shown with explicit UTC reservations',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Balance refresh allowance'), findsOneWidget);
    expect(find.text('2026-11: 2 / 50 attempts reserved. 48 remaining.'),
        findsOneWidget);
  });
  testWidgets(
      'annotation editor shows independent transfer and card payment flags',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synthetic groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Annotate transaction'), findsOneWidget);
    expect(find.text('Own-account transfer'), findsOneWidget);
    expect(find.text('Card payment'), findsOneWidget);
    await tester.tap(find.text('Own-account transfer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'snapshot rejects impossible dates instead of normalizing silently',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record balance'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '100.00');
    await tester.enterText(find.byType(TextField).last, '2026-02-30');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid observation date, not in the future.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'category creation and budgets validate empty or malformed values',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a category name.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set category budget'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '-5.00');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Budget must be zero or positive.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('budgets and export screens remain usable without records',
      (tester) async {
    await mount(tester, empty: true);
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    expect(find.text('Start with your categories'), findsOneWidget);
    await tester.tap(find.text('Import & export'));
    await tester.pumpAndSettle();
    expect(find.text('No imports yet.'), findsOneWidget);
    expect(find.text('Export JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('mobile workspace navigation is drawer-based with no overflow',
      (tester) async {
    await mount(tester, mobile: true, empty: true);
    expect(find.text('Your ledger starts here'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('No accounts yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'failed load does not substitute zeros or leak raw server content',
      (tester) async {
    await mount(tester, fail: true);
    expect(find.text('Data is unavailable'), findsOneWidget);
    expect(find.textContaining('must never display'), findsNothing);
    expect(find.text('TRACKED NET POSITION'), findsNothing);
  });
  testWidgets('auth exposes login and recovery but no public signup',
      (tester) async {
    final client = SupabaseClient(
        'https://example.supabase.co', 'test-public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.textContaining('Sign up'), findsNothing);
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(find.text('Send recovery email'), findsOneWidget);
    expect(find.text('Password'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
