import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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
  Object? inclusionError;
  Completer<BudgeteerState>? pendingRead;
  Completer<BudgeteerState>? pendingInclusion;
  List<Json> sources = [];
  final excluded = <String>{};
  final inclusions = <Json>[];
  Completer<BudgeteerState>? pending;
  final calls = <Json>[];
  final months = <String>[];

  @override
  Future<BudgeteerState> budgeteerRead(String month) async {
    months.add(month);
    if (readError != null) throw readError!;
    if (pendingRead != null) return pendingRead!.future;
    return state;
  }

  @override
  Future<BudgeteerState> budgeteerMutate(
      String month, int revision, String operation, Json payload,
      {required int groupsRevision}) async {
    if (operation == 'sources_include') {
      inclusions.add({
        'month': month,
        'revision': revision,
        'groups_revision': groupsRevision
      });
      if (inclusionError != null) throw inclusionError!;
      if (pendingInclusion != null) return pendingInclusion!.future;
      return _include(month);
    }
    calls.add({
      'month': month,
      'revision': revision,
      'groups_revision': groupsRevision,
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
      expect(payload.containsKey('label_ids'), isFalse);
      final existing = entries.where((row) => row['id'] == id).firstOrNull;
      entries.removeWhere((row) => row['id'] == id);
      entries.add({
        ...?existing,
        ...payload,
        'id': id,
        'sort_position': existing?['sort_position'] ?? entries.length,
        'source_state': existing?['source_state'] ?? 'manual'
      });
    } else if (operation == 'entry_delete') {
      final source = entries
          .singleWhere((row) => row['id'] == id)['source_transaction_id'];
      if (source != null) excluded.add('$source');
      entries.removeWhere((row) => row['id'] == id);
    } else if (operation == 'sources_restore') {
      excluded.clear();
      return _include(month);
    } else if (operation == 'group_save') {
      expect(payload.containsKey('parent_group_id'), isTrue);
      expect(payload['kind'], anyOf('withdrawal', 'deposit'));
      final existing = groups.where((row) => row['id'] == id).firstOrNull;
      groups.removeWhere((row) => row['id'] == id);
      groups.add({
        ...?existing,
        ...payload,
        'id': id,
        'sort_position': existing?['sort_position'] ?? groups.length
      });
    } else if (operation == 'legacy_label_convert') {
      expect(payload['confirmed'], isTrue);
      expect(labels.any((row) => row['id'] == payload['label_id']), isTrue);
      final target = payload['group_id'] ?? id;
      if (payload['group_id'] == null) {
        groups.add({
          'id': target,
          'kind': 'withdrawal',
          'name': payload['name'],
          'color_key': payload['color_key'],
          'parent_group_id': payload['parent_group_id'],
          'sort_position': groups.length,
        });
      }
      for (final entryId in payload['entry_ids'] as List) {
        expect(
            assignments.any((link) =>
                link['entry_id'] == entryId &&
                link['label_id'] == payload['label_id']),
            isTrue);
        final index = entries.indexWhere((row) => row['id'] == entryId);
        expect(entries[index]['kind'], 'withdrawal');
        entries[index] = {...entries[index], 'group_id': target};
      }
    } else if (operation == 'group_delete') {
      final parent =
          groups.singleWhere((row) => row['id'] == id)['parent_group_id'];
      groups.removeWhere((row) => row['id'] == id);
      for (var i = 0; i < groups.length; i++) {
        if (groups[i]['parent_group_id'] == id) {
          groups[i] = {...groups[i], 'parent_group_id': parent};
        }
      }
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
      groupsRevision: groupsRevision +
          (['group_save', 'group_delete', 'legacy_label_convert']
                  .contains(operation)
              ? 1
              : 0),
      excludedSourceCount: excluded.length,
    );
  }

  BudgeteerState _include(String month) {
    final entries = [...state.entries];
    for (final source in sources) {
      final kind =
          integer(source['amount_minor']) > 0 ? 'deposit' : 'withdrawal';
      if (!eligibleBudgeteerSource(source, kind) ||
          !'${source['posted_date'] ?? source['transaction_date'] ?? ''}'
              .startsWith('$month-') ||
          excluded.contains(source['id']) ||
          entries.any((row) => row['source_transaction_id'] == source['id'])) {
        continue;
      }
      entries.add({
        ..._entry('entry-${source['id']}', '${source['description']}', kind,
            integer(source['amount_minor']).abs(),
            position: entries.length),
        'source_transaction_id': source['id'],
        'source_current': source,
        'source_snapshot': source,
        'source_state': 'linked',
      });
    }
    return state = BudgeteerState(
        plan: entries.isEmpty
            ? state.plan
            : {
                'id': 'plan',
                'month': month,
                'revision': state.revision +
                    (entries.length == state.entries.length ? 0 : 1),
              },
        entries: entries,
        groups: state.groups,
        labels: state.labels,
        entryLabels: state.entryLabels,
        groupsRevision: state.groupsRevision,
        excludedSourceCount: excluded.length);
  }
}

class _MultiMonthRepository extends _Repository {
  _MultiMonthRepository(this.plans, this.catalog, this.catalogRevision)
      : super(const BudgeteerState.empty());

  final Map<String, BudgeteerState> plans;
  List<Json> catalog;
  int catalogRevision;

  BudgeteerState snapshot(String month) {
    final monthly = plans[month] ?? const BudgeteerState.empty();
    return BudgeteerState(
      plan: monthly.plan,
      entries: monthly.entries,
      groups: [
        for (final group in catalog)
          {
            ...group,
            'sort_position': monthly.groups
                    .where((row) => row['id'] == group['id'])
                    .firstOrNull?['sort_position'] ??
                group['sort_position'],
          },
      ],
      groupsRevision: catalogRevision,
      labels: monthly.labels,
      entryLabels: monthly.entryLabels,
      excludedSourceCount: monthly.excludedSourceCount,
    );
  }

  @override
  Future<BudgeteerState> budgeteerRead(String month) async {
    months.add(month);
    return state = snapshot(month);
  }

  @override
  Future<BudgeteerState> budgeteerMutate(
      String month, int revision, String operation, Json payload,
      {required int groupsRevision}) async {
    state = snapshot(month);
    if (revision != state.revision || groupsRevision != catalogRevision) {
      throw Exception('budgeteer_conflict');
    }
    final result = await super.budgeteerMutate(
        month, revision, operation, payload,
        groupsRevision: groupsRevision);
    if (operation == 'group_save' || operation == 'group_delete') {
      catalog = [
        for (final group in result.groups)
          {
            ...group,
            'sort_position': catalog
                    .where((row) => row['id'] == group['id'])
                    .firstOrNull?['sort_position'] ??
                group['sort_position'],
          },
      ];
      catalogRevision = result.groupsRevision;
    }
    if (operation == 'group_delete') {
      for (final otherMonth in plans.keys.toList()) {
        final other = plans[otherMonth]!;
        plans[otherMonth] = BudgeteerState(
          plan: other.plan,
          entries: [
            for (final entry in other.entries)
              if (entry['group_id'] == payload['id'])
                {...entry, 'group_id': null}
              else
                entry,
          ],
          groups: other.groups,
          labels: other.labels,
          entryLabels: other.entryLabels,
          excludedSourceCount: other.excludedSourceCount,
        );
      }
    }
    plans[month] = result;
    return state = snapshot(month);
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
          'kind': 'withdrawal',
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
    {String month = '2026-11',
    List<Json> transactions = const [],
    bool groupsOnly = false,
    bool settle = true,
    bool openEditor = true}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
        body: Padding(
      padding: const EdgeInsets.all(16),
      child: BudgeteerPage(
          repository: repository,
          month: month,
          transactions: transactions,
          groupsOnly: groupsOnly),
    )),
  ));
  if (!settle) {
    await tester.pump();
    return;
  }
  await tester.pumpAndSettle();
  if (openEditor && !groupsOnly) await _tab(tester, 'Withdrawals');
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
      of: find.byType(SegmentedButton<int>), matching: find.text(label)));
  await tester.pumpAndSettle();
}

Finder _towerPanel() => find.byKey(const ValueKey('tower-of-money-card'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

BudgeteerState _hierarchy() => BudgeteerState(
      plan: const {'id': 'plan', 'month': '2026-11', 'revision': 4},
      groups: [
        for (var i = 0; i < 7; i++)
          {
            'id': 'level-$i',
            'kind': 'withdrawal',
            'name': 'Level $i',
            'color_key': 'blue',
            'parent_group_id': i == 0 ? null : 'level-${i - 1}',
            'sort_position': i,
          },
        {
          'id': 'sibling',
          'kind': 'withdrawal',
          'name': 'Sibling',
          'color_key': 'teal',
          'parent_group_id': 'level-0',
          'sort_position': 7
        },
        {
          'id': 'other',
          'kind': 'withdrawal',
          'name': 'Other root',
          'color_key': 'rose',
          'parent_group_id': null,
          'sort_position': 8
        },
      ].reversed.toList(),
      entries: [
        _entry('pay', 'Paycheck', 'deposit', 2000),
        for (var i = 0; i < 7; i++)
          _entry('bill-$i', 'Depth bill $i', 'withdrawal', 100,
              group: 'level-$i', position: i),
        _entry('other-bill', 'Other bill', 'withdrawal', 100, group: 'other'),
        _entry('loose', 'Loose bill', 'withdrawal', 100),
      ],
    );

void main() {
  for (final width in [1400.0, 360.0]) {
    testWidgets('tab contrast and streamlined controls at ${width}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_funded());
      await _page(tester, repository);
      for (final label in ['Tower of Money', 'Withdrawals', 'Deposits']) {
        await _tab(tester, label);
        final tabs = tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>));
        final style = tabs.style!;
        for (final states in [
          <WidgetState>{},
          {WidgetState.selected}
        ]) {
          final foreground = style.foregroundColor!.resolve(states)!;
          final background = style.backgroundColor!.resolve(states)!;
          expect(foreground, Colors.white);
          expect(
              (foreground.computeLuminance() + .05) /
                  (background.computeLuminance() + .05),
              greaterThanOrEqualTo(4.5));
        }
        expect(style.backgroundColor!.resolve({}),
            isNot(style.backgroundColor!.resolve({WidgetState.selected})));
      }
      final deposit = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Add deposit'));
      await _tab(tester, 'Withdrawals');
      expect(find.text('Withdrawals'), findsOneWidget);
      expect(find.text('Withdrawal order'), findsNothing);
      expect(find.text('Add group'), findsNothing);
      expect(find.textContaining('Named groups fund in priority order'),
          findsNothing);
      expect(
          find.text(
              'Groups are shared across all months. Funding priority and transactions are monthly.'),
          findsOneWidget);
      final withdrawal = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Add withdrawal'));
      expect(withdrawal.style, deposit.style);
      expect(withdrawal.onPressed, isNotNull);
      expect(
          find.widgetWithText(OutlinedButton, 'Add withdrawal'), findsNothing);
      await _tap(tester, find.text('Add withdrawal'));
      expect(find.text('Save withdrawal'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      await _tab(tester, 'Deposits');
      await _tap(tester, find.text('Add deposit'));
      expect(find.text('Save deposit'), findsOneWidget);
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [1400.0, 360.0]) {
    for (final kind in ['deposit', 'withdrawal']) {
      for (final count in [1, 20]) {
        testWidgets('$kind scrolling ends at content: $count entries at $width',
            (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final repository = _Repository(BudgeteerState(entries: [
            for (var i = 0; i < count; i++)
              _entry('item-$i', 'Item $i', kind, 100),
          ]));
          const footerKey = ValueKey('scroll-limit-footer');
          await tester.pumpWidget(MaterialApp(
              home: Scaffold(
                  body: BudgeteerPage(
                      repository: repository,
                      month: '2026-11',
                      transactions: const [],
                      footer: const SizedBox(key: footerKey, height: 24)))));
          await tester.pumpAndSettle();
          await _tab(tester, kind == 'deposit' ? 'Deposits' : 'Withdrawals');
          final viewport = find.ancestor(
              of: find.byKey(footerKey),
              matching: find.byType(SingleChildScrollView));
          final controller =
              tester.widget<SingleChildScrollView>(viewport).controller!;
          final position = controller.position;
          if (count == 1) expect(position.maxScrollExtent, 0);
          controller.jumpTo(position.maxScrollExtent);
          await tester.pumpAndSettle();
          final footerBottom = tester.getBottomLeft(find.byKey(footerKey)).dy;
          final viewportBottom = tester.getBottomLeft(viewport).dy;
          expect(footerBottom, lessThanOrEqualTo(viewportBottom + .1));
          if (count == 20) expect(footerBottom, closeTo(viewportBottom, .1));
          await tester.drag(viewport, const Offset(0, -1500));
          await tester.pumpAndSettle();
          expect(position.pixels,
              lessThanOrEqualTo(position.maxScrollExtent + .1));
          expect(tester.getBottomLeft(find.byKey(footerKey)).dy,
              closeTo(footerBottom, .1));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final width in [1400.0, 360.0]) {
    testWidgets(
        'group manager edits shared groups without source inclusion at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(BudgeteerState(groups: [
        ..._funded().groups,
        {
          'id': 'salary',
          'kind': 'deposit',
          'name': 'Salary',
          'color_key': 'hex_123456',
          'sort_position': 0
        },
        {
          'id': 'child',
          'kind': 'withdrawal',
          'name': 'Child',
          'parent_group_id': 'essentials',
          'color_key': 'teal',
          'sort_position': 1
        },
      ], entries: _funded().entries));
      await _page(tester, repository, groupsOnly: true);
      expect(repository.inclusions, isEmpty);
      expect(repository.calls, isEmpty);
      expect(repository.state.plan, isNull);
      expect(find.text('Deposit groups'), findsOneWidget);
      expect(find.text('Withdrawal groups'), findsOneWidget);
      expect(find.text('Salary'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Child')).dx,
          greaterThan(tester.getTopLeft(find.text('Essentials')).dx));
      expect(find.text('Paycheck'), findsNothing);
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byTooltip('Move Essentials group up'), findsNothing);
      await _tap(tester, find.byTooltip('Edit deposit group Salary'));
      await tester.enterText(find.byType(TextField).first, 'Income');
      await _tap(tester, find.text('Save deposit group'));
      expect(repository.calls.single['operation'], 'group_save');
      expect((repository.calls.single['payload'] as Json)['kind'], 'deposit');
      expect(find.text('Income'), findsOneWidget);
      await _tap(tester, find.byTooltip('Delete group Essentials'));
      expect(find.textContaining('every month'), findsWidgets);
      await _tap(tester, find.text('Confirm'));
      expect(repository.calls.last['operation'], 'group_delete');
      expect(find.text('Essentials'), findsNothing);
      expect(find.text('Child'), findsOneWidget);
      expect(repository.state.entries.length, _funded().entries.length);
      expect(repository.inclusions, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty group manager creates both kinds and switches to planning',
      (tester) async {
    final repository = _Repository(BudgeteerState.empty());
    await _page(tester, repository, groupsOnly: true);
    expect(find.text('No deposit groups yet.'), findsOneWidget);
    expect(find.text('No withdrawal groups yet.'), findsOneWidget);
    for (final kind in ['deposit', 'withdrawal']) {
      await _tap(tester, find.text('Add $kind group'));
      await tester.enterText(find.byType(TextField).first, 'New $kind');
      await _tap(tester,
          find.text(kind == 'deposit' ? 'Save deposit group' : 'Save group'));
      expect(find.text('New $kind'), findsOneWidget);
      expect((repository.calls.last['payload'] as Json)['kind'], kind);
    }
    expect(repository.inclusions, isEmpty);
    await _page(tester, repository);
    expect(repository.inclusions, hasLength(1));
    expect(find.text('New withdrawal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group manager reloads conflicts without including sources',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository, groupsOnly: true);
    repository.saveError = Exception('budgeteer_conflict');
    await _tap(tester, find.byTooltip('Edit group Essentials'));
    await tester.enterText(find.byType(TextField).first, 'Changed');
    await _tap(tester, find.text('Save group'));
    await _tap(tester, find.text('Cancel'));
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    repository.saveError = null;
    await _tap(tester, find.text('Reload plan to reapply'));
    expect(find.text('Essentials'), findsOneWidget);
    expect(repository.inclusions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1400.0, 360.0]) {
    testWidgets('withdrawal groups collapse and compact rows fit at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_funded());
      await _page(tester, repository);
      final rent = find.byKey(const ValueKey('entry-rent'));
      expect(tester.getSize(rent).height, lessThan(width > 640 ? 80 : 160));
      final name = tester.getRect(find.text('Rent'));
      final edit = tester.getRect(find.byTooltip('Edit Rent'));
      if (width > 640) {
        expect(edit.left, greaterThan(name.right));
        expect(edit.top, lessThan(name.bottom));
      } else {
        expect(edit.top, greaterThan(name.bottom));
      }
      await _tap(tester, find.byTooltip('Collapse Essentials group'));
      expect(rent, findsNothing);
      expect(find.byTooltip('Edit Groceries'), findsNothing);
      expect(find.text(r'$120.00 total / $120.00 direct'), findsOneWidget);
      expect(find.byTooltip('Edit group Essentials'), findsOneWidget);
      await _tab(tester, 'Tower of Money');
      await _tab(tester, 'Withdrawals');
      expect(find.byTooltip('Expand Essentials group'), findsOneWidget);
      await _tap(tester, find.byTooltip('Edit group Essentials'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Save group'));
      expect(find.byTooltip('Expand Essentials group'), findsOneWidget);
      expect(rent, findsNothing);
      await _tab(tester, 'Tower of Money');
      await _tap(
          tester, find.byKey(const ValueKey('sankey-label-group:essentials')));
      expect(rent, findsOneWidget);
      expect(find.byTooltip('Collapse Essentials group'), findsOneWidget);
      await _tap(tester, find.byTooltip('Collapse Essentials group'));
      await _page(tester, repository, month: '2026-12');
      expect(rent, findsOneWidget);
      expect(find.byTooltip('Collapse Essentials group'), findsOneWidget);
      expect(repository.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'parents enclose descendants and preserve independent collapse state',
      (tester) async {
    final repository = _Repository(_hierarchy());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Collapse Level 1 group'));
    await _tap(tester, find.byTooltip('Collapse Level 0 group'));
    expect(find.byTooltip('Edit Depth bill 0'), findsNothing);
    expect(find.byTooltip('Edit Depth bill 1'), findsNothing);
    expect(find.byKey(const ValueKey('group-level-1')), findsNothing);
    await _tap(tester, find.byTooltip('Collapse Ungrouped group'));
    expect(find.byTooltip('Edit Loose bill'), findsNothing);
    await _tap(tester, find.byTooltip('Expand Ungrouped group'));
    expect(find.byTooltip('Edit Loose bill'), findsOneWidget);
    expect(find.byTooltip('Expand Level 0 group'), findsOneWidget);
    await _tap(tester, find.byTooltip('Expand Level 0 group'));
    expect(find.byTooltip('Expand Level 1 group'), findsOneWidget);
    expect(find.byTooltip('Edit Depth bill 2'), findsNothing);
    await _tap(tester, find.byTooltip('Expand Level 1 group'));
    expect(find.byTooltip('Edit Depth bill 2'), findsOneWidget);
    await _tap(tester, find.byTooltip('Collapse Sibling group'));
    expect(find.byTooltip('Expand Sibling group'), findsOneWidget);
    await _tap(tester, find.byTooltip('Expand Sibling group'));
    expect(find.byTooltip('Collapse Sibling group'), findsOneWidget);
    expect(repository.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['withdrawal', 'deposit']) {
    for (final hasUngrouped in [false, true]) {
      testWidgets(
          '$kind Ungrouped renders first only when nonempty: $hasUngrouped',
          (tester) async {
        final repository = _Repository(BudgeteerState(
          groups: [
            {'id': 'named', 'kind': kind, 'name': 'Named', 'sort_position': 0},
            {'id': 'empty', 'kind': kind, 'name': 'Empty', 'sort_position': 1},
          ],
          entries: [
            _entry('assigned', 'Assigned entry', kind, 100, group: 'named'),
            if (hasUngrouped) _entry('loose', 'Loose entry', kind, 50),
          ],
        ));
        final allocation = repository.state.allocation;
        await _page(tester, repository);
        if (kind == 'deposit') await _tab(tester, 'Deposits');
        final ungrouped = kind == 'deposit'
            ? find.byKey(const ValueKey('deposit-pool-group-ungrouped'))
            : find.byTooltip('Collapse Ungrouped group');
        final named = kind == 'deposit'
            ? find.byKey(const ValueKey('deposit-pool-group-named'))
            : find.byKey(const ValueKey('group-named'));
        final empty = kind == 'deposit'
            ? find.byKey(const ValueKey('deposit-pool-group-empty'))
            : find.byKey(const ValueKey('group-empty'));
        expect(named, findsOneWidget);
        expect(empty, findsOneWidget);
        expect(
            tester.getTopLeft(named).dy, lessThan(tester.getTopLeft(empty).dy));
        expect(ungrouped, hasUngrouped ? findsOneWidget : findsNothing);
        if (hasUngrouped) {
          expect(tester.getTopLeft(ungrouped).dy,
              lessThan(tester.getTopLeft(named).dy));
          expect(find.byTooltip('Edit Loose entry'), findsOneWidget);
        }
        expect(
            find.byTooltip(kind == 'deposit'
                ? 'Edit deposit group Empty'
                : 'Edit group Empty'),
            findsOneWidget);
        expect(repository.calls, isEmpty);
        expect(repository.state.allocation.deposits, allocation.deposits);
        expect(repository.state.allocation.withdrawals, allocation.withdrawals);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$kind editor can assign to hidden Ungrouped', (tester) async {
      final repository = _Repository(BudgeteerState(
        groups: [
          {'id': 'named', 'kind': kind, 'name': 'Named'},
        ],
        entries: [
          _entry('assigned', 'Assigned entry', kind, 100, group: 'named'),
        ],
      ));
      final allocation = repository.state.allocation;
      await _page(tester, repository);
      if (kind == 'deposit') await _tab(tester, 'Deposits');
      final ungrouped = kind == 'deposit'
          ? find.byKey(const ValueKey('deposit-pool-group-ungrouped'))
          : find.byTooltip('Collapse Ungrouped group');
      expect(ungrouped, findsNothing);
      await _tap(tester, find.byTooltip('Edit Assigned entry'));
      final group =
          find.widgetWithText(DropdownButtonFormField<String>, 'Group');
      await _tap(tester, group);
      await _tap(tester, find.text('Ungrouped').last);
      await _tap(tester, find.text('Save $kind'));
      expect(repository.calls.single['operation'], 'entry_save');
      expect(repository.calls.single['payload']['group_id'], isNull);
      expect(repository.state.entries.single['group_id'], isNull);
      expect(ungrouped, findsOneWidget);
      final named = kind == 'deposit'
          ? find.byKey(const ValueKey('deposit-pool-group-named'))
          : find.byKey(const ValueKey('group-named'));
      expect(named, findsOneWidget);
      expect(tester.getTopLeft(ungrouped).dy,
          lessThan(tester.getTopLeft(named).dy));
      expect(repository.state.allocation.deposits, allocation.deposits);
      expect(repository.state.allocation.withdrawals, allocation.withdrawals);
      expect(repository.state.allocation.remaining, allocation.remaining);
      expect(repository.state.allocation.deficit, allocation.deficit);
      await _tap(tester, find.byTooltip('Edit Assigned entry'));
      await _tap(tester, group);
      await _tap(tester, find.text('Named').last);
      await _tap(tester, find.text('Save $kind'));
      expect(repository.calls.last['payload']['group_id'], 'named');
      expect(ungrouped, findsNothing);
      expect(named, findsOneWidget);
      expect(repository.state.allocation.deposits, allocation.deposits);
      expect(repository.state.allocation.withdrawals, allocation.withdrawals);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Ungrouped display order does not change withdrawal funding',
      (tester) async {
    final base = _funded();
    final repository = _Repository(BudgeteerState(
      plan: base.plan,
      groups: base.groups,
      entries: [
        ...base.entries,
        _entry('loose', 'Loose bill', 'withdrawal', 1000),
      ],
    ));
    await _page(tester, repository);
    expect(
        tester.getTopLeft(find.byTooltip('Collapse Ungrouped group')).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('group-essentials')))
            .dy));
    final allocation = repository.state.allocation;
    expect(allocation.segments.map((segment) => segment.entry['id']),
        ['rent', 'food', 'loose']);
    expect(
        allocation.segments.map((segment) => segment.funded), [7000, 3000, 0]);
    expect(allocation.segments.map((segment) => segment.unfunded),
        [0, 2000, 1000]);
    expect(allocation.deposits, 10000);
    expect(allocation.withdrawals, 13000);
    expect(allocation.deficit, 3000);
    expect(repository.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact withdrawals wrap long names without hiding actions',
      (tester) async {
    tester.view.physicalSize = const Size(360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const name = 'An unusually long withdrawal name that needs multiple lines';
    final repository = _Repository(BudgeteerState(entries: [
      _entry('long', name, 'withdrawal', 100),
    ]));
    await _page(tester, repository);
    expect(find.text(name), findsOneWidget);
    expect(find.byTooltip('Edit $name'), findsOneWidget);
    expect(find.byTooltip('Move $name to group'), findsOneWidget);
    await _tap(tester, find.byTooltip('Edit $name'));
    expect(find.text('Edit withdrawal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1400.0, 360.0]) {
    testWidgets(
        'deposit groups create assign rename color and delete at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_funded());
      await _page(tester, repository);
      await _tab(tester, 'Deposits');
      await _tap(tester, find.text('Add deposit group'));
      expect(find.text('Create deposit group'), findsOneWidget);
      expect(
          find.widgetWithText(DropdownButtonFormField<String>, 'Parent group'),
          findsNothing);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Group name'), 'Salary');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Custom color (hex)'), '#12AB34');
      await _tap(tester, find.text('Save deposit group'));
      expect(repository.calls.single['operation'], 'group_save');
      expect(repository.calls.single['payload'], {
        'kind': 'deposit',
        'name': 'Salary',
        'color_key': 'hex_12ab34',
        'parent_group_id': null,
      });
      final section = find.byKey(const ValueKey('deposit-pool-group-server-1'));
      expect(section, findsOneWidget);
      expect(find.descendant(of: section, matching: find.text(r'$0.00')),
          findsOneWidget);
      expect(find.byTooltip('Edit deposit group Salary'), findsOneWidget);
      expect(find.byTooltip('Edit group Salary'), findsNothing);
      await _tap(tester, find.byTooltip('Edit Paycheck'));
      final group =
          find.widgetWithText(DropdownButtonFormField<String>, 'Group');
      final options = tester
          .widget<DropdownButton<String>>(find.descendant(
              of: group, matching: find.byType(DropdownButton<String>)))
          .items!;
      expect(options.map((item) => item.value), ['', 'server-1']);
      await _tap(tester, group);
      await _tap(tester, find.text('Salary').last);
      await _tap(tester, find.text('Save deposit'));
      expect(repository.calls.last['payload']['kind'], 'deposit');
      expect(repository.calls.last['payload']['group_id'], 'server-1');
      expect(repository.state.allocation.deposits, 10000);
      expect(find.descendant(of: section, matching: find.text(r'$100.00')),
          findsNWidgets(2));
      await _tab(tester, 'Withdrawals');
      await _tap(tester, find.byTooltip('Edit Rent'));
      final withdrawalOptions = tester
          .widget<DropdownButton<String>>(find.descendant(
              of: group, matching: find.byType(DropdownButton<String>)))
          .items!;
      expect(withdrawalOptions.map((item) => item.value), ['', 'essentials']);
      await _tap(tester, find.text('Cancel'));
      await _tab(tester, 'Tower of Money');
      expect(
          find.byKey(const ValueKey('sankey-bar-deposit:pay')), findsNothing);
      expect(find.byKey(const ValueKey('sankey-bar-group:server-1')),
          findsNothing);
      expect(
          tester
              .widget<Material>(find
                  .byKey(const ValueKey('sankey-bar-deposit-group:server-1')))
              .color,
          const Color(0xff12ab34));
      expect(
          tester
              .widget<Text>(find
                  .byKey(const ValueKey('sankey-label-deposit-group:server-1')))
              .style!
              .color,
          const Color(0xff12ab34));
      await _tab(tester, 'Deposits');
      await _tap(tester, find.byTooltip('Edit deposit group Salary'));
      expect(find.text('Edit deposit group'), findsOneWidget);
      final custom = find.widgetWithText(TextFormField, 'Custom color (hex)');
      expect(tester.widget<TextFormField>(custom).controller!.text, '#12ab34');
      expect(
          find.widgetWithText(DropdownButtonFormField<String>, 'Parent group'),
          findsNothing);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Group name'), 'Salary renamed');
      expect(find.byType(ChoiceChip), findsNothing);
      await tester.enterText(custom, '#993366');
      await _tap(tester, find.text('Save deposit group'));
      expect(repository.calls.last['payload'], {
        'id': 'server-1',
        'kind': 'deposit',
        'name': 'Salary renamed',
        'color_key': 'hex_993366',
        'parent_group_id': null,
      });
      await _tap(tester, find.byTooltip('Delete deposit group Salary renamed'));
      expect(find.text('Delete deposit group?'), findsOneWidget);
      final beforeDelete = repository.calls.length;
      await _tap(tester, find.text('Cancel'));
      expect(repository.calls, hasLength(beforeDelete));
      await _tap(tester, find.byTooltip('Delete deposit group Salary renamed'));
      await _tap(tester, find.text('Confirm'));
      expect(repository.calls.last['operation'], 'group_delete');
      expect(repository.calls.last['payload'], {'id': 'server-1'});
      expect(repository.state.depositGroups, isEmpty);
      expect(repository.state.deposits.single['group_id'], isNull);
      expect(repository.state.allocation.deposits, 10000);
      expect(repository.state.orderedGroups.single['id'], 'essentials');
      expect(find.byTooltip('Edit Paycheck'), findsOneWidget);
      await _tab(tester, 'Tower of Money');
      expect(find.byKey(const ValueKey('sankey-bar-deposit-group:server-1')),
          findsNothing);
      expect(find.byKey(const ValueKey('sankey-bar-deposit-ungrouped')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'deposit aggregate nodes stay flat and empty groups stay editable',
      (tester) async {
    final repository = _Repository(BudgeteerState(
      plan: const {'id': 'plan', 'revision': 1},
      groups: const [
        {
          'id': 'salary',
          'name': 'Salary group',
          'kind': 'deposit',
          'parent_group_id': null,
          'color_key': 'hex_993366'
        },
        {
          'id': 'empty',
          'name': 'Empty group',
          'kind': 'deposit',
          'parent_group_id': null,
          'sort_position': 1
        },
        {
          'id': 'bills',
          'name': 'Bills',
          'kind': 'withdrawal',
          'parent_group_id': null
        },
      ],
      entries: [
        _entry('pay1', 'First pay', 'deposit', 600, group: 'salary'),
        _entry('pay2', 'Second pay', 'deposit', 300,
            group: 'salary', position: 1),
        _entry('loose1', 'Loose one', 'deposit', 50),
        _entry('loose2', 'Loose two', 'deposit', 50, position: 1),
        _entry('bill', 'Bill', 'withdrawal', 1000, group: 'bills'),
      ],
    ));
    await _page(tester, repository, openEditor: false);
    final diagram =
        tester.getRect(find.byKey(const ValueKey('sankey-diagram')));
    Rect bar(String id) =>
        tester.getRect(find.byKey(ValueKey('sankey-bar-$id')));
    final salary = bar('deposit-group:salary');
    final loose = bar('deposit-ungrouped');
    expect(salary.left, closeTo(diagram.left, .01));
    expect(loose.left, closeTo(salary.left, .01));
    expect(loose.top - salary.bottom, closeTo(8, .01));
    expect(salary.height / loose.height, closeTo(9, .001));
    expect(bar('income').left,
        closeTo(diagram.left + (diagram.width - 19) / 2, .01));
    expect(bar('group:bills').right, closeTo(diagram.right, .01));
    expect(find.byKey(const ValueKey('sankey-bar-deposit-group:empty')),
        findsNothing);
    for (final id in ['pay1', 'pay2', 'loose1', 'loose2']) {
      expect(find.byKey(ValueKey('sankey-bar-deposit:$id')), findsNothing);
    }
    expect(
        tester
            .widget<Text>(find.byKey(
                const ValueKey('sankey-percentage-deposit-group:salary')))
            .data,
        '90%');
    expect(
        tester
            .widget<Text>(find
                .byKey(const ValueKey('sankey-percentage-deposit-ungrouped')))
            .data,
        '10%');
    await _tab(tester, 'Deposits');
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('deposit-pool-group-empty')),
            matching: find.text(r'$0.00')),
        findsOneWidget);
    expect(find.byTooltip('Edit deposit group Empty group'), findsOneWidget);
    expect(find.byTooltip('Delete deposit group Empty group'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('deposit-pool-group-ungrouped')),
            matching: find.text(r'$1.00')),
        findsOneWidget);
    await _tap(tester, find.byTooltip('Edit First pay'));
    final group = find.widgetWithText(DropdownButtonFormField<String>, 'Group');
    await _tap(tester, group);
    await _tap(tester, find.text('Ungrouped').last);
    await _tap(tester, find.text('Save deposit'));
    expect(repository.calls.single['payload']['group_id'], isNull);
    expect(repository.state.depositInputs.map((e) => e['amount_minor']),
        [300, 700]);
    expect(repository.state.allocation.deposits, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new deposits join empty groups and reorder preserves both kinds',
      (tester) async {
    final base = _funded();
    final repository = _Repository(BudgeteerState(
      plan: base.plan,
      groups: [
        ...base.groups,
        {
          'id': 'income',
          'name': 'Other income',
          'kind': 'deposit',
          'parent_group_id': null,
          'color_key': 'amber'
        },
      ],
      entries: base.entries,
    ));
    await _page(tester, repository);
    await _tab(tester, 'Deposits');
    await _tap(tester, find.text('Add deposit'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Interest');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '2.50');
    await _tap(
        tester, find.widgetWithText(DropdownButtonFormField<String>, 'Group'));
    await _tap(tester, find.text('Other income').last);
    await _tap(tester, find.text('Save deposit'));
    expect(repository.calls.single['payload']['group_id'], 'income');
    expect(repository.calls.single['payload']['kind'], 'deposit');
    expect(repository.state.deposits.last['id'], 'server-1');
    expect(repository.state.allocation.deposits, 10250);
    await _tab(tester, 'Withdrawals');
    await _tap(tester, find.byTooltip('Move Groceries up'));
    expect(repository.calls.last['operation'], 'reorder');
    expect(
        repository.calls.last['payload']['groups'], ['income', 'essentials']);
    expect(repository.calls.last['payload']['entries'], [
      {'id': 'pay', 'group_id': null},
      {'id': 'server-1', 'group_id': 'income'},
      {'id': 'food', 'group_id': 'essentials'},
      {'id': 'rent', 'group_id': 'essentials'},
    ]);
    expect(repository.state.depositGroups.single['kind'], 'deposit');
    expect(
        repository.state.directDeposits('income').single['name'], 'Interest');
    expect(repository.state.withdrawals.first['id'], 'food');
    expect(tester.takeException(), isNull);
  });

  for (final width in [1400.0, 360.0]) {
    testWidgets(
        'Sankey thin bars external labels gaps and curved anchors at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = BudgeteerState(
        plan: const {'id': 'plan', 'month': '2026-11', 'revision': 1},
        groups: const [
          {
            'id': 'root',
            'kind': 'withdrawal',
            'name': 'Root',
            'color_key': 'blue',
            'sort_position': 0
          },
          {
            'id': 'child',
            'kind': 'withdrawal',
            'name': 'Child',
            'color_key': 'hex_993366',
            'parent_group_id': 'root',
            'sort_position': 0
          },
          {
            'id': 'other',
            'kind': 'withdrawal',
            'name': 'Other',
            'sort_position': 1
          },
        ],
        entries: [
          _entry('pay1', 'First paycheck', 'deposit', 600),
          _entry('pay2', 'Second paycheck', 'deposit', 400, position: 1),
          _entry('direct', 'Direct bill', 'withdrawal', 200, group: 'root'),
          _entry('childbill', 'Child bill', 'withdrawal', 400, group: 'child'),
          _entry('otherbill', 'Other bill', 'withdrawal', 200, group: 'other'),
          _entry('loose', 'Loose bill', 'withdrawal', 100),
        ],
      );
      final repository = _Repository(state);
      await _page(tester, repository, openEditor: false);
      Rect bar(String id) =>
          tester.getRect(find.byKey(ValueKey('sankey-bar-$id')));
      for (final id in [
        'deposit-ungrouped',
        'income',
        'group:root',
        'group:child',
        'group:other',
        'direct:root',
        'ungrouped'
      ]) {
        final rect = bar(id);
        expect(rect.width, 19);
        expect(rect.height, greaterThan(0));
        final decoration = tester
            .widget<DecoratedBox>(find
                .descendant(
                    of: find.byKey(ValueKey('sankey-bar-$id')),
                    matching: find.byType(DecoratedBox))
                .last)
            .decoration as BoxDecoration;
        expect(decoration.border, isNull);
        final label = tester.getRect(find.byKey(ValueKey('sankey-label-$id')));
        if (id == 'group:child' || id == 'direct:root') {
          expect(label.right, lessThan(rect.left));
        } else {
          expect(label.left, greaterThan(rect.right));
        }
      }
      for (final entry in {
        'deposit-ungrouped': '100%',
        'income': '100%',
        'group:root': '60%',
        'group:child': '40%',
        'group:other': '20%',
        'direct:root': '20%',
        'ungrouped': '10%',
      }.entries) {
        final percentage =
            find.byKey(ValueKey('sankey-percentage-${entry.key}'));
        expect(tester.widget<Text>(percentage).data, entry.value);
        final name =
            tester.getRect(find.byKey(ValueKey('sankey-label-${entry.key}')));
        expect(
            tester.getRect(percentage).top, greaterThanOrEqualTo(name.bottom));
      }
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('sankey-label-income')))
              .data,
          'Income');
      expect(
          find.byKey(const ValueKey('sankey-bar-deposit:pay1')), findsNothing);
      expect(
          find.byKey(const ValueKey('sankey-bar-deposit:pay2')), findsNothing);
      expect(
          bar('deposit-ungrouped').height, closeTo(bar('income').height, .01));
      expect(
          bar('group:other').top - bar('group:root').bottom, closeTo(8, .01));
      expect(bar('ungrouped').top - bar('group:other').bottom, closeTo(8, .01));
      expect(
          bar('group:child').top - bar('direct:root').bottom, closeTo(8, .01));
      expect(bar('group:root').height / bar('group:other').height,
          closeTo(3, .001));
      expect(bar('income').height / bar('group:root').height,
          closeTo(1000 / 600, .001));
      final paint = tester
          .widget<CustomPaint>(find.byKey(const ValueKey('sankey-diagram')));
      expect(
          bar('deposit-ungrouped').bottom,
          closeTo(
              tester
                  .getRect(find.byKey(const ValueKey('sankey-diagram')))
                  .bottom,
              .01));
      final dynamic painter = paint.painter;
      final links = painter.links as List;
      expect(links, isNotEmpty);
      for (final dynamic link in links) {
        final source = (link.$1 as Offset) +
            tester.getTopLeft(find.byKey(const ValueKey('sankey-diagram')));
        final target = (link.$2 as Offset) +
            tester.getTopLeft(find.byKey(const ValueKey('sankey-diagram')));
        Color endpointColor(Offset point, bool source) {
          final materials = tester.widgetList<Material>(find.byWidgetPredicate(
              (widget) =>
                  widget is Material &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>)
                      .value
                      .startsWith('sankey-bar-')));
          for (final material in materials) {
            final rect = tester.getRect(find.byKey(material.key!));
            final x = source ? rect.right : rect.left;
            if ((x - point.dx).abs() < .01 &&
                point.dy >= rect.top - .01 &&
                point.dy < rect.bottom) {
              return material.color!.withValues(alpha: .35);
            }
          }
          throw StateError('No bar at link endpoint');
        }

        expect(link.$4, endpointColor(source, true));
        expect(link.$5, endpointColor(target, false));
      }
      expect(links.any((dynamic link) => link.$4 != link.$5), isTrue);
      expect(
          links.any((dynamic link) =>
              (link.$1 as Offset).dy != (link.$2 as Offset).dy),
          isTrue);
      expect(state.allocation.remaining, 100);
      expect(state.allocation.deficit, 0);
      expect(find.byKey(const ValueKey('sankey-bar-overflow')), findsNothing);
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [1400.0, 360.0]) {
    for (final columnCount in [3, 4, 5]) {
      testWidgets('Sankey fills card with $columnCount columns at $width',
          (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final depth = columnCount - 2;
        final state = BudgeteerState(
          plan: const {'id': 'plan', 'month': '2026-11', 'revision': 1},
          groups: [
            for (var i = 0; i < depth; i++)
              {
                'id': 'level-$i',
                'kind': 'withdrawal',
                'name': 'Level $i',
                'parent_group_id': i == 0 ? null : 'level-${i - 1}',
                'sort_position': i,
              },
          ],
          entries: [
            _entry('pay', 'Paycheck', 'deposit', 1000),
            _entry('bill', 'Bill', 'withdrawal', 1000,
                group: 'level-${depth - 1}'),
          ],
        );
        await _page(tester, _Repository(state), openEditor: false);
        final diagram =
            tester.getRect(find.byKey(const ValueKey('sankey-diagram')));
        final card = tester.getRect(_towerPanel());
        expect(
            find.descendant(
                of: _towerPanel(), matching: find.text('Tower of Money')),
            findsNothing);
        expect(find.text('Funded in order'), findsNothing);
        expect(diagram.height, greaterThan(card.height / 2));
        expect(find.text(r'$10.00 capacity'), findsNothing);
        expect(diagram.top, closeTo(card.top, .01));
        expect(tester.widget(_towerPanel()), isA<Column>());
        final summary = tester.getRect(find
            .ancestor(
                of: find.text('Pooled deposits'),
                matching: find.byType(Container))
            .first);
        expect(diagram.bottom, closeTo(summary.top - 16, .01));
        expect(diagram.left, closeTo(card.left, .01));
        expect(diagram.right, closeTo(card.right, .01));
        final ids = [
          'deposit-ungrouped',
          'income',
          for (var i = 0; i < depth; i++) 'group:level-$i',
        ];
        final step = (diagram.width - 19) / (columnCount - 1);
        for (var i = 0; i < ids.length; i++) {
          final bar =
              tester.getRect(find.byKey(ValueKey('sankey-bar-${ids[i]}')));
          expect(bar.left, closeTo(diagram.left + i * step, .01));
          if (i == ids.length - 1) {
            expect(bar.right, closeTo(diagram.right, .01));
          }
          final label =
              tester.getRect(find.byKey(ValueKey('sankey-label-${ids[i]}')));
          expect(label.left, greaterThanOrEqualTo(diagram.left));
          expect(label.right, lessThanOrEqualTo(diagram.right));
        }
        expect(
            tester
                .getRect(find.byKey(const ValueKey('sankey-bar-income')))
                .bottom,
            closeTo(diagram.bottom, .01));
        expect(
            find.descendant(
                of: find.byKey(const ValueKey('tower-of-money-card')),
                matching: find.byWidgetPredicate((widget) =>
                    widget is SingleChildScrollView &&
                    widget.scrollDirection == Axis.horizontal)),
            findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [1400.0, 360.0]) {
    testWidgets(
        'tiny Sankey sections bottom-align with labels and retain proportions at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = BudgeteerState(
        plan: const {'id': 'plan', 'revision': 1},
        groups: [
          for (var i = 0; i < 30; i++)
            {
              'id': 'tiny-$i',
              'kind': 'withdrawal',
              'name': 'A very long group name for small allocation $i',
              'sort_position': i
            },
        ],
        entries: [
          _entry('pay', 'Funding', 'deposit', 100000),
          for (var i = 0; i < 30; i++)
            _entry('bill-$i', 'Tiny bill $i', 'withdrawal', 1,
                group: 'tiny-$i'),
        ],
      );
      await _page(tester, _Repository(state), openEditor: false);
      Rect node(String id) =>
          tester.getRect(find.byKey(ValueKey('sankey-bar-$id')));
      final income = node('income');
      final first = node('group:tiny-0');
      expect(first.height, greaterThan(0));
      expect(first.height / income.height, closeTo(1 / 100000, .000001));
      final label = tester.widget<Text>(
          find.byKey(const ValueKey('sankey-label-group:tiny-0')));
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      for (var i = 0; i < 30; i++) {
        final labelBlock = tester.getRect(find
            .ancestor(
                of: find.byKey(ValueKey('sankey-label-group:tiny-$i')),
                matching: find.byType(Positioned))
            .first);
        expect(node('group:tiny-$i').height, lessThan(labelBlock.height));
        expect(node('group:tiny-$i').bottom, closeTo(labelBlock.bottom, .001));
      }
      for (var i = 1; i < 30; i++) {
        final before = tester.getRect(
            find.byKey(ValueKey('sankey-percentage-group:tiny-${i - 1}')));
        final after =
            tester.getRect(find.byKey(ValueKey('sankey-label-group:tiny-$i')));
        expect(after.top, greaterThanOrEqualTo(before.bottom));
        expect(node('group:tiny-$i').top - node('group:tiny-${i - 1}').bottom,
            greaterThanOrEqualTo(8));
      }
      expect(state.allocation.remaining, 99970);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [1400.0, 360.0]) {
    for (final deposit in [1000, 0, 1, 1799]) {
      testWidgets(
          'Sankey shows full withdrawals at $width with Income $deposit',
          (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = BudgeteerState(
          groups: const [
            {
              'id': 'root',
              'kind': 'withdrawal',
              'name': 'Root',
              'sort_position': 0
            },
            {
              'id': 'child',
              'kind': 'withdrawal',
              'name': 'Child',
              'parent_group_id': 'root'
            },
            {
              'id': 'last',
              'kind': 'withdrawal',
              'name': 'Last',
              'sort_position': 1
            },
          ],
          entries: [
            if (deposit > 0) _entry('pay', 'Paycheck', 'deposit', deposit),
            _entry('direct', 'Direct bill', 'withdrawal', 600, group: 'root'),
            _entry('childbill', 'Child bill', 'withdrawal', 800,
                group: 'child'),
            _entry('lastbill', 'Last bill', 'withdrawal', 300, group: 'last'),
            _entry('loose', 'Loose bill', 'withdrawal', 100),
          ],
        );
        await _page(tester, _Repository(state), openEditor: false);
        Rect bar(String id) =>
            tester.getRect(find.byKey(ValueKey('sankey-bar-$id')));
        final overflow = bar('overflow');
        const red = Color(0xff7f1d1d);
        expect(
            tester
                .widget<Material>(
                    find.byKey(const ValueKey('sankey-bar-overflow')))
                .color,
            red);
        final scale = overflow.height / (1800 - deposit);
        if (deposit > 0) {
          final income = bar('income');
          expect(overflow.top, closeTo(income.bottom, .001));
          expect(income.height, closeTo(deposit * scale, .001));
          final incomePercentage = tester
              .getRect(find.byKey(const ValueKey('sankey-percentage-income')));
          final overflowLabel = tester
              .getRect(find.byKey(const ValueKey('sankey-label-overflow')));
          expect(overflowLabel.top, greaterThan(incomePercentage.bottom));
        } else {
          expect(find.byKey(const ValueKey('sankey-bar-income')), findsNothing);
        }
        final paintFinder = find.byKey(const ValueKey('sankey-diagram'));
        final origin = tester.getTopLeft(paintFinder);
        final bounds = tester.getRect(paintFinder);
        var tallest = bounds.top;
        for (final rect in [
          for (final id in [
            if (deposit > 0) 'deposit-ungrouped',
            if (deposit > 0) 'income',
            'overflow',
            'group:root',
            'group:child',
            'direct:root',
            'group:last',
            'ungrouped',
          ]) ...[
            bar(id),
            tester.getRect(find
                .ancestor(
                    of: find.byKey(ValueKey('sankey-label-$id')),
                    matching: find.byType(Positioned))
                .first),
          ],
        ]) {
          if (rect.bottom > tallest) tallest = rect.bottom;
        }
        expect(tallest, closeTo(bounds.bottom, .01));
        for (final id in ['income', 'overflow']) {
          final finder = find.byKey(ValueKey('sankey-bar-$id'));
          if (finder.evaluate().isEmpty) continue;
          final labelBlock = tester.getRect(find
              .ancestor(
                  of: find.byKey(ValueKey('sankey-label-$id')),
                  matching: find.byType(Positioned))
              .first);
          if (bar(id).height < labelBlock.height) {
            expect(bar(id).bottom, closeTo(labelBlock.bottom, .001));
          }
        }
        final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
        final links = painter.links as List;
        for (final entry in {
          'group:root': 1400,
          'group:child': 800,
          'direct:root': 600,
          'group:last': 300,
          'ungrouped': 100,
        }.entries) {
          final rect = bar(entry.key);
          expect(rect.height, closeTo(entry.value * scale, .001));
          final percentage = tester
              .widget<Text>(
                  find.byKey(ValueKey('sankey-percentage-${entry.key}')))
              .data;
          expect(
              percentage,
              deposit == 0
                  ? 'N/A'
                  : '${(entry.value * 100 / deposit).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}%');
          final incoming = links.where((dynamic link) {
            final target = (link.$2 as Offset) + origin;
            return (target.dx - rect.left).abs() < .01 &&
                target.dy >= rect.top - .01 &&
                target.dy < rect.bottom;
          }).fold<double>(0, (sum, dynamic link) => sum + (link.$3 as double));
          expect(incoming, closeTo(rect.height, .001));
        }
        final redLinks = links
            .where((dynamic link) => link.$4 == red.withValues(alpha: .35));
        expect(redLinks, isNotEmpty);
        expect(
            redLinks.fold<double>(
                0, (sum, dynamic link) => sum + (link.$3 as double)),
            closeTo(overflow.height, .001));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Sankey percentages round fractional shares of total Income',
      (tester) async {
    final state = BudgeteerState(entries: [
      _entry('first', 'First deposit', 'deposit', 1),
      _entry('second', 'Second deposit', 'deposit', 2, position: 1),
      _entry('bill', 'Bill', 'withdrawal', 1),
    ]);
    await _page(tester, _Repository(state), openEditor: false);
    for (final entry in {
      'deposit-ungrouped': '100%',
      'income': '100%',
      'ungrouped': '33.3%',
    }.entries) {
      expect(
          tester
              .widget<Text>(
                  find.byKey(ValueKey('sankey-percentage-${entry.key}')))
              .data,
          entry.value);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'empty parent encloses populated children without an empty message',
      (tester) async {
    final repository = _Repository(BudgeteerState(groups: const [
      {'id': 'parent', 'name': 'Parent'},
      {'id': 'child', 'name': 'Child', 'parent_group_id': 'parent'},
      {'id': 'empty', 'name': 'Empty leaf'},
    ], entries: [
      _entry('bill', 'Child bill', 'withdrawal', 100, group: 'child'),
    ]));
    await _page(tester, repository);
    final parent = find.byKey(const ValueKey('group-parent'));
    expect(find.descendant(of: parent, matching: find.text('Child bill')),
        findsOneWidget);
    expect(
        find.descendant(
            of: parent, matching: find.text('No withdrawals here yet.')),
        findsNothing);
    expect(find.text('No withdrawals here yet.'), findsOneWidget);
    expect(find.byTooltip('Collapse Ungrouped group'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1400.0, 360.0]) {
    testWidgets(
        'deep hierarchy nests enclosing cards without overflow at ${width}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_hierarchy());
      await _page(tester, repository);
      final ids = [for (var i = 0; i < 7; i++) 'level-$i', 'sibling', 'other'];
      final positions = [
        for (final id in ids)
          tester.getTopLeft(find.byKey(ValueKey('group-$id'))).dy,
      ];
      expect(positions, orderedEquals([...positions]..sort()));
      for (var i = 1; i < 7; i++) {
        final parent = find.byKey(ValueKey('group-level-${i - 1}'));
        final child = find.byKey(ValueKey('group-level-$i'));
        expect(find.descendant(of: parent, matching: child), findsOneWidget);
        final parentBounds = tester.getRect(parent);
        final childBounds = tester.getRect(child);
        expect(childBounds.left, greaterThan(parentBounds.left));
        expect(childBounds.right, lessThan(parentBounds.right));
        expect(childBounds.top, greaterThan(parentBounds.top));
        expect(childBounds.bottom, lessThan(parentBounds.bottom));
        expect(find.byTooltip('Edit Depth bill $i'), findsOneWidget);
      }
      expect(
          tester.getRect(find.byKey(const ValueKey('group-other'))).top,
          greaterThanOrEqualTo(tester
              .getRect(find.byKey(const ValueKey('group-level-0')))
              .bottom));
      expect(
          find.text(
              'Level 0 / Level 1 / Level 2 / Level 3 / Level 4 / Level 5 / Level 6'),
          findsNothing);
      for (var i = 0; i < 7; i++) {
        expect(find.text('Level $i'), findsOneWidget);
        expect(
            find.descendant(
                of: find.byKey(ValueKey('group-level-$i')),
                matching: find.text(
                    '${money((7 - i) * 100)} total / ${money(100)} direct')),
            findsOneWidget);
        expect(find.byTooltip('Edit group Level $i'), findsOneWidget);
        expect(find.byTooltip('Delete group Level $i'), findsOneWidget);
        expect(find.byTooltip('Move Level $i group up'), findsOneWidget);
        expect(find.byTooltip('Move Level $i group down'), findsOneWidget);
      }
      await _tap(tester, find.byTooltip('Edit group Level 6'));
      expect(
          find.widgetWithText(DropdownButtonFormField<String>, 'Parent group'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Cancel'));
      await _tap(tester, find.byTooltip('Edit Depth bill 6'));
      expect(find.text('Edit withdrawal'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Cancel'));
      expect(repository.calls, isEmpty);
    });

    testWidgets('Tower navigation opens collapsed ancestors at ${width}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_hierarchy());
      await _page(tester, repository);
      await _tap(tester, find.byTooltip('Collapse Level 1 group'));
      await _tap(tester, find.byTooltip('Collapse Level 0 group'));
      await _tab(tester, 'Tower of Money');
      await _tap(
          tester, find.byKey(const ValueKey('sankey-label-group:level-6')));
      expect(find.byTooltip('Collapse Level 0 group'), findsOneWidget);
      expect(find.byTooltip('Collapse Level 1 group'), findsOneWidget);
      expect(find.byTooltip('Edit Depth bill 6'), findsOneWidget);
      expect(tester.getRect(find.byTooltip('Edit Depth bill 6')).top,
          lessThan(1000));
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deposit group cards enclose inset transactions at ${width}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(BudgeteerState(groups: const [
        {'id': 'salary', 'name': 'Salary', 'kind': 'deposit'},
        {'id': 'empty', 'name': 'Empty', 'kind': 'deposit'},
      ], entries: [
        _entry('pay', 'First pay', 'deposit', 100, group: 'salary'),
        _entry('loose', 'Loose pay', 'deposit', 50),
      ]));
      await _page(tester, repository);
      await _tab(tester, 'Deposits');
      for (final entry in [
        ('salary', 'First pay'),
        ('ungrouped', 'Loose pay')
      ]) {
        final group = find.byKey(ValueKey('deposit-pool-group-${entry.$1}'));
        final name = find.text(entry.$2);
        expect(find.descendant(of: group, matching: name), findsOneWidget);
        final bounds = tester.getRect(group);
        final transaction = tester.getRect(name);
        expect(transaction.left, greaterThan(bounds.left + 12));
        expect(transaction.right, lessThan(bounds.right));
        expect(transaction.top, greaterThan(bounds.top));
        expect(transaction.bottom, lessThan(bounds.bottom));
      }
      expect(find.byKey(const ValueKey('deposit-pool-group-empty')),
          findsOneWidget);
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'group arrows move only siblings and carry descendants as a block',
      (tester) async {
    final repository = _Repository(_hierarchy());
    await _page(tester, repository);
    IconButton arrow(String name, String direction) =>
        tester.widget<IconButton>(find.byWidgetPredicate((widget) =>
            widget is IconButton &&
            widget.tooltip == 'Move $name group $direction'));
    expect(arrow('Level 0', 'up').onPressed, isNull);
    expect(arrow('Level 1', 'up').onPressed, isNull);
    expect(arrow('Level 1', 'down').onPressed, isNotNull);
    expect(arrow('Level 2', 'up').onPressed, isNull);
    expect(arrow('Level 2', 'down').onPressed, isNull);
    expect(arrow('Sibling', 'down').onPressed, isNull);
    expect(arrow('Other root', 'down').onPressed, isNull);
    await _tap(tester, find.byTooltip('Move Sibling group up'));
    expect(repository.calls.single['operation'], 'reorder');
    expect(repository.calls.single['payload']['groups'], [
      'level-0',
      'sibling',
      for (var i = 1; i < 7; i++) 'level-$i',
      'other',
    ]);
    expect(
        (repository.calls.single['payload']['entries'] as List)
            .map((e) => e['id']),
        [
          'pay',
          for (var i = 0; i < 7; i++) 'bill-$i',
          'other-bill',
          'loose',
        ]);
    expect(
        repository.state.groups
            .singleWhere((g) => g['id'] == 'level-6')['parent_group_id'],
        'level-5');
  });

  testWidgets(
      'parent editor excludes self and descendants and supports reparenting',
      (tester) async {
    final repository = _Repository(_hierarchy());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Edit group Level 1'));
    final parent =
        find.widgetWithText(DropdownButtonFormField<String>, 'Parent group');
    final items = tester
        .widget<DropdownButton<String>>(find.descendant(
            of: parent, matching: find.byType(DropdownButton<String>)))
        .items!;
    expect(
        items.map((item) => item.value), ['', 'level-0', 'sibling', 'other']);
    await _tap(tester, parent);
    await _tap(tester, find.text('Other root').last);
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.single['operation'], 'group_save');
    expect(repository.calls.single['payload'], {
      'id': 'level-1',
      'kind': 'withdrawal',
      'name': 'Level 1',
      'color_key': 'hex_426c9b',
      'parent_group_id': 'other',
    });
    expect(
        repository.state.groups
            .singleWhere((g) => g['id'] == 'level-2')['parent_group_id'],
        'level-1');
    await _tap(tester, find.byTooltip('Edit group Level 1'));
    await _tap(tester, parent);
    await _tap(tester, find.text('Income (top level)').last);
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.last['payload']['parent_group_id'], isNull);
    expect(repository.calls.last['payload'].containsKey('parent_group_id'),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'global catalog edits persist while entries and order stay monthly',
      (tester) async {
    final base = _funded();
    final catalog = [
      ...base.groups,
      {
        'id': 'future',
        'kind': 'withdrawal',
        'name': 'Future',
        'color_key': 'rose',
        'sort_position': 1,
      },
    ];
    final repository = _MultiMonthRepository({
      '2026-11': BudgeteerState(
          plan: base.plan,
          groups: catalog,
          entries: base.entries,
          labels: base.labels,
          entryLabels: base.entryLabels),
      '2026-12': BudgeteerState(
          plan: const {'id': 'december', 'revision': 2},
          groups: catalog,
          entries: [_entry('gift', 'December gift', 'withdrawal', 300)]),
    }, catalog, 7);
    await _page(tester, repository);
    expect(find.text('Copy earlier groups'), findsNothing);
    expect(
        find.text('Groups are shared across all months. '
            'Funding priority and transactions are monthly.'),
        findsOneWidget);
    expect(repository.inclusions.single['groups_revision'], 7);
    await _tap(tester, find.byTooltip('Move Future group up'));
    expect(repository.calls.single['groups_revision'], 7);
    expect(repository.state.orderedGroups.map((group) => group['id']),
        ['future', 'essentials']);
    expect(repository.state.groupsRevision, 7);
    await _tap(tester, find.byTooltip('Edit group Essentials'));
    expect(
        find.text('This group is shared across all months. '
            'Names, colors, and parent changes apply everywhere.'),
        findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Group name'), 'Shared essentials');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Custom color (hex)'), '#993366');
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.last['groups_revision'], 7);
    expect(repository.state.groupsRevision, 8);
    await _page(tester, repository, month: '2026-12');
    expect(find.byTooltip('Edit group Shared essentials'), findsOneWidget);
    expect(find.byTooltip('Edit December gift'), findsOneWidget);
    expect(find.byTooltip('Edit Rent'), findsNothing);
    expect(repository.state.orderedGroups.map((group) => group['id']),
        ['essentials', 'future']);
    expect(
        repository.state.groups
            .singleWhere((group) => group['id'] == 'essentials')['color_key'],
        'hex_993366');
    expect(repository.state.revision, 2);
    expect(repository.inclusions.last['groups_revision'], 8);
    await _page(tester, repository, month: '2027-01');
    expect(repository.state.plan, isNull);
    expect(repository.state.entries, isEmpty);
    expect(find.byTooltip('Edit group Shared essentials'), findsOneWidget);
    expect(repository.state.groupsRevision, 8);
    await _page(tester, repository);
    expect(find.byTooltip('Edit Rent'), findsOneWidget);
    expect(find.byTooltip('Edit December gift'), findsNothing);
    expect(repository.state.orderedGroups.map((group) => group['id']),
        ['future', 'essentials']);
    expect(repository.state.labels, base.labels);
    expect(repository.state.entryLabels, base.entryLabels);
    await _tap(tester, find.byTooltip('Edit group Future'));
    await _tap(tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Parent group'));
    await _tap(tester, find.text('Shared essentials').last);
    await _tap(tester, find.text('Save group'));
    await _tab(tester, 'Deposits');
    await _tap(tester, find.text('Add deposit group'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Group name'), 'Shared income');
    await _tap(tester, find.text('Save deposit group'));
    final incomeId = repository.state.depositGroups.single['id'];
    await _page(tester, repository, month: '2026-12');
    await _tab(tester, 'Deposits');
    expect(find.byTooltip('Edit deposit group Shared income'), findsOneWidget);
    expect(repository.state.depositGroups.single['id'], incomeId);
    expect(
        repository.state.groups
            .singleWhere((group) => group['id'] == 'future')['parent_group_id'],
        'essentials');
    expect(repository.state.entries.single['name'], 'December gift');
    expect(repository.state.entries.single['group_id'], isNull);
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['withdrawal', 'deposit']) {
    testWidgets(
        'global $kind deletion ungroups every month without deleting entries',
        (tester) async {
      final catalog = [
        {'id': 'root', 'kind': kind, 'name': 'Root', 'sort_position': 0},
        if (kind == 'withdrawal') ...[
          {
            'id': 'parent',
            'kind': kind,
            'name': 'Parent',
            'parent_group_id': 'root',
            'sort_position': 1
          },
          {
            'id': 'child',
            'kind': kind,
            'name': 'Child',
            'parent_group_id': 'parent',
            'sort_position': 2
          },
          {
            'id': 'grandchild',
            'kind': kind,
            'name': 'Grandchild',
            'parent_group_id': 'child',
            'sort_position': 3
          },
        ],
      ];
      final deleted = kind == 'withdrawal' ? 'parent' : 'root';
      final repository = _MultiMonthRepository({
        for (final month in ['2026-11', '2026-12'])
          month: BudgeteerState(
            plan: {'id': month, 'revision': 4},
            groups: catalog,
            entries: [
              _entry('$month-direct', '$month direct', kind, 300,
                  group: deleted),
              if (kind == 'withdrawal')
                _entry('$month-child', '$month child', kind, 200,
                    group: 'child'),
            ],
          ),
      }, catalog, 11);
      await _page(tester, repository);
      if (kind == 'deposit') await _tab(tester, 'Deposits');
      final tooltip = kind == 'deposit'
          ? 'Delete deposit group Root'
          : 'Delete group Parent';
      await _tap(tester, find.byTooltip(tooltip));
      expect(find.textContaining('in every month.'), findsOneWidget);
      if (kind == 'withdrawal') {
        expect(
            find.textContaining('Immediate children move to its former parent'),
            findsOneWidget);
      }
      await _tap(tester, find.text('Cancel'));
      expect(repository.calls, isEmpty);
      expect(repository.snapshot('2026-12').entries.first['group_id'], deleted);
      await _tap(tester, find.byTooltip(tooltip));
      await _tap(tester, find.text('Confirm'));
      expect(repository.calls.single['operation'], 'group_delete');
      expect(repository.calls.single['groups_revision'], 11);
      for (final month in ['2026-11', '2026-12']) {
        await _page(tester, repository, month: month);
        if (kind == 'deposit') await _tab(tester, 'Deposits');
        expect(repository.state.entries.first['group_id'], isNull);
        expect(repository.state.entries.first['amount_minor'], 300);
        expect(find.byTooltip('Edit $month direct'), findsOneWidget);
        expect(repository.state.groups.any((group) => group['id'] == deleted),
            isFalse);
        expect(repository.state.groupsRevision, 12);
        if (kind == 'withdrawal') {
          expect(repository.state.entries, hasLength(2));
          expect(repository.state.entries.last['group_id'], 'child');
          expect(
              repository.state.groups.singleWhere(
                  (group) => group['id'] == 'child')['parent_group_id'],
              'root');
          expect(
              repository.state.groups.singleWhere(
                  (group) => group['id'] == 'grandchild')['parent_group_id'],
              'child');
        } else {
          expect(repository.state.entries, hasLength(1));
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('catalog-only conflict requires reload before reapplying a draft',
      (tester) async {
    final base = _funded();
    final repository = _MultiMonthRepository({'2026-11': base}, base.groups, 7);
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Edit Rent'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'My rent draft');
    repository.catalog = [
      for (final group in repository.catalog)
        {...group, 'name': 'Renamed elsewhere'},
    ];
    repository.catalogRevision = 8;
    await _tap(tester, find.text('Save withdrawal'));
    expect(find.text('Reload, then reapply'), findsOneWidget);
    expect(repository.calls, isEmpty);
    expect(repository.snapshot('2026-11').revision, 4);
    expect(
        repository
            .snapshot('2026-11')
            .entries
            .firstWhere((entry) => entry['id'] == 'rent')['name'],
        'Rent');
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save withdrawal'))
            .onPressed,
        isNull);
    await _tap(tester, find.text('Reload, then reapply'));
    expect(find.text('My rent draft'), findsOneWidget);
    expect(repository.calls, isEmpty);
    await _tap(tester, find.text('Save withdrawal'));
    expect(repository.calls.single['revision'], 4);
    expect(repository.calls.single['groups_revision'], 8);
    expect(repository.calls.single['payload']['group_id'], 'essentials');
    expect(
        repository.state.entries
            .firstWhere((entry) => entry['id'] == 'rent')['name'],
        'My rent draft');
    expect(find.byTooltip('Edit group Renamed elsewhere'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final removeEditedGroup in [true, false]) {
    testWidgets(
        'group conflict reload fails closed when '
        '${removeEditedGroup ? 'edited group is deleted' : 'selected parent is deleted'}',
        (tester) async {
      final repository = _Repository(BudgeteerState(
        plan: const {'id': 'plan', 'revision': 4},
        groupsRevision: 7,
        groups: const [
          {
            'id': 'parent',
            'kind': 'withdrawal',
            'name': 'Parent',
            'parent_group_id': null,
            'color_key': 'blue',
            'sort_position': 0
          },
          {
            'id': 'edited',
            'kind': 'withdrawal',
            'name': 'Edited',
            'parent_group_id': 'parent',
            'color_key': 'teal',
            'sort_position': 1
          },
          {
            'id': 'other',
            'kind': 'withdrawal',
            'name': 'Other',
            'parent_group_id': null,
            'color_key': 'rose',
            'sort_position': 2
          },
        ],
      ))
        ..saveError = Exception('budgeteer_conflict');
      await _page(tester, repository);
      await _tap(tester, find.byTooltip('Edit group Edited'));
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Group name'), 'My edit');
      await _tap(tester, find.text('Save group'));
      expect(repository.calls.single['payload']['parent_group_id'], 'parent');
      expect(repository.calls.single['groups_revision'], 7);
      repository.state = BudgeteerState(
        plan: const {'id': 'plan', 'revision': 4},
        groupsRevision: 8,
        groups: [
          for (final group in repository.state.groups)
            if (group['id'] != (removeEditedGroup ? 'edited' : 'parent'))
              {...group, if (group['id'] == 'edited') 'parent_group_id': null},
        ],
      );
      repository.saveError = null;
      await _tap(tester, find.text('Reload, then reapply'));
      expect(tester.takeException(), isNull);
      expect(find.text('My edit'), findsOneWidget);
      expect(
          find.text('This group or its parent changed elsewhere. '
              'Cancel and reopen the editor to review the current hierarchy.'),
          findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Save group'))
              .onPressed,
          isNull);
      expect(repository.calls, hasLength(1));
      await _tap(tester, find.text('Cancel'));
      expect(find.byType(AlertDialog), findsNothing);
      if (removeEditedGroup) {
        expect(find.byTooltip('Edit group Edited'), findsNothing);
        expect(find.byTooltip('Edit group Other'), findsOneWidget);
      } else {
        await _tap(tester, find.byTooltip('Edit group Edited'));
        expect(find.text('Income (top level)'), findsOneWidget);
        expect(
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Save group'))
                .onPressed,
            isNotNull);
        await _tap(tester, find.text('Cancel'));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'deleted withdrawals retain archived associations without archive controls',
      (tester) async {
    final base = _funded();
    final repository = _Repository(BudgeteerState(
      plan: {...base.plan!, 'owner_id': 'owner'},
      groups: base.groups,
      entries: base.entries,
      labels: base.labels,
      entryLabels: [
        {
          ...base.entryLabels.single,
          'owner_id': 'owner',
          'plan_id': 'plan',
          'entry_snapshot': {
            ...base.withdrawals.first,
            'owner_id': 'owner',
            'plan_id': 'plan',
          },
        },
      ],
    ));
    final links = [...repository.state.entryLabels];
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Delete Rent'));
    await _tap(tester, find.text('Confirm'));
    expect(repository.state.entryLabels, links);
    expect(repository.state.labels, _funded().labels);
    expect(links.single['entry_snapshot']['name'], 'Rent');
    expect(links.single['entry_snapshot']['amount_minor'], 7000);
    expect(find.text('Rent'), findsNothing);
    expect(find.text('Review archived labels'), findsNothing);
    expect(find.byTooltip('Convert archived label Needs'), findsNothing);
    expect(repository.calls.single['operation'], 'entry_delete');
    await _page(tester, repository);
    expect(repository.state.withdrawals.single['id'], 'food');
    expect(repository.state.entryLabels, links);
    expect(repository.state.labels, _funded().labels);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'old schema shows deployment guidance without editing incomplete state',
      (tester) async {
    final repository = _Repository(_funded())
      ..readError = const BudgeteerSchemaException();
    await _page(tester, repository);
    expect(
        find.text(
            'Budgeteer requires schema version 4. Ask the administrator to '
            'deploy the global groups database migration, then reload.'),
        findsOneWidget);
    expect(find.text('Add group'), findsNothing);
    expect(find.text('Pooled deposits'), findsNothing);
    expect(repository.inclusions, isEmpty);
    expect(repository.calls, isEmpty);
    repository.readError = null;
    await _tap(tester, find.text('Reload plan'));
    await _tab(tester, 'Tower of Money');
    expect(find.text('Pooled deposits'), findsOneWidget);
  });

  testWidgets('mounted arrivals include all accounts and preserve removals',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty())
      ..sources = [
        {
          'id': 'salary',
          'account_id': 'checking',
          'description': 'Salary',
          'amount_minor': 20000,
          'status': 'posted',
          'posted_date': '2026-11-01'
        },
        {
          'id': 'interest',
          'account_id': 'savings',
          'description': 'Interest',
          'amount_minor': 100,
          'status': 'posted',
          'transaction_date': '2026-11-02'
        },
        {
          'id': 'bill',
          'account_id': 'card',
          'description': 'Utility bill',
          'amount_minor': -5000,
          'status': 'posted',
          'posted_date': '2026-11-03'
        },
        {
          'id': 'old',
          'description': 'Previous month',
          'amount_minor': 99999,
          'status': 'posted',
          'posted_date': '2026-10-31'
        },
      ];
    await _page(tester, repository, transactions: repository.sources);
    expect(repository.state.deposits, hasLength(2));
    expect(repository.state.withdrawals, hasLength(1));
    expect(repository.state.allocation.deposits, 20100);
    expect(repository.calls, isEmpty);
    await _tab(tester, 'Deposits');
    await _tap(tester, find.byTooltip('Delete Salary'));
    await _tap(tester, find.text('Confirm'));
    await _tab(tester, 'Withdrawals');
    await _tap(tester, find.byTooltip('Delete Utility bill'));
    await _tap(tester, find.text('Confirm'));
    repository.sources.add({
      'id': 'new',
      'account_id': 'savings',
      'description': 'New deposit',
      'amount_minor': 200,
      'status': 'posted',
      'posted_date': '2026-11-04'
    });
    await _page(tester, repository,
        transactions: repository.sources, openEditor: false);
    expect(repository.inclusions, hasLength(2));
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .selected,
        {1});
    expect(repository.state.deposits, hasLength(2));
    expect(repository.state.withdrawals, isEmpty);
    expect(repository.state.allocation.deposits, 300);
    await _tab(tester, 'Deposits');
    expect(find.text('Salary'), findsNothing);
    await _tap(tester, find.text('Restore excluded transactions (2)'));
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.last['operation'], 'sources_restore');
    expect(repository.state.deposits, hasLength(3));
    expect(repository.state.withdrawals, hasLength(1));
    expect(
        find.textContaining('Restore excluded transactions ('), findsNothing);
  });

  testWidgets('mounted source refresh preserves tab collapse and scroll state',
      (tester) async {
    final base = _funded();
    final repository = _Repository(BudgeteerState(
      plan: base.plan,
      groups: base.groups,
      entries: [
        ...base.entries,
        for (var i = 0; i < 20; i++)
          _entry('extra-$i', 'Extra $i', 'withdrawal', 100),
      ],
    ));
    await _page(tester, repository);
    final pageState = tester.state(find.byType(BudgeteerPage));
    await _tap(tester, find.byTooltip('Collapse Essentials group'));
    final scroll = tester.widget<SingleChildScrollView>(find.ancestor(
        of: find.byTooltip('Expand Essentials group'),
        matching: find.byType(SingleChildScrollView)));
    final controller = scroll.controller!;
    controller.jumpTo(80);
    await tester.pumpAndSettle();
    repository.sources = [
      {
        'id': 'arrival',
        'description': 'New withdrawal',
        'amount_minor': -200,
        'status': 'posted',
        'posted_date': '2026-11-04',
      },
    ];
    final inclusion = Completer<BudgeteerState>();
    repository.pendingInclusion = inclusion;
    await _page(tester, repository,
        transactions: repository.sources, openEditor: false, settle: false);
    expect(tester.state(find.byType(BudgeteerPage)), same(pageState));
    expect(controller.hasClients, isTrue);
    expect(controller.offset, 80);
    inclusion.complete(repository._include('2026-11'));
    repository.pendingInclusion = null;
    await tester.pumpAndSettle();
    expect(controller.offset, 80);
    expect(repository.state.withdrawals.last['name'], 'New withdrawal');
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Expand Essentials group'), findsOneWidget);
    expect(find.byTooltip('Edit Rent'), findsNothing);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .selected,
        {1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-ID pending transaction becomes posted without unmounting',
      (tester) async {
    final source = <String, dynamic>{
      'id': 'pending',
      'description': 'Posted withdrawal',
      'amount_minor': -300,
      'status': 'pending',
      'transaction_date': '2026-11-04',
    };
    final repository = _Repository(const BudgeteerState.empty())
      ..sources = [source];
    await _page(tester, repository, transactions: repository.sources);
    expect(repository.state.entries, isEmpty);
    final pageState = tester.state(find.byType(BudgeteerPage));
    source['status'] = 'posted';
    await _page(tester, repository,
        transactions: repository.sources, openEditor: false);
    expect(tester.state(find.byType(BudgeteerPage)), same(pageState));
    expect(repository.inclusions, hasLength(2));
    expect(find.byTooltip('Edit Posted withdrawal'), findsOneWidget);
  });

  for (final change in <String, dynamic>{
    'is_transfer': false,
    'is_card_payment': false,
    'excluded_from_budget': false,
    'category_kind': 'expense',
    'posted_date': '2026-11-04',
    'transaction_date': '2026-11-04',
  }.entries) {
    testWidgets('same-ID ${change.key} change refreshes source eligibility',
        (tester) async {
      final source = <String, dynamic>{
        'id': 'changed',
        'description': 'Newly eligible',
        'amount_minor': -300,
        'status': 'posted',
        'transaction_date': '2026-11-04',
        change.key: change.value is bool
            ? true
            : change.key == 'category_kind'
                ? 'income'
                : '2026-10-31',
      };
      final repository = _Repository(const BudgeteerState.empty())
        ..sources = [source];
      await _page(tester, repository, transactions: repository.sources);
      expect(repository.state.entries, isEmpty);
      source[change.key] = change.value;
      await _page(tester, repository,
          transactions: repository.sources, openEditor: false);
      expect(repository.inclusions, hasLength(2));
      expect(find.byTooltip('Edit Newly eligible'), findsOneWidget);
    });
  }

  testWidgets('unchanged copied reordered transactions do not refresh',
      (tester) async {
    final repository = _Repository(_funded());
    final transactions = <Json>[
      {'id': 'one', 'amount_minor': -100, 'status': 'pending'},
      {'id': 'two', 'amount_minor': 200, 'status': 'pending'},
    ];
    await _page(tester, repository, transactions: transactions);
    await _page(tester, repository, transactions: transactions);
    await _page(tester, repository, transactions: [
      for (final row in transactions.reversed) {...row, 'note': 'Unrelated note'},
    ]);
    expect(repository.months, ['2026-11']);
    expect(repository.inclusions, hasLength(1));
    expect(repository.calls, isEmpty);
  });

  testWidgets('groups-only ignores transaction changes', (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository, groupsOnly: true);
    await _page(tester, repository, groupsOnly: true, transactions: [
      {'id': 'new', 'amount_minor': -100, 'status': 'posted'},
    ]);
    expect(repository.months, ['2026-11']);
    expect(repository.inclusions, isEmpty);
    expect(repository.calls, isEmpty);
  });

  for (final saveEdit in [false, true]) {
    testWidgets(
        'arrival waits for entry dialog ${saveEdit ? 'save' : 'cancel'} after dropdown changes',
        (tester) async {
      final repository = _Repository(_funded());
      await _page(tester, repository);
      await _tap(tester, find.byTooltip('Edit Rent'));
      final inclusion = Completer<BudgeteerState>();
      repository.pendingInclusion = inclusion;
      repository.sources = [
        {
          'id': 'arrival',
          'description': 'Arrived while editing',
          'amount_minor': -200,
          'status': 'posted',
          'posted_date': '2026-11-04',
        },
      ];
      await _page(tester, repository,
          transactions: repository.sources, openEditor: false, settle: false);
      await _tap(tester,
          find.widgetWithText(DropdownButtonFormField<String>, 'Group'));
      await _tap(tester, find.text('Ungrouped').last);
      expect(repository.months, ['2026-11']);
      expect(repository.inclusions, hasLength(1));
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Save withdrawal'))
              .onPressed,
          isNotNull);
      await tester.tap(find.text(saveEdit ? 'Save withdrawal' : 'Cancel'));
      await tester.pump();
      expect(repository.inclusions, hasLength(2));
      expect(repository.inclusions.last['revision'], repository.state.revision);
      if (saveEdit) {
        expect(repository.calls.single['payload']['group_id'], isNull);
      } else {
        expect(repository.calls, isEmpty);
      }
      inclusion.complete(repository._include('2026-11'));
      repository.pendingInclusion = null;
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byTooltip('Edit Arrived while editing'), findsOneWidget);
      await _tap(tester, find.byTooltip('Edit Rent'));
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Save withdrawal'))
              .onPressed,
          isNotNull);
      await _tap(tester, find.text('Save withdrawal'));
      expect(repository.calls, hasLength(saveEdit ? 2 : 1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('nested color dialog defers refresh until group editor closes',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Edit group Essentials'));
    await _tap(tester, find.byTooltip('Choose custom color'));
    await _page(tester, repository, openEditor: false, transactions: [
      {'id': 'arrival', 'amount_minor': -100, 'status': 'posted'},
    ]);
    expect(repository.inclusions, hasLength(1));
    await _tap(tester, find.text('Apply color'));
    expect(repository.inclusions, hasLength(1));
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save group'))
            .onPressed,
        isNotNull);
    await _tap(tester, find.text('Cancel'));
    expect(repository.inclusions, hasLength(2));
    expect(repository.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmation dialog defers refresh until dismissed',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Delete Rent'));
    await _page(tester, repository, openEditor: false, transactions: [
      {'id': 'arrival', 'amount_minor': -100, 'status': 'posted'},
    ]);
    expect(repository.inclusions, hasLength(1));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNotNull);
    await _tap(tester, find.text('Cancel'));
    expect(repository.inclusions, hasLength(2));
    expect(repository.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transaction arrival waits for save and reads saved revisions',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository);
    await _tab(tester, 'Deposits');
    await _tap(tester, find.text('Add deposit'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Saved deposit');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (USD)'), '50');
    final save = Completer<BudgeteerState>();
    repository.pending = save;
    await tester.tap(find.text('Save deposit'));
    await tester.pump();
    repository.sources = [
      {
        'id': 'arrival',
        'description': 'Arrived during save',
        'amount_minor': 200,
        'status': 'posted',
        'posted_date': '2026-11-04',
      },
    ];
    await _page(tester, repository,
        transactions: repository.sources, openEditor: false, settle: false);
    await _page(tester, repository,
        transactions: [...repository.sources],
        openEditor: false,
        settle: false);
    expect(repository.months, ['2026-11']);
    expect(repository.inclusions, hasLength(1));
    repository.state = BudgeteerState(
      plan: const {'id': 'plan', 'revision': 7},
      groupsRevision: 3,
      entries: [_entry('saved', 'Saved deposit', 'deposit', 5000)],
    );
    repository.pending = null;
    save.complete(repository.state);
    await tester.pumpAndSettle();
    expect(repository.months, ['2026-11', '2026-11']);
    expect(repository.inclusions.last['revision'], 7);
    expect(repository.inclusions.last['groups_revision'], 3);
    expect(repository.state.deposits, hasLength(2));
    expect(repository.calls, hasLength(1));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('Edit Saved deposit'), findsOneWidget);
    expect(find.byTooltip('Edit Arrived during save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final conflict in [false, true]) {
    testWidgets(
        'arrival preserves failed-save ${conflict ? 'conflict' : 'retry'} until recovery',
        (tester) async {
      final repository = _Repository(const BudgeteerState.empty());
      await _page(tester, repository);
      await _tab(tester, 'Deposits');
      await _tap(tester, find.text('Add deposit'));
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'Retained edit');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount (USD)'), '50');
      final save = Completer<BudgeteerState>();
      repository.pending = save;
      await tester.tap(find.text('Save deposit'));
      await tester.pump();
      repository.sources = [
        {
          'id': 'arrival',
          'description': 'Arrived during failed save',
          'amount_minor': 200,
          'status': 'posted',
          'posted_date': '2026-11-04',
        },
      ];
      await _page(tester, repository,
          transactions: repository.sources, settle: false);
      repository.pending = null;
      save.completeError(Exception(conflict ? 'budgeteer_conflict' : 'offline'));
      await tester.pumpAndSettle();
      expect(repository.inclusions, hasLength(1));
      expect(repository.months, ['2026-11']);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Retained edit'), findsOneWidget);
      expect(
          find.text(conflict
              ? 'This plan or shared groups changed elsewhere. Reload, review, then reapply your change.'
              : 'Could not save. Your last saved plan is unchanged. Please retry.'),
          findsWidgets);
      if (conflict) {
        await _tap(tester, find.text('Reload, then reapply'));
        expect(repository.inclusions, hasLength(2));
        expect(find.text('Retained edit'), findsOneWidget);
      }
      await _tap(tester, find.text('Save deposit'));
      expect(repository.inclusions, hasLength(2));
      expect(repository.state.deposits, hasLength(2));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byTooltip('Edit Retained edit'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final duringRead in [true, false]) {
    testWidgets(
        'arrivals during ${duringRead ? 'read' : 'inclusion'} queue one follow-up load',
        (tester) async {
      final pending = Completer<BudgeteerState>();
      final repository = _Repository(const BudgeteerState.empty());
      if (duringRead) {
        repository.pendingRead = pending;
      } else {
        repository.pendingInclusion = pending;
      }
      await _page(tester, repository, settle: false);
      for (var i = 0; i < 2; i++) {
        repository.sources.add({
          'id': 'arrival-$i',
          'description': 'Arrived during load $i',
          'amount_minor': -200,
          'status': 'posted',
          'posted_date': '2026-11-04',
        });
        await _page(tester, repository,
            transactions: repository.sources, settle: false);
      }
      expect(repository.months, ['2026-11']);
      expect(repository.inclusions, hasLength(duringRead ? 0 : 1));
      repository.pendingRead = null;
      repository.pendingInclusion = null;
      pending.complete(repository.state);
      await tester.pumpAndSettle();
      expect(repository.months, ['2026-11', '2026-11']);
      expect(repository.inclusions, hasLength(2));
      expect(repository.state.withdrawals, hasLength(2));
      await _tab(tester, 'Withdrawals');
      expect(find.byTooltip('Edit Arrived during load 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('inclusion failure hides incomplete totals and supports reload',
      (tester) async {
    final repository = _Repository(_funded())
      ..inclusionError = Exception('private financial detail');
    await _page(tester, repository);
    expect(
        find.text('Could not load this plan. Please retry.'), findsOneWidget);
    expect(find.text('Pooled deposits'), findsNothing);
    expect(find.text('Add deposit'), findsNothing);
    expect(find.textContaining('private financial detail'), findsNothing);
    repository.inclusionError = null;
    await _tap(tester, find.text('Reload plan'));
    await _tab(tester, 'Tower of Money');
    expect(find.text('Pooled deposits'), findsOneWidget);
    expect(repository.inclusions, hasLength(2));
  });

  testWidgets('mounted refresh failure hides outdated totals until reload',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    repository.inclusionError = Exception('refresh failed');
    await _page(tester, repository, transactions: [
      {'id': 'arrival', 'amount_minor': -100, 'status': 'posted'},
    ]);
    expect(find.text('Could not load this plan. Please retry.'), findsOneWidget);
    expect(find.byTooltip('Edit Rent'), findsNothing);
    expect(find.text('Add withdrawal'), findsNothing);
    repository.inclusionError = null;
    await _tap(tester, find.text('Reload plan'));
    expect(find.byTooltip('Edit Rent'), findsOneWidget);
    expect(repository.inclusions, hasLength(3));
  });

  for (final duringRead in [true, false]) {
    testWidgets(
        'stale ${duringRead ? 'read' : 'inclusion'} cannot apply or refresh the new month',
        (tester) async {
      final pending = Completer<BudgeteerState>();
      final repository = _Repository(_funded());
      if (duringRead) {
        repository.pendingRead = pending;
      } else {
        repository.pendingInclusion = pending;
      }
      await _page(tester, repository, settle: false);
      await _page(tester, repository, settle: false, transactions: [
        {'id': 'arrival', 'amount_minor': -100, 'status': 'posted'},
      ]);
      expect(repository.months, ['2026-11']);
      repository.pendingRead = null;
      repository.pendingInclusion = null;
      repository.state = const BudgeteerState.empty();
      await _page(tester, repository, month: '2026-12');
      pending.complete(_funded());
      await tester.pumpAndSettle();
      expect(repository.months, ['2026-11', '2026-12']);
      expect(repository.inclusions, hasLength(duringRead ? 1 : 2));
      expect(find.text('Paycheck'), findsNothing);
      expect(find.text('Rent'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('inclusion conflict requires reload before editing',
      (tester) async {
    final repository = _Repository(_funded())
      ..inclusionError = Exception('budgeteer_conflict');
    await _page(tester, repository);
    expect(
        find.text(
            'This plan or shared groups changed elsewhere. Reload to include all transactions.'),
        findsOneWidget);
    expect(find.text('Add deposit'), findsNothing);
    repository.inclusionError = null;
    await _tap(tester, find.text('Reload plan to reapply'));
    await _tab(tester, 'Deposits');
    expect(find.text('Add deposit'), findsOneWidget);
    expect(repository.inclusions, hasLength(2));
  });

  testWidgets(
      'desktop Tower fills workspace and source-unavailable entries survive in editor',
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
    await _page(tester, repository, openEditor: false);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .selected,
        {0});
    expect(find.text('Withdrawal order'), findsNothing);
    expect(find.text('Add deposit'), findsNothing);
    expect(find.byTooltip('Edit Paycheck'), findsNothing);
    expect(find.text('Review archived labels'), findsNothing);
    final fundingPanel = _towerPanel();
    final fundingRect = tester.getRect(fundingPanel);
    expect(fundingRect.left, 16);
    expect(fundingRect.right, 1384);
    expect(fundingRect.top,
        tester.getBottomLeft(find.byType(SegmentedButton<int>)).dy + 12);
    expect(fundingRect.bottom, 984);
    final summaryRects = [
      for (final label in ['Pooled deposits', 'Withdrawals', 'Funding deficit'])
        tester.getRect(find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first),
    ];
    for (final rect in summaryRects) {
      expect(fundingRect.contains(rect.topLeft), isTrue);
      expect(rect.right, lessThanOrEqualTo(fundingRect.right));
      expect(rect.bottom, closeTo(fundingRect.bottom, .1));
      expect(rect.top, closeTo(summaryRects.first.top, .1));
    }
    await tester.drag(find.text('Pooled deposits'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getRect(fundingPanel), fundingRect);
    for (var i = 0; i < 2; i++) {
      await _tab(tester, 'Withdrawals');
      expect(find.text('Withdrawal order'), findsNothing);
      expect(find.byTooltip('Edit Paycheck'), findsNothing);
      expect(find.text('Add deposit'), findsNothing);
      expect(find.text('Add withdrawal'), findsOneWidget);
      expect(find.text('Copy earlier groups'), findsNothing);
      expect(find.text('Pooled deposits'), findsNothing);
      await _tab(tester, 'Deposits');
      expect(find.byTooltip('Edit Paycheck'), findsOneWidget);
      expect(find.byTooltip('Edit Rent'), findsNothing);
      expect(find.text('Add deposit'), findsOneWidget);
      expect(find.text('Add withdrawal'), findsNothing);
      await _tab(tester, 'Tower of Money');
      expect(tester.getRect(fundingPanel), fundingRect);
    }
    expect(repository.months, ['2026-11']);
    expect(repository.inclusions, hasLength(1));
    expect(repository.calls, isEmpty);
    await _tab(tester, 'Withdrawals');
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
    await _tab(tester, 'Deposits');
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
    expect(find.byTooltip('Edit Canonical server name'), findsOneWidget);
    expect(find.text('Canonical server name'), findsOneWidget);
    expect(find.text('Pending deposit'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
      'withdrawal edit preserves source and group without changing archived labels',
      (tester) async {
    final base = _funded();
    final repository = _Repository(BudgeteerState(
      plan: base.plan,
      groups: base.groups,
      labels: base.labels,
      entryLabels: base.entryLabels,
      entries: [
        for (final entry in base.entries)
          if (entry['id'] == 'rent')
            {
              ...entry,
              'source_transaction_id': 'rent-source',
              'source_state': 'linked',
              'source_snapshot': {
                'description': 'Original rent',
                'amount_minor': -7000
              },
            }
          else
            entry,
      ],
    ));
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
    expect(payload.containsKey('label_ids'), isFalse);
    expect(repository.state.labels, _funded().labels);
    expect(repository.state.entryLabels, _funded().entryLabels);
    expect(payload.containsKey('source_transaction_id'), isFalse);
    final saved =
        repository.state.entries.singleWhere((row) => row['id'] == 'rent');
    expect(saved['source_transaction_id'], 'rent-source');
    expect(saved['source_snapshot'],
        {'description': 'Original rent', 'amount_minor': -7000});
    expect(saved['source_state'], 'linked');
    expect(
        repository.state.entries
            .singleWhere((row) => row['id'] == 'rent')['amount_minor'],
        7502);
  });

  for (final width in [1400.0, 360.0]) {
    testWidgets('color picker applies cancels and saves at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_funded());
      await _page(tester, repository);
      await _tap(tester, find.byTooltip('Edit group Essentials'));
      final custom = find.widgetWithText(TextFormField, 'Custom color (hex)');
      await tester.enterText(custom, '#336699');
      await _tap(tester, find.byTooltip('Choose custom color'));
      expect(find.text('Choose group color'), findsOneWidget);
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('color-picker-preview')))
              .data,
          '#336699');
      final area = find.byKey(const ValueKey('color-picker-area'));
      final rect = tester.getRect(area);
      await tester
          .tapAt(rect.topLeft + Offset(rect.width * .75, rect.height * .25));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('color-picker-preview')))
              .data,
          isNot('#336699'));
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel').last);
      expect(tester.widget<TextFormField>(custom).controller!.text, '#336699');
      await _tap(tester, find.byTooltip('Choose custom color'));
      final hue = find.byKey(const ValueKey('color-picker-Hue'));
      await tester.ensureVisible(hue);
      await tester.tap(hue);
      await tester.pumpAndSettle();
      final changedHue = tester.widget<Slider>(hue).value;
      expect(changedHue, closeTo(180, 5));
      final colorRect = tester.getRect(area);
      await tester.dragFrom(
          colorRect.topLeft + Offset(colorRect.width * .5, 80),
          Offset(colorRect.width * .3, -40));
      await tester.pumpAndSettle();
      final selected = tester
          .widget<Text>(find.byKey(const ValueKey('color-picker-preview')))
          .data!;
      expect(selected, isNot('#336699'));
      await _tap(tester, find.text('Apply color'));
      expect(tester.widget<TextFormField>(custom).controller!.text, selected);
      expect(repository.calls, isEmpty);
      await _tap(tester, find.text('Save group'));
      expect(repository.calls.single['payload']['color_key'],
          'hex_${selected.substring(1)}');
      expect(tester.takeException(), isNull);
    });

    testWidgets('custom group colors save reopen and render at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_funded());
      await _page(tester, repository);
      await _tap(tester, find.byTooltip('Edit group Essentials'));
      final custom = find.widgetWithText(TextFormField, 'Custom color (hex)');
      expect(find.byType(ChoiceChip), findsNothing);
      expect(tester.widget<TextFormField>(custom).controller!.text, '#426c9b');
      await tester.enterText(custom, '');
      await _tap(tester, find.text('Save group'));
      expect(find.text('Enter six hex digits, e.g. #336699.'), findsOneWidget);
      await tester.enterText(custom, '#bad');
      await _tap(tester, find.text('Save group'));
      expect(find.text('Enter six hex digits, e.g. #336699.'), findsOneWidget);
      expect(repository.calls, isEmpty);
      await tester.enterText(custom, '#12AB34');
      await _tap(tester, find.text('Save group'));
      expect(repository.calls.single['payload']['color_key'], 'hex_12ab34');
      await _tab(tester, 'Tower of Money');
      expect(
          tester
              .widget<Material>(
                  find.byKey(const ValueKey('sankey-bar-group:essentials')))
              .color,
          const Color(0xff12ab34));
      expect(
          tester
              .widget<Text>(
                  find.byKey(const ValueKey('sankey-label-group:essentials')))
              .style!
              .color,
          const Color(0xff12ab34));
      await _tab(tester, 'Withdrawals');
      await _tap(tester, find.byTooltip('Edit group Essentials'));
      expect(tester.widget<TextFormField>(custom).controller!.text, '#12ab34');
      expect(find.byType(ChoiceChip), findsNothing);
      await tester.enterText(custom, '#426c9b');
      await _tap(tester, find.text('Save group'));
      expect(repository.calls.last['payload']['color_key'], 'hex_426c9b');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('create and rename group use server IDs and custom colors',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository, groupsOnly: true);
    await _tap(tester, find.text('Add withdrawal group'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Group name'), 'Future');
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Custom color (hex)'), '#993366');
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.single['payload'], {
      'name': 'Future',
      'kind': 'withdrawal',
      'color_key': 'hex_993366',
      'parent_group_id': null
    });
    await _tap(tester, find.byTooltip('Edit group Future'));
    expect(
        tester
            .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'Custom color (hex)'))
            .controller!
            .text,
        '#993366');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Group name'), 'Future plans');
    await _tap(tester, find.text('Save group'));
    expect(repository.calls.last['payload']['id'], 'server-1');
    expect(repository.state.groups.single['name'], 'Future plans');
  });

  testWidgets('all three tabs omit archive controls and preserve archived data',
      (tester) async {
    final repository = _Repository(_funded());
    await _page(tester, repository);
    final labels = [...repository.state.labels];
    final links = [...repository.state.entryLabels];
    final entries = [...repository.state.entries];
    final groups = [...repository.state.groups];
    final tabs = tester
        .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
        .segments;
    expect(tabs.map((segment) => (segment.label! as Text).data),
        ['Tower of Money', 'Withdrawals', 'Deposits']);
    for (final tab in ['Tower of Money', 'Withdrawals', 'Deposits']) {
      await _tab(tester, tab);
      expect(find.text('Review archived labels'), findsNothing);
      expect(find.text('Archived labels'), findsNothing);
      expect(find.text('Confirm conversion'), findsNothing);
      expect(find.byTooltip('Convert archived label Needs'), findsNothing);
      expect(find.byTooltip('Edit label Needs'), findsNothing);
      expect(find.byTooltip('Delete label Needs'), findsNothing);
      expect(find.text('Needs'), findsNothing);
    }
    expect(repository.calls, isEmpty);
    expect(repository.state.entries, entries);
    expect(repository.state.groups, groups);
    expect(repository.state.labels, labels);
    expect(repository.state.entryLabels, links);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source refresh is explicit and unlink control is absent',
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
    await _tab(tester, 'Deposits');
    expect(find.text('Bank source changed. Review before refreshing.'),
        findsOneWidget);
    await _tap(tester, find.text('Refresh from source'));
    expect(repository.calls, isEmpty);
    await _tap(tester, find.text('Confirm'));
    expect(repository.calls.single['operation'], 'source_refresh');
    expect(repository.calls.single['payload'], {'id': 'pay'});
    expect(find.text('Unlink source'), findsNothing);
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
          'kind': 'withdrawal',
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

  testWidgets('empty monthly plan checks all sources and explains zero funding',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository);
    expect(repository.months, ['2026-11']);
    expect(repository.calls, isEmpty);
    expect(repository.inclusions, [
      {'month': '2026-11', 'revision': 0, 'groups_revision': 0}
    ]);
    expect(
        find.text('No funding yet. Add a deposit to give this plan capacity.'),
        findsNothing);
    expect(find.byTooltip('Collapse Ungrouped group'), findsNothing);
    await _tab(tester, 'Deposits');
    expect(find.byKey(const ValueKey('deposit-pool-group-ungrouped')),
        findsNothing);
    expect(
        find.text('No included deposits this month. Add a planning deposit '
            'or restore excluded transactions.'),
        findsOneWidget);
    await _tab(tester, 'Tower of Money');
    expect(find.text(r'$0.00 capacity'), findsNothing);
    expect(find.text('Pooled deposits'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('sankey-percentage-income')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deficit remains exact and group segment navigates to its list',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _page(tester, _Repository(_funded()));
    expect(find.text(r'$30.00 funded / $20.00 unfunded'), findsOneWidget);
    await _tab(tester, 'Tower of Money');
    expect(find.text('Funding deficit'), findsOneWidget);
    expect(
        tester
            .widget<Text>(find
                .byKey(const ValueKey('sankey-percentage-group:essentials')))
            .data,
        '120%');
    expect(find.text(r'$20.00'), findsOneWidget);
    final segment =
        find.bySemanticsLabel(RegExp(r'Essentials, \$120\.00 planned'));
    expect(
        find.bySemanticsLabel(RegExp(r'Groceries, .* funded')), findsNothing);
    await _tap(tester, segment);
    final selected = tester
        .widgetList<Semantics>(find.byType(Semantics, skipOffstage: false))
        .where((widget) =>
            widget.properties.selected == true &&
            widget.properties.label ==
                r'Essentials, $120.00 planned, 120% of Income');
    expect(selected.length, 1);
    final card = find
        .ancestor(
            of: find.text('Essentials').last, matching: find.byType(Container))
        .first;
    Border border() =>
        (tester.widget<Container>(card).foregroundDecoration! as BoxDecoration)
            .border! as Border;
    expect(border().top.width, 3);
    expect(border().top.color, const Color(0xff426c9b));
    await _tab(tester, 'Tower of Money');
    await _tap(tester, segment);
    expect(tester.widget<Container>(card).foregroundDecoration, isNull);
    expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics, skipOffstage: false))
            .where((widget) =>
                widget.properties.selected == true &&
                widget.properties.label ==
                    r'Essentials, $120.00 planned, 120% of Income'),
        isEmpty);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  for (final width in [1400.0, 360.0]) {
    testWidgets(
        'funding groups jump across tabs and preserve scrolling at ${width}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(BudgeteerState(
        plan: const {'id': 'plan', 'revision': 1},
        groups: const [
          {
            'id': 'first',
            'kind': 'withdrawal',
            'name': 'First group',
            'color_key': 'teal',
            'sort_position': 0
          },
          {
            'id': 'last',
            'kind': 'withdrawal',
            'name': 'Last group',
            'color_key': 'blue',
            'sort_position': 1
          },
        ],
        entries: [
          _entry('pay', 'Paycheck', 'deposit', 1400),
          for (var i = 0; i < 12; i++)
            _entry('bill-$i', 'Bill $i', 'withdrawal', 100,
                group: 'first', position: i),
          _entry('last-bill', 'Final bill', 'withdrawal', 100, group: 'last'),
          _entry('unassigned', 'Unassigned bill', 'withdrawal', 100),
        ],
      ));
      await _page(tester, repository, openEditor: false);
      await _tab(tester, 'Withdrawals');
      final first = find.text('First group', skipOffstage: false).last;
      final last = find.text('Last group', skipOffstage: false).last;
      expect(tester.getTopLeft(last).dy, greaterThan(1000));
      final stackTop = tester.getTopLeft(find.byType(SegmentedButton<int>));
      await _tab(tester, 'Tower of Money');
      await _tap(tester, find.byKey(const ValueKey('sankey-label-group:last')));
      expect(
          tester
              .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
              .selected,
          {1});
      final viewport = find.ancestor(
          of: find.byKey(const ValueKey('group-last')),
          matching: find.byType(SingleChildScrollView));
      final viewportTop = tester.getTopLeft(viewport).dy;
      final lastCard =
          find.ancestor(of: last, matching: find.byType(Container)).first;
      expect(tester.getTopLeft(lastCard).dy, greaterThanOrEqualTo(viewportTop));
      expect(tester.getBottomLeft(lastCard).dy,
          lessThanOrEqualTo(tester.getBottomLeft(viewport).dy + .1));
      expect(tester.getTopLeft(find.byType(SegmentedButton<int>)), stackTop);
      await _tab(tester, 'Tower of Money');
      await _tap(
          tester, find.byKey(const ValueKey('sankey-label-group:first')));
      final firstCard =
          find.ancestor(of: first, matching: find.byType(Container)).first;
      expect(tester.getTopLeft(firstCard).dy, closeTo(viewportTop, .1));
      final beforeManualScroll = tester.getTopLeft(first).dy;
      await tester.dragFrom(Offset(width / 2, 600), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(first).dy, lessThan(beforeManualScroll));
      final afterManualScroll = tester.getTopLeft(first).dy;
      await tester.dragFrom(Offset(width / 2, 400), const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(first).dy, greaterThan(afterManualScroll));
      final beforeDeselect = tester.getTopLeft(firstCard).dy;
      await _tab(tester, 'Tower of Money');
      await _tap(
          tester, find.byKey(const ValueKey('sankey-label-group:first')));
      expect(tester.widget<Container>(firstCard).foregroundDecoration, isNull);
      expect(tester.getTopLeft(firstCard).dy, closeTo(beforeDeselect, .1));
      await _tab(tester, 'Tower of Money');
      await _tap(tester, find.byKey(const ValueKey('sankey-label-ungrouped')));
      final ungroupedCard = find
          .ancestor(
              of: find.byTooltip('Edit Unassigned bill'),
              matching: find.byWidgetPredicate(
                  (widget) => widget is Container && widget.key is GlobalKey))
          .first;
      expect(tester.getTopLeft(ungroupedCard).dy, closeTo(viewportTop, .1));
      expect(repository.months, ['2026-11']);
      expect(repository.inclusions, hasLength(1));
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('positive cents validation and server generated deposit identity',
      (tester) async {
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository);
    await _tab(tester, 'Deposits');
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
    expect(payload.containsKey('label_ids'), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('Edit Salary'), findsOneWidget);
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
    await _tab(tester, 'Deposits');
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
      'posted_date': '2026-11-02',
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
    final old = {
      ...source,
      'id': 'old',
      'description': 'Old salary',
      'posted_date': '2026-10-31'
    };
    final repository = _Repository(const BudgeteerState.empty());
    await _page(tester, repository,
        transactions: [source, pending, transfer, expense, old]);
    await _tab(tester, 'Deposits');
    await _tap(tester, find.text('Add deposit'));
    await _tap(tester, find.text('Manual planning item'));
    expect(find.textContaining('Pending salary'), findsNothing);
    expect(find.textContaining('Transfer salary'), findsNothing);
    expect(find.textContaining('Expense refund'), findsNothing);
    expect(find.textContaining('Old salary'), findsNothing);
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

  testWidgets(
      'entry edits preserve overlapping archives without label conversion',
      (tester) async {
    final base = _funded();
    final repository = _Repository(BudgeteerState(
      plan: base.plan,
      groups: base.groups,
      entries: base.entries,
      labels: [
        ...base.labels,
        {'id': 'shared', 'name': 'Shared', 'color_key': 'rose'}
      ],
      entryLabels: [
        ...base.entryLabels,
        {'entry_id': 'food', 'label_id': 'needs'},
        {'entry_id': 'rent', 'label_id': 'shared'},
        {'entry_id': 'pay', 'label_id': 'needs'},
      ],
    ));
    final labels = [...repository.state.labels];
    final links = [...repository.state.entryLabels];
    await _page(tester, repository);
    await _tap(tester, find.byTooltip('Edit Rent'));
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Housing');
    await _tap(tester, find.text('Save withdrawal'));
    expect(repository.calls.single['operation'], 'entry_save');
    expect(
        repository.calls.single['payload'].containsKey('label_ids'), isFalse);
    expect(repository.state.withdrawals.first['group_id'], 'essentials');
    await _tab(tester, 'Deposits');
    await _tap(tester, find.byTooltip('Edit Paycheck'));
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Income');
    await _tap(tester, find.text('Save deposit'));
    expect(repository.calls.map((call) => call['operation']),
        ['entry_save', 'entry_save']);
    expect(repository.calls.last['payload'].containsKey('label_ids'), isFalse);
    expect(repository.state.groups, base.groups);
    expect(repository.state.labels, labels);
    expect(repository.state.entryLabels, links);
    expect(tester.takeException(), isNull);
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
    await _tab(tester, 'Tower of Money');
    expect(find.text(r'$0.00 capacity'), findsNothing);
    expect(find.text('Pooled deposits'), findsOneWidget);
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
    await _tap(tester, find.byTooltip('Edit group Essentials'));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 900), const Size(360, 600)]) {
    testWidgets('mobile Tower stacks summaries and switches tabs at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository(_hierarchy());
      await _page(tester, repository, openEditor: false);
      expect(find.text('Add withdrawal'), findsNothing);
      expect(find.byTooltip('Edit Paycheck'), findsNothing);
      final tower = tester.getRect(_towerPanel());
      expect(tower.left, 16);
      expect(tower.right, 344);
      final summaries = [
        for (final label in ['Pooled deposits', 'Withdrawals', 'Remaining'])
          tester.getRect(find
              .ancestor(of: find.text(label), matching: find.byType(Container))
              .first),
      ];
      for (final summary in summaries) {
        expect(summary.left, tower.left);
        expect(summary.right, tower.right);
        expect(tower.contains(summary.topLeft), isTrue);
        expect(summary.bottom, lessThanOrEqualTo(tower.bottom));
      }
      expect(summaries[1].top, greaterThan(summaries[0].bottom));
      expect(summaries[2].top, greaterThan(summaries[1].bottom));
      expect(summaries.last.bottom, closeTo(tower.bottom, .1));
      await tester.ensureVisible(find.text('Remaining'));
      await tester.pumpAndSettle();
      expect(
          tester.getRect(find.text('Remaining')).bottom, lessThan(size.height));
      await _tab(tester, 'Withdrawals');
      expect(find.text('Add withdrawal'), findsOneWidget);
      await _tap(tester, find.byTooltip('Edit Depth bill 6'));
      expect(find.text('Edit withdrawal'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      await _tab(tester, 'Deposits');
      expect(find.text('Add deposit'), findsOneWidget);
      expect(find.text('Add withdrawal'), findsNothing);
      expect(find.byTooltip('Edit Paycheck'), findsOneWidget);
      expect(find.byTooltip('Edit Depth bill 6'), findsNothing);
      await _tap(tester, find.byTooltip('Edit Paycheck'));
      expect(find.text('Edit deposit'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      await _tab(tester, 'Tower of Money');
      expect(find.text('Pooled deposits'), findsOneWidget);
      expect(repository.months, ['2026-11']);
      expect(repository.inclusions, hasLength(1));
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
