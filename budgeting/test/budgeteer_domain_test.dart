import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/budgeteer_domain.dart';
import 'package:private_budgeting/domain.dart';

Json entry(String id, int amount,
        {String kind = 'withdrawal', String? group, int position = 0}) =>
    {
      'id': id,
      'name': id,
      'kind': kind,
      'amount_minor': amount,
      'group_id': group,
      'sort_position': position,
    };

Json response({List<Json> entries = const [], List<Json> groups = const []}) =>
    {
      'schema_version': 4,
      'owner_id': 'owner',
      'groups_revision': 7,
      'plan': {
        'id': 'p',
        'owner_id': 'owner',
        'month': '2026-11-01',
        'revision': 2
      },
      'entries': entries,
      'groups': groups,
      'legacy_labels': [],
      'legacy_entry_labels': [],
      'excluded_source_count': 0,
    };

Json group(String id,
        {String kind = 'withdrawal', String? parent, int position = 0}) =>
    {
      'id': id,
      'name': 'Same name is allowed',
      'kind': kind,
      'parent_group_id': parent,
      'sort_position': position,
      'owner_id': 'owner',
    };

void main() {
  test('global catalog and revision are available without a monthly plan', () {
    final fixture = {
      ...response(groups: [
        group('income', kind: 'deposit'),
        group('parent'),
        group('child', parent: 'parent'),
      ]),
      'plan': null,
    };
    final state = BudgeteerState.fromJson(fixture);
    expect(state.plan, isNull);
    expect(state.revision, 0);
    expect(state.groupsRevision, 7);
    expect(state.depositGroups.single['id'], 'income');
    expect(state.orderedGroups.map((g) => g['id']), ['parent', 'child']);
    expect(state.allocation.deposits, 0);
    expect(state.allocation.withdrawals, 0);
    expect(() => state.groups.clear(), throwsUnsupportedError);
    expect(
        () => state.groups.first['name'] = 'changed', throwsUnsupportedError);
    (fixture['groups'] as List<Json>).first['name'] = 'changed input';
    expect(state.groups.first['name'], 'Same name is allowed');
  });

  test('effective monthly positions change funding, not shared group identity',
      () {
    final entries = [
      entry('income', 100, kind: 'deposit'),
      entry('first', 100, group: 'a'),
      entry('second', 100, group: 'b'),
    ];
    final november = BudgeteerState.fromJson(response(
        entries: entries, groups: [group('a'), group('b', position: 1)]));
    final december = BudgeteerState.fromJson({
      ...response(
          entries: entries, groups: [group('a', position: 1), group('b')]),
      'plan': {
        'id': 'next',
        'owner_id': 'owner',
        'month': '2026-12-01',
        'revision': 1,
      },
    });
    expect(november.groups.map((g) => g['id']),
        december.groups.map((g) => g['id']));
    expect(november.groupsRevision, december.groupsRevision);
    expect(november.groupTotals('a').directFunded, 100);
    expect(december.groupTotals('a').directFunded, 0);
    expect(december.groupTotals('b').directFunded, 100);
  });

  test('global owner and integer revision are mandatory even without a plan',
      () {
    for (final value in [null, '', 1]) {
      expect(
          () => BudgeteerState.fromJson(
              {...response(), 'plan': null, 'owner_id': value}),
          throwsFormatException);
    }
    for (final value in [null, -1, 1.5, '1']) {
      expect(
          () => BudgeteerState.fromJson(
              {...response(), 'plan': null, 'groups_revision': value}),
          throwsFormatException);
    }
    expect(
        BudgeteerState.fromJson({...response(), 'groups_revision': 0})
            .groupsRevision,
        0);
    for (final changes in <Json>[
      {'owner_id': 'foreign'},
      {'owner_id': null},
      {'plan_id': 'p'},
      {'sort_position': null},
      {'sort_position': -1},
      {'sort_position': 1.5},
    ]) {
      expect(
          () => BudgeteerState.fromJson({
                ...response(groups: [
                  {...group('g'), ...changes}
                ]),
                'plan': null,
              }),
          throwsFormatException);
    }
    final missingOwner = group('g')..remove('owner_id');
    expect(() => BudgeteerState.fromJson(response(groups: [missingOwner])),
        throwsFormatException);
  });

  test('deposit groups aggregate flat inputs without changing withdrawals', () {
    final state = BudgeteerState.fromJson(response(groups: [
      group('b-income', kind: 'deposit', position: 1),
      {
        ...group('a-income', kind: 'deposit'),
        'name': 'Salary',
        'color_key': 'hex_12ab34'
      },
      group('empty-income', kind: 'deposit', position: 2),
      group('bills'),
      group('child', parent: 'bills'),
    ], entries: [
      entry('second-pay', 200, kind: 'deposit', group: 'a-income', position: 1),
      entry('first-pay', 100, kind: 'deposit', group: 'a-income'),
      entry('interest', 50, kind: 'deposit', group: 'b-income'),
      entry('loose-pay', 25, kind: 'deposit'),
      entry('loose-pay-2', 25, kind: 'deposit', position: 2),
      entry('bill', 250, group: 'child'),
    ]));
    expect(state.childrenOf(null).map((g) => g['id']), ['bills']);
    expect(state.orderedGroups.map((g) => g['id']), ['bills', 'child']);
    expect(state.depositGroups.map((g) => g['id']),
        ['a-income', 'b-income', 'empty-income']);
    expect(state.childrenOf(null, kind: 'deposit'), state.depositGroups);
    expect(state.directDeposits('a-income').map((e) => e['id']),
        ['first-pay', 'second-pay']);
    expect(state.directDeposits(null).map((e) => e['id']),
        ['loose-pay', 'loose-pay-2']);
    expect(state.directDeposits('empty-income'), isEmpty);
    expect(state.depositInputs, [
      {
        'id': 'deposit-group:a-income',
        'name': 'Salary',
        'color_key': 'hex_12ab34',
        'amount_minor': 300
      },
      {
        'id': 'deposit-group:b-income',
        'name': 'Same name is allowed',
        'color_key': 'teal',
        'amount_minor': 50
      },
      {
        'id': 'deposit-ungrouped',
        'name': 'Ungrouped',
        'color_key': 'teal',
        'amount_minor': 50
      },
    ]);
    expect(
        state.allocation.flows
            .where((f) => f.target == 'income')
            .map((f) => '${f.source}:${f.funded}'),
        [
          'deposit-group:a-income:300',
          'deposit-group:b-income:50',
          'deposit-ungrouped:50'
        ]);
    expect(state.allocation.flows.any((f) => f.source.startsWith('deposit:')),
        isFalse);
    expect(state.allocation.deposits, 400);
    expect(state.allocation.remaining, 150);
    expect(state.groupTotals('bills').subtreeFunded, 250);
  });

  test('canonical groups require kind and reject nested or cross-kind deposits',
      () {
    for (final kind in [null, '', 'income', 3]) {
      expect(
          () => BudgeteerState.fromJson(response(groups: [
                {...group('invalid'), 'kind': kind}
              ])),
          throwsFormatException);
    }
    final missingKind = group('missing')..remove('kind');
    expect(() => BudgeteerState.fromJson(response(groups: [missingKind])),
        throwsFormatException);
    for (final groups in <List<Json>>[
      [
        group('parent', kind: 'deposit'),
        group('child', kind: 'deposit', parent: 'parent')
      ],
      [group('parent'), group('child', kind: 'deposit', parent: 'parent')],
      [group('parent', kind: 'deposit'), group('child', parent: 'parent')],
    ]) {
      expect(() => BudgeteerState.fromJson(response(groups: groups)),
          throwsFormatException);
    }
    for (final kind in ['deposit', 'withdrawal']) {
      expect(
          () => BudgeteerState.fromJson(response(groups: [
                group('wrong-kind',
                    kind: kind == 'deposit' ? 'withdrawal' : 'deposit')
              ], entries: [
                entry('entry', 1, kind: kind, group: 'wrong-kind')
              ])),
          throwsFormatException);
    }
  });

  test('hierarchy traverses direct entries then descendants, Ungrouped last',
      () {
    final state = BudgeteerState.fromJson(response(groups: [
      group('z'),
      group('a'),
      group('b', parent: 'a'),
      group('c', parent: 'b'),
      group('d', parent: 'a', position: 1),
      group('empty', parent: 'z'),
    ], entries: [
      entry('income', 101, kind: 'deposit'),
      entry('u', 10),
      entry('z', 10, group: 'z'),
      entry('c', 30, group: 'c'),
      entry('b', 30, group: 'b'),
      entry('d', 30, group: 'd'),
      entry('a2', 10, group: 'a', position: 1),
      entry('a1', 20, group: 'a'),
    ]));
    expect(state.orderedGroups.map((g) => g['id']),
        ['a', 'b', 'c', 'd', 'z', 'empty']);
    expect(state.childrenOf('a').map((g) => g['id']), ['b', 'd']);
    expect(state.descendantIds('a'), {'b', 'c', 'd'});
    expect(state.pathOf('c').map((g) => g['id']), ['a', 'b', 'c']);
    expect(state.depthOf('c'), 2);
    expect(state.depthOf('a'), 0);
    expect(state.withdrawals.map((e) => e['id']),
        ['a1', 'a2', 'b', 'c', 'd', 'z', 'u']);
    final totals = state.groupTotals('a');
    expect(totals.direct, 30);
    expect(totals.directFunded, 30);
    expect(totals.directUnfunded, 0);
    expect(totals.subtree, 120);
    expect(totals.subtreeFunded, 101);
    expect(totals.subtreeUnfunded, 19);
    expect(state.groupTotals('d').directFunded, 11);
    expect(state.groupTotals('z').subtreeFunded, 0);
    expect(state.groupTotals('empty').subtree, 0);
    expect(state.groupTotals(null).directUnfunded, 10);
    expect(state.allocation.withdrawals, 140);
    expect(state.allocation.deficit, 39);
    expect(
        state.allocation.flows
            .map((f) => '${f.source}>${f.target}:${f.funded}'),
        [
          'deposit-ungrouped>income:101',
          'income>group:a:101',
          'group:a>direct:a:30',
          'group:a>group:b:60',
          'group:b>direct:b:30',
          'group:b>group:c:30',
          'group:c>direct:c:30',
          'group:a>group:d:11',
          'group:d>direct:d:11',
        ]);
    expect(() => state.pathOf('missing'), throwsArgumentError);
    expect(() => state.descendantIds('missing'), throwsArgumentError);
  });

  test(
      'hierarchy rejects cycles, orphans, duplicate identities and foreign scope',
      () {
    for (final groups in <List<Json>>[
      [group('a', parent: 'a')],
      [group('a', parent: 'b'), group('b', parent: 'a')],
      [group('a', parent: 'missing')],
      [group('a'), group('a')],
      [
        {...group('a'), 'plan_id': 'foreign'}
      ],
      [
        {...group('a'), 'owner_id': 'one'},
        {...group('b', parent: 'a'), 'owner_id': 'two'}
      ],
      [
        {'id': 'a', 'name': 'No explicit parent'}
      ],
    ]) {
      expect(() => BudgeteerState.fromJson(response(groups: groups)),
          throwsFormatException);
    }
    expect(
        () => BudgeteerState.fromJson({
              ...response(),
              'plan': {
                'id': 'p',
                'month': '2026-11-01',
                'revision': 2,
                'owner_id': 'one'
              },
              'groups': [
                {...group('a'), 'owner_id': 'two'}
              ],
            }),
        throwsFormatException);
    expect(
        () => BudgeteerState.fromJson(response(entries: [
              {...entry('a', 1), 'plan_id': 'foreign'}
            ])),
        throwsFormatException);
    expect(
        () => BudgeteerState.fromJson(response(entries: [
              {...entry('a', 1), 'owner_id': 'foreign'}
            ])),
        throwsFormatException);
  });

  test(
      'zero funding retains navigation and exact unfunded rollups without flows',
      () {
    final state = BudgeteerState.fromJson(response(
        groups: [group('a'), group('b', parent: 'a')],
        entries: [entry('b', 1, group: 'b')]));
    expect(state.orderedGroups.length, 2);
    expect(state.groupTotals('a').subtreeUnfunded, 1);
    expect(state.allocation.flows, isEmpty);
    final funded = BudgeteerState.fromJson(
        response(entries: [entry('d', 3, kind: 'deposit'), entry('u', 2)]));
    expect(funded.allocation.remaining, 1);
    expect(funded.allocation.flows.last.target, 'ungrouped');
    expect(funded.allocation.flows.last.funded, 2);
  });

  test('legacy multi-label data remain distinct and readonly', () {
    final fixture = {
      ...response(entries: [entry('a', 1)]),
      'legacy_labels': [
        {'id': 'l1', 'name': 'One'},
        {'id': 'l2', 'name': 'Two'}
      ],
      'legacy_entry_labels': [
        {'entry_id': 'a', 'label_id': 'l1'},
        {'entry_id': 'a', 'label_id': 'l2'}
      ],
    };
    final state = BudgeteerState.fromJson(fixture);
    expect(state.labels.length, 2);
    expect(state.entryLabels.length, 2);
    expect(state.groups, isEmpty);
    expect(() => state.labels.add({}), throwsUnsupportedError);
    expect(
        () => state.labels.first['name'] = 'changed', throwsUnsupportedError);
    expect(() => state.entryLabels.clear(), throwsUnsupportedError);
    expect(
        () => BudgeteerState.fromJson({
              ...fixture,
              'legacy_entry_labels': [
                {'entry_id': 'a', 'label_id': 'l1'},
                {'entry_id': 'a', 'label_id': 'l1'}
              ]
            }),
        throwsFormatException);
  });

  test('schema v4 is mandatory with actionable update error', () {
    for (final version in [null, 1, 2, 3, 5, '4', 4.0]) {
      expect(
          () => BudgeteerState.fromJson(
              {...response(), 'schema_version': version}),
          throwsA(isA<BudgeteerSchemaException>().having(
              (e) => e.message, 'message', contains('database migration'))));
    }
  });
  test(
      'deleted withdrawals retain validated immutable archived label snapshots',
      () {
    final snapshot = {
      ...entry('deleted', 150, group: 'deleted-group'),
      'owner_id': 'owner',
      'plan_id': 'p',
      'source_snapshot': {
        'description': 'Synthetic',
        'tags': ['original']
      },
    };
    final assignment = {
      'owner_id': 'owner',
      'plan_id': 'p',
      'entry_id': 'deleted',
      'label_id': 'legacy',
      'entry_snapshot': snapshot,
    };
    final fixture = {
      ...response(),
      'plan': {...(response()['plan'] as Json), 'owner_id': 'owner'},
      'legacy_labels': [
        {'id': 'legacy', 'name': 'Archived'}
      ],
      'legacy_entry_labels': [assignment],
    };
    final state = BudgeteerState.fromJson(fixture);
    expect(state.entries, isEmpty);
    expect(state.entryLabels.single['entry_id'], 'deleted');
    expect(state.allocation.withdrawals, 0);
    final archived = state.entryLabels.single['entry_snapshot'] as Json;
    expect(() => archived['amount_minor'] = 200, throwsUnsupportedError);
    expect(
        () => (archived['source_snapshot'] as Json)['description'] = 'Changed',
        throwsUnsupportedError);
    expect(
        () =>
            ((archived['source_snapshot'] as Json)['tags'] as List).add('new'),
        throwsUnsupportedError);
    (snapshot['source_snapshot'] as Json)['description'] = 'Changed input';
    expect((archived['source_snapshot'] as Json)['description'], 'Synthetic');
    for (final invalidSnapshot in <Object?>[
      null,
      'invalid',
      {...snapshot, 'id': 'other'},
      {...snapshot, 'kind': 'deposit'},
      {...snapshot, 'plan_id': 'other'},
      {...snapshot, 'owner_id': 'other'},
      {...snapshot, 'name': ''},
      {...snapshot, 'amount_minor': 0},
      {...snapshot, 'amount_minor': 1.5},
      {...snapshot, 'source_snapshot': 'invalid'},
    ]) {
      expect(
          () => BudgeteerState.fromJson({
                ...fixture,
                'legacy_entry_labels': [
                  {...assignment, 'entry_snapshot': invalidSnapshot}
                ],
              }),
          throwsFormatException);
    }
    for (final changed in <Json>[
      {'plan_id': 'other'},
      {'owner_id': 'other'},
      {'label_id': 'missing'},
    ]) {
      expect(
          () => BudgeteerState.fromJson({
                ...fixture,
                'legacy_entry_labels': [
                  {...assignment, ...changed}
                ],
              }),
          throwsFormatException);
    }
    expect(
        () => BudgeteerState.fromJson({
              ...fixture,
              'entries': [entry('deleted', 100)],
              'legacy_entry_labels': [
                {
                  ...assignment,
                  'entry_snapshot': {...snapshot, 'kind': 'deposit'}
                }
              ],
            }),
        throwsFormatException);
  });
  test('empty state has no money or implicit plan', () {
    const state = BudgeteerState.empty();
    expect(state.plan, isNull);
    expect(state.revision, 0);
    expect(state.groupsRevision, 0);
    expect(state.allocation.remaining, 0);
    expect(state.allocation.deficit, 0);
    expect(state.allocation.segments, isEmpty);
  });

  test('allocation uses cents, ordered groups, then ungrouped', () {
    final state = BudgeteerState.fromJson(response(entries: [
      entry('deposit', 10001, kind: 'deposit'),
      entry('ungrouped', 2000),
      entry('second', 3000, group: 'g2'),
      entry('first-b', 3000, group: 'g1', position: 1),
      entry('first-a', 2000, group: 'g1'),
    ], groups: [
      {
        'id': 'g2',
        'kind': 'withdrawal',
        'name': 'Second',
        'sort_position': 1,
        'owner_id': 'owner',
        'parent_group_id': null
      },
      {
        'id': 'g1',
        'kind': 'withdrawal',
        'name': 'First',
        'sort_position': 0,
        'owner_id': 'owner',
        'parent_group_id': null
      },
    ]));
    expect(state.revision, 2);
    expect(state.groupsRevision, 7);
    expect(state.withdrawals.map((e) => e['id']),
        ['first-a', 'first-b', 'second', 'ungrouped']);
    expect(state.allocation.deposits, 10001);
    expect(state.allocation.withdrawals, 10000);
    expect(state.allocation.remaining, 1);
    expect(state.allocation.deficit, 0);
    expect(state.allocation.segments.map((e) => e.funded),
        [2000, 3000, 3000, 2000]);
  });

  test('over-allocation preserves exact capacity and shows unfunded tail', () {
    final allocation = BudgeteerAllocation.calculate(
        [entry('d', 100, kind: 'deposit')], [entry('a', 80), entry('b', 50)]);
    expect(allocation.remaining, 0);
    expect(allocation.deficit, 30);
    expect(allocation.segments.last.funded, 20);
    expect(allocation.segments.last.unfunded, 30);
    final empty = BudgeteerAllocation.calculate([], [entry('a', 50)]);
    expect(empty.segments.single.funded, 0);
    expect(empty.segments.single.unfunded, 50);
    expect(empty.deficit, 50);
  });

  test('invalid amounts and unsupported aggregate totals are rejected', () {
    for (final amount in [0, -1, budgeteerMaxMinor + 1, 1.5, '1']) {
      expect(
          () => BudgeteerAllocation.calculate([], [
                {...entry('a', 1), 'amount_minor': amount}
              ]),
          throwsFormatException);
    }
    expect(
        () => BudgeteerAllocation.calculate(
            [], [entry('a', budgeteerMaxMinor), entry('b', 1)]),
        throwsFormatException);
  });

  test('source picker respects reporting exclusions, refunds and reversals',
      () {
    final row = {'status': 'posted', 'amount_minor': 120};
    expect(eligibleBudgeteerSource(row, 'deposit'), isTrue);
    expect(eligibleBudgeteerSource(row, 'withdrawal'), isFalse);
    expect(
        eligibleBudgeteerSource({...row, 'amount_minor': -120}, 'withdrawal'),
        isTrue);
    for (final flag in [
      'is_transfer',
      'is_card_payment',
      'excluded_from_budget'
    ]) {
      expect(eligibleBudgeteerSource({...row, flag: true}, 'deposit'), isFalse);
    }
    expect(eligibleBudgeteerSource({...row, 'status': 'pending'}, 'deposit'),
        isFalse);
    expect(
        eligibleBudgeteerSource(
            {...row, 'category_kind': 'expense'}, 'deposit'),
        isFalse);
    expect(
        eligibleBudgeteerSource(
            {...row, 'category_kind': 'income', 'amount_minor': -10},
            'withdrawal'),
        isFalse);
    expect(eligibleBudgeteerSource({...row, 'amount_minor': 0}, 'deposit'),
        isFalse);
  });

  test('source changes compare snapshot, never planning overrides', () {
    final original = {
      'amount_minor': 100,
      'status': 'posted',
      'description': 'Bank'
    };
    final row = {
      'name': 'Independent name',
      'amount_minor': 200,
      'source_snapshot': original,
      'source_current': {...original}
    };
    expect(sourceChanged(row), isFalse);
    expect(
        sourceChanged({
          ...row,
          'source_current': {...original, 'amount_minor': 101}
        }),
        isTrue);
    expect(sourceChanged({'source_state': 'changed'}), isTrue);
    expect(sourceChanged({'source_state': 'unavailable'}), isFalse);
    expect(sourceChanged({}), isFalse);
  });

  test('malformed canonical responses fail closed', () {
    for (final value in <Json>[
      {},
      {...response(), 'entries': null},
      {...response(), 'excluded_source_count': -1},
      {...response(), 'excluded_source_count': '1'},
      {...response(), 'excluded_source_count': null},
      {...response(), 'plan': null, 'excluded_source_count': 1},
      {
        ...response(),
        'groups': [null]
      },
      {
        ...response(),
        'plan': {'id': 'p', 'revision': 0, 'month': '2026-11'}
      },
      response(entries: [entry('a', 1, group: 'foreign')]),
      response(entries: [entry('a', 1), entry('a', 2)]),
      response(entries: [
        {...entry('a', 1), 'source_snapshot': 'bad'}
      ]),
      {
        ...response(),
        'legacy_entry_labels': [
          {'entry_id': 'missing', 'label_id': 'missing'}
        ]
      },
      {
        ...response(entries: [entry('a', 1)]),
        'plan': null
      },
    ]) {
      expect(() => BudgeteerState.fromJson(value), throwsFormatException);
    }
    expect(BudgeteerState.fromJson({...response(), 'plan': null}).revision, 0);
    expect(
        BudgeteerState.fromJson({...response(), 'excluded_source_count': 2})
            .excludedSourceCount,
        2);
  });
}
