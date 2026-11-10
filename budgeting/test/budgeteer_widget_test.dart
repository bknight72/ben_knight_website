import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/budgeteer.dart';
import 'package:private_budgeting/budgeteer_domain.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';

class _Repository extends LedgerRepository {
  _Repository(this.state)
      : super(SupabaseClient('https://example.supabase.co', 'public-test-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  BudgeteerState state;
  Object? readError;
  Object? saveError;
  Completer<BudgeteerState>? pending;
  final calls = <Json>[];
  final months = <String>[];

  @override
  Future<BudgeteerState> budgeteerRead(String month) async {
    months.add(month);
    if (readError != null) throw readError!;
    return state;
  }

  @override
  Future<BudgeteerState> budgeteerMutate(
      String month, int revision, String operation, Json payload) async {
    calls.add({
      'month': month,
      'revision': revision,
      'operation': operation,
      'payload': payload
    });
    if (saveError != null) throw saveError!;
    if (pending != null) return pending!.future;
    final entries = [...state.entries];
    final groups = [...state.groups];
    final labels = [...state.labels];
    final assignments = [...state.entryLabels];
    final id = payload['id'] ?? 'server-${calls.length}';
    if (operation == 'entry_save') {
      entries.removeWhere((row) => row['id'] == id);
      entries.add({
        ...payload,
        'id': id,
        'sort_position': entries.length,
        'source_state': 'manual'
      });
      assignments.removeWhere((row) => row['entry_id'] == id);
      for (final label in payload['label_ids'] as List) {
        assignments.add({'entry_id': id, 'label_id': label});
      }
    } else if (operation == 'entry_delete') {
      entries.removeWhere((row) => row['id'] == id);
    } else if (operation == 'group_save') {
      groups.removeWhere((row) => row['id'] == id);
      groups.add({...payload, 'id': id, 'sort_position': groups.length});
    } else if (operation == 'label_save') {
      labels.removeWhere((row) => row['id'] == id);
      labels.add({...payload, 'id': id, 'updated_at': 'canonical-token'});
    } else if (operation == 'label_delete') {
      labels.removeWhere((row) => row['id'] == id);
      assignments.removeWhere((row) => row['label_id'] == id);
    } else if (operation == 'group_delete') {
      groups.removeWhere((row) => row['id'] == id);
      for (var i = 0; i < entries.length; i++) {
        if (entries[i]['group_id'] == id) {
          entries[i] = {...entries[i], 'group_id': null};
        }
      }
    } else if (operation == 'reorder') {
      final ordered = payload['entries'] as List;
      for (var i = 0; i < entries.length; i++) {
        final position =
            ordered.indexWhere((row) => row['id'] == entries[i]['id']);
        entries[i] = {
          ...entries[i],
          'sort_position': position,
          'group_id': ordered[position]['group_id']
        };
      }
      final order = payload['groups'] as List;
      for (var i = 0; i < groups.length; i++) {
        groups[i] = {
          ...groups[i],
          'sort_position': order.indexOf(groups[i]['id'])
        };
      }
      groups.sort((a, b) =>
          integer(a['sort_position']).compareTo(integer(b['sort_position'])));
    }
    return state = BudgeteerState(
      plan: {'id': 'plan', 'month': month, 'revision': revision + 1},
      entries: entries,
      groups: groups,
      labels: labels,
      entryLabels: assignments,
    );
  }
}

Json _entry(String id, String name, String kind, int amount,
        {String? group, int position = 0}) =>
    {
      'id': id,
      'name': name,
      'kind': kind,
      'amount_minor': amount,
      'group_id': group,
      'sort_position': position,
      'source_state': 'manual',
    };

BudgeteerState _funded({int deposit = 10000}) => BudgeteerState(
      plan: {'id': 'plan', 'month': '2026-11', 'revision': 4},
      groups: const [
        {
          'id': 'essentials',
          'name': 'Essentials',
          'color_key': 'blue',
          'sort_position': 0
        }
      ],
      entries: [
        if (deposit > 0) _entry('pay', 'Paycheck', 'deposit', deposit),
        _entry('rent', 'Rent', 'withdrawal', 7000, group: 'essentials'),
        _entry('food', 'Groceries', 'withdrawal', 5000,
            group: 'essentials', position: 1),
      ],
      labels: const [
        {
          'id': 'needs',
          'name': 'Needs',
          'color_key': 'teal',
          'updated_at': 'opaque-token'
        }
      ],
      entryLabels: const [
        {'entry_id': 'rent', 'label_id': 'needs'}
      ],
    );

Future<void> _page(WidgetTester tester, _Repository repository,
    {String month = '2026-11', List<Json> transactions = const []}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
        body: ListView(padding: const EdgeInsets.all(16), children: [
      BudgeteerPage(
          repository: repository, month: month, transactions: transactions),
    ])),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'desktop places funding beside editor and source-unavailable entries survive',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _funded();
    final repository = _Repository(
        BudgeteerState(plan: state.plan, groups: state.groups, entries: [
      state.deposits.single,
      {
        ...state.withdrawals.first,
        'source_state': 'unavailable',
        'source_snapshot': {
          'description': 'Old rent source',
          'amount_minor': -7000
        }
      },
      state.withdrawals.last,
    ]));
    await _page(tester, repository);
    expect(tester.getTopLeft(find.text('Withdrawal order')).dx,
        greaterThan(tester.getTopLeft(find.text('Your funding stack')).dx));
    expect(
        find.text('Bank source unavailable. Plan retained.'), findsOneWidget);
    expect(find.textContaining('Old rent source'), findsOneWidget);
    await _tap(tester, find.byTooltip('Delete Rent'));
    expect(repository.calls, isEmpty);
    await _tap(tester, find.text('Cancel'));
    expect(repository.state.withdrawals, hasLength(2));
    await _tap(tester, find.byTooltip('Delete Rent'));
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.single['operation'], 'entry_delete');
    expect(repository.state.withdrawals.single['id'], 'food');
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending save does not optimistically replace canonical totals',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty())
      ..pending = Completer<BudgeteerState>();
    await _page(tester, repository);
    await _tap(tester, find.text('Add deposit'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Pending deposit');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '50');
    await tester.tap(find.text('Save deposit'));
    await tester.pump();
    expect(repository.state.entries, isEmpty);
    expect(find.text('Saved to your plan'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Saving...'))
            .onPressed,
        isNull);
    repository.pending!.complete(BudgeteerState(
      plan: const {'id': 'plan', 'revision': 1},
      entries: [_entry('canonical', 'Canonical server name', 'deposit', 5000)],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Canonical server name'), findsOneWidget);
    expect(find.text('Pending deposit'), findsNothing);
    expect(find.text('Saved to your plan'), findsOneWidget);
  });

  testWidgets(
      'withdrawal edit preserves source and persists group plus multiple labels',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Edit Rent'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Housing');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '75.02');
    await _tap(tester, find.text('Save withdrawal'));
    final payload = repository.calls.single['payload'] as Json;
    expect(payload['id'], 'rent');
    expect(payload['group_id'], 'essentials');
    expect(payload['label_ids'], ['needs']);
    expect(payload.containsKey('source_transaction_id'), isFalse);
    expect(
        repository.state.entries
            .singleWhere((row) => row['id'] == 'rent')['amount_minor'],
        7502);
  });

  testWidgets('create and rename group use server IDs and chosen palette',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository);
    await _tap(tester, find.text('Add group'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Group name'), 'Future');
    await _tap(tester, find.text('violet'));
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.single['payload'],
        {'name': 'Future', 'color_key': 'violet'});
    await _tap(tester, find.byTooltip('Edit group Future'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Group name'), 'Future plans');
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.last['payload']['id'], 'server-1');
    expect(repository.state.groups.single['name'], 'Future plans');
  });

  testWidgets(
      'label creation is reusable without assigning to entries automatically',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.text('Manage labels'));
    await _tap(tester, find.text('New label'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Label name'), 'Flexible');
    await _tap(tester, find.text('amber'));
    await _tap(tester, find.text('Save label'));
    expect(repository.calls.single['operation'], 'label_save');
    expect(repository.calls.single['payload'],
        {'name': 'Flexible', 'color_key': 'amber'});
    expect(repository.state.entryLabels, hasLength(1));
    await _tap(tester, find.text('Close'));
    await _tap(tester, find.byTooltip('Edit Groceries'));
    await _tap(tester, find.text('Flexible'));
    await _tap(tester, find.text('Needs').last);
    await _tap(tester, find.text('Save withdrawal'));
    expect(repository.calls.last['payload']['label_ids'],
        containsAll(['needs', 'server-1']));
  });

  testWidgets('source refresh and unlink are explicit planning-only operations',
      (tester) async {
    final state = _funded();
    final source = <String, dynamic>{
      'id': 'raw',
      'description': 'Bank pay',
      'amount_minor': 10100,
      'status': 'posted',
      'posted_date': '2026-11-01'
    };
    final repository = _Repository(BudgeteerState(
      plan: state.plan,
      groups: state.groups,
      labels: state.labels,
      entries: [
        {
          ...state.deposits.single,
          'source_transaction_id': 'raw',
          'source_snapshot': {...source, 'amount_minor': 10000},
          'source_current': source,
          'source_state': 'changed'
        },
        ...state.withdrawals,
      ],
    ));
    await _page(tester, repository);
    expect(find.text('Bank source changed. Review before refreshing.'),
        findsOneWidget);
    await _tap(tester, find.text('Refresh from source'));
    expect(repository.calls, isEmpty);
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.single['operation'], 'source_refresh');
    expect(repository.calls.single['payload'], {'id': 'pay'});
    await _tap(tester, find.text('Unlink source'));
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.last['operation'], 'source_unlink');
    expect(source['amount_minor'], 10100);
  });

  testWidgets(
      'group reorder moves contiguous block and move-to-group keeps complete lists',
      (tester) async {
    final state = _funded();
    final repository = _Repository(BudgeteerState(
      plan: state.plan,
      entries: [
        ...state.entries,
        _entry('trip', 'Trip', 'withdrawal', 1000, group: 'future')
      ],
      groups: [
        ...state.groups,
        {
          'id': 'future',
          'name': 'Future',
          'color_key': 'rose',
          'sort_position': 1
        }
      ],
    ));
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Move Future group up'));
    expect(
        repository.calls.single['payload']['groups'], ['future', 'essentials']);
    expect(
        (repository.calls.single['payload']['entries'] as List)
            .map((row) => row['id']),
        ['pay', 'trip', 'rent', 'food']);
    await _tap(tester, find.byTooltip('Move Trip to group'));
    await _tap(tester, find.text('Ungrouped').last);
    expect(repository.calls.last['payload']['entries'], [
      {'id': 'pay', 'group_id': null},
      {'id': 'rent', 'group_id': 'essentials'},
      {'id': 'food', 'group_id': 'essentials'},
      {'id': 'trip', 'group_id': null},
    ]);
  });

  testWidgets('empty monthly plan creates nothing and explains zero funding',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository);
    expect(repository.months, ['2026-11']);
    expect(repository.calls, isEmpty);
    expect(
        find.text('No funding yet. Add a deposit to give this plan capacity.'),
        findsOneWidget);
    expect(find.text('Start with a deposit. Nothing is added automatically.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'deficit and funded portions remain exact and segment selects list',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _page(tester, _Repository(_funded()));
    expect(find.text('Funding deficit'), findsOneWidget);
    expect(find.text(r'$30.00 funded / $20.00 unfunded'), findsOneWidget);
    expect(find.text(r'$20.00' '\nunfunded'), findsOneWidget);
    final segment =
        find.bySemanticsLabel(RegExp(r'2\. Groceries, \$30\.00 funded'));
    await _tap(tester, segment);
    final selected = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((widget) => widget.properties.selected == true);
    expect(selected.length, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('positive cents validation and server generated deposit identity',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository);
    await _tap(tester, find.text('Add deposit'));
    await _tap(tester, find.text('Save deposit'));
    expect(find.text('Enter a name.'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Salary');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '0');
    await _tap(tester, find.text('Save deposit'));
    expect(find.text('Enter an amount above zero.'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '1250.51');
    await _tap(tester, find.text('Save deposit'));
    expect(repository.calls.single['operation'], 'entry_save');
    final payload = repository.calls.single['payload'] as Json;
    expect(payload['amount_minor'], 125051);
    expect(payload.containsKey('id'), isFalse);
    expect(payload['label_ids'], isEmpty);
    expect(find.text('Saved to your plan'), findsOneWidget);
    expect(find.text('Salary'), findsOneWidget);
    expect(repository.state.entries.single['id'], 'server-1');
  });

  testWidgets('failed saves retain entered values and retry with same revision',
      (tester) async {
    final repository = _Repository(_funded())
      ..saveError = Exception('private backend detail');
    await _page(tester, repository);
    await _tap(tester, find.text('Add withdrawal'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Emergency reserve');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '20.01');
    await _tap(tester, find.text('Save withdrawal'));
    expect(find.text('Emergency reserve'), findsOneWidget);
    expect(find.text('20.01'), findsOneWidget);
    expect(find.textContaining('private backend detail'), findsNothing);
    expect(find.text('Saved to your plan'), findsNothing);
    expect(repository.state.entries.length, 3);
    repository.saveError = null;
    await _tap(tester, find.text('Save withdrawal'));
    expect(repository.calls.map((call) => call['revision']), [4, 4]);
    expect(repository.state.entries.last['amount_minor'], 2001);
  });

  testWidgets('conflict needs explicit reload and reapply without losing form',
      (tester) async {
    final repository = _Repository(_funded())
      ..saveError = Exception('budgeteer_conflict');
    await _page(tester, repository);
    await _tap(tester, find.text('Add deposit'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Bonus');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '99');
    await _tap(tester, find.text('Save deposit'));
    expect(find.text('Reload, then reapply'), findsOneWidget);
    final disabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save deposit'));
    expect(disabled.onPressed, isNull);
    repository.state = BudgeteerState(
        plan: {'id': 'plan', 'revision': 9},
        entries: repository.state.entries,
        groups: repository.state.groups,
        labels: repository.state.labels);
    repository.saveError = null;
    await _tap(tester, find.text('Reload, then reapply'));
    expect(repository.calls, hasLength(1));
    expect(find.text('Bonus'), findsOneWidget);
    await _tap(tester, find.text('Save deposit'));
    expect(repository.calls.last['revision'], 9);
    expect(repository.state.entries.last['name'], 'Bonus');
  });

  testWidgets('source picker excludes ineligible and already linked rows',
      (tester) async {
    final source = <String, dynamic>{
      'id': 'income',
      'description': 'Posted salary',
      'amount_minor': 12345,
      'status': 'posted',
      'category_kind': 'income'
    };
    final pending = {
      ...source,
      'id': 'pending',
      'description': 'Pending salary',
      'status': 'pending'
    };
    final transfer = {
      ...source,
      'id': 'transfer',
      'description': 'Transfer salary',
      'is_transfer': true
    };
    final expense = {
      ...source,
      'id': 'refund',
      'description': 'Expense refund',
      'category_kind': 'expense'
    };
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository,
        transactions: [source, pending, transfer, expense]);
    await _tap(tester, find.text('Add deposit'));
    await _tap(tester, find.text('Manual planning item'));
    expect(find.textContaining('Pending salary'), findsNothing);
    expect(find.textContaining('Transfer salary'), findsNothing);
    expect(find.textContaining('Expense refund'), findsNothing);
    await _tap(tester, find.textContaining('Posted salary'));
    await _tap(tester, find.text('Save deposit'));
    expect(
        repository.calls.single['payload']['source_transaction_id'], 'income');
    expect(repository.calls.single['payload']['amount_minor'], 12345);
    expect(source['amount_minor'], 12345);
    expect(source['description'], 'Posted salary');
  });

  testWidgets('explicit entry reorder submits complete canonical ordering',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Move Groceries up'));
    expect(repository.calls.single['operation'], 'reorder');
    expect(repository.calls.single['payload']['groups'], ['essentials']);
    expect(repository.calls.single['payload']['entries'], [
      {'id': 'pay', 'group_id': null},
      {'id': 'food', 'group_id': 'essentials'},
      {'id': 'rent', 'group_id': 'essentials'},
    ]);
    expect(repository.state.withdrawals.first['id'], 'food');
    expect(find.text(r'$50.00 funded / $20.00 unfunded'), findsOneWidget);
  });

  testWidgets(
      'group delete retains withdrawals in Ungrouped after confirmation',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Delete group Essentials'));
    expect(repository.calls, isEmpty);
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.single['operation'], 'group_delete');
    expect(repository.state.groups, isEmpty);
    expect(repository.state.withdrawals, hasLength(2));
    expect(repository.state.withdrawals.every((row) => row['group_id'] == null),
        isTrue);
    expect(find.text('Rent'), findsOneWidget);
  });

  testWidgets('labels edit and delete carry exact owner-wide concurrency token',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.text('Manage labels'));
    await _tap(tester, find.byTooltip('Edit label Needs'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Label name'), 'Necessary');
    await _tap(tester, find.text('Save label'));
    expect(repository.calls.single['payload']['expected_updated_at'],
        'opaque-token');
    expect(repository.calls.single['payload']['id'], 'needs');
    await _tap(tester, find.byTooltip('Delete label Necessary'));
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.last['operation'], 'label_delete');
    expect(repository.calls.last['payload']['expected_updated_at'],
        'canonical-token');
    expect(repository.state.entries, hasLength(3));
  });

  testWidgets('read failure is safe and can reload without creating a plan',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty())
      ..readError = Exception('secret error');
    await _page(tester, repository);
    expect(
        find.text('Could not load this plan. Please retry.'), findsOneWidget);
    expect(find.textContaining('secret error'), findsNothing);
    repository.readError = null;
    await _tap(tester, find.text('Reload plan'));
    expect(repository.months, hasLength(2));
    expect(repository.calls, isEmpty);
  });

  testWidgets('month changes reload and clear previous financial subtree',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    expect(find.text('Rent'), findsOneWidget);
    repository.state = const BudgeteerState.empty();
    await _page(tester, repository, month: '2026-12');
    expect(repository.months, ['2026-11', '2026-12']);
    expect(find.text('Rent'), findsNothing);
    expect(find.text('2026-12'), findsOneWidget);
  });

  testWidgets('zero funding, group controls, and dialogs fit a 360px viewport',
      (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _page(tester, _Repository(_funded(deposit: 0)));
    expect(find.text(r'$0.00 funded / $70.00 unfunded'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, find.text('Add withdrawal'));
    expect(tester.takeException(), isNull);
    await _tap(tester, find.text('Cancel'));
    await _tap(tester, find.text('Add group'));
    expect(tester.takeException(), isNull);
  });
}
