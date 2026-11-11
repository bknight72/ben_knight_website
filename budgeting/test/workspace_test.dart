import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/budgeteer_domain.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/financial_history_chart.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';
import 'support.dart';

class FixtureRepository extends LedgerRepository {
  final bool empty;
  final bool fail;
  final bool stripe;
  final bool credit;
  FixtureRepository(
      {this.empty = false,
      this.fail = false,
      this.stripe = false,
      this.credit = false})
      : super(SupabaseClient('https://example.supabase.co', 'test-public-key',
            isolate: TestJsonIsolate(),
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  @override
  Future<Json> api(String path, {Json? body, bool get = false}) async =>
      path == 'connections/pending'
          ? {'sessions': <Json>[]}
          : {
              'month': '2026-11',
              'reservedAttempts': 2,
              'limit': 50,
              'remainingAttempts': 48,
              'accounts': [
                {'accountId': 'a', 'nextEligibleRefreshAt': null}
              ]
            };
  @override
  Future<BudgeteerState> budgeteerRead(String month) async =>
      const BudgeteerState.empty();
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
          },
          if (credit)
            {
              'id': 'card',
              'name': 'Synthetic card',
              'kind': 'credit',
              'source': 'stripe'
            },
        ],
      'balance_snapshots' => [
          {
            'id': 's',
            'account_id': 'a',
            'current_minor': 200000,
            'observed_at': '2026-11-01T12:00:00Z'
          },
          if (credit)
            {
              'id': 'card-snapshot',
              'account_id': 'card',
              'current_minor': -300000,
              'source': 'stripe',
              'observed_at': '2026-11-01T12:00:00Z'
            },
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
      'connected account actions disclose costs without app cooldown and preserve confirmation',
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
    await tester.tap(find.text('Request paid refresh'));
    await tester.pumpAndSettle();
    expect(find.textContaining('approximately \$0.10'), findsOneWidget);
    expect(find.textContaining('There is no app cooldown'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Refresh requested.'), findsOneWidget);
    await tester.tap(find.text('Request paid refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh balance?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
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
    expect(find.text('Synthetic checking'), findsNothing);
    expect(find.text('TRACKED NET POSITION'), findsOneWidget);
    expect(find.byType(FinancialHistoryChart), findsOneWidget);
    expect(find.text('Spending by category'), findsNothing);
    expect(find.text('Account coverage'), findsNothing);
    expect(find.text('Recent activity'), findsNothing);
    expect(find.byTooltip('Reporting settings'), findsNothing);
    final heading = tester.widget<Text>(find.text('Overview').last);
    expect(heading.style?.color, darkSurfaceTitle);
    expect(tester.takeException(), isNull);
  });
  testWidgets('negative Stripe credit is debt in overview and history',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = FixtureRepository(credit: true);
    addTearDown(repo.client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LedgerShell(repository: repo, onLogout: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('-\$1,000.00'), findsWidgets);
    final chart = tester
        .widget<FinancialHistoryChart>(find.byType(FinancialHistoryChart));
    expect(chart.history.last.netWorth, -100000);
    expect(chart.history.last.totalDebt, 300000);
    await tester.ensureVisible(find.text('Total debt'));
    await tester.tap(find.text('Total debt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('\$3,000.00'), findsWidgets);
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
  testWidgets('group manager validates names without exposing category limits',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Group manager'));
    await tester.pumpAndSettle();
    expect(find.text('Budgets'), findsNothing);
    expect(find.text('Add category'), findsNothing);
    expect(find.text('Set category budget'), findsNothing);
    expect(find.text('Deposit groups'), findsOneWidget);
    expect(find.text('Withdrawal groups'), findsOneWidget);
    await tester.tap(find.text('Add deposit group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save deposit group'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name.'), findsOneWidget);
    expect(find.text('Parent group'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add withdrawal group'));
    await tester.pumpAndSettle();
    expect(find.text('Parent group'), findsOneWidget);
    await tester.tap(find.text('Save group'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('group manager and export remain usable without records',
      (tester) async {
    await mount(tester, empty: true);
    await tester.tap(find.text('Group manager'));
    await tester.pumpAndSettle();
    expect(find.text('No deposit groups yet.'), findsOneWidget);
    expect(find.text('No withdrawal groups yet.'), findsOneWidget);
    expect(find.text('Add deposit group'), findsOneWidget);
    expect(find.text('Add withdrawal group'), findsOneWidget);
    await tester.tap(find.text('Import & export'));
    await tester.pumpAndSettle();
    expect(find.text('No imports yet.'), findsOneWidget);
    expect(find.text('Export JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('mobile workspace navigation is drawer-based with no overflow',
      (tester) async {
    await mount(tester, mobile: true, empty: true);
    expect(find.text('Your budget starts here'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    final picker = find.byTooltip(RegExp('Choose reporting month:'));
    expect(find.ancestor(of: picker, matching: find.byType(Drawer)),
        findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('February'));
    await tester.pumpAndSettle();
    final selectedMonth = tester
        .widget<Text>(find.descendant(
            of: find.widgetWithIcon(
                OutlinedButton, Icons.calendar_today_outlined),
            matching: find.byType(Text)))
        .data!;
    expect(selectedMonth.endsWith('-02'), isTrue);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('No accounts yet'), findsOneWidget);
    expect(find.byTooltip('Refresh data'), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text(selectedMonth), findsOneWidget);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Only $selectedMonth'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group manager'));
    await tester.pumpAndSettle();
    expect(find.text('No deposit groups yet.'), findsOneWidget);
    expect(find.text('No withdrawal groups yet.'), findsOneWidget);
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
