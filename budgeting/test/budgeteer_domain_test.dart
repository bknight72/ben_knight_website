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
      'plan': {'id': 'p', 'month': '2026-11-01', 'revision': 2},
      'entries': entries,
      'groups': groups,
      'labels': [],
      'entry_labels': [],
      'excluded_source_count': 0,
    };

void main() {
  test('empty state has no money or implicit plan', () {
    const state = BudgeteerState.empty();
    expect(state.plan, isNull);
    expect(state.revision, 0);
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
      {'id': 'g2', 'name': 'Second', 'sort_position': 1},
      {'id': 'g1', 'name': 'First', 'sort_position': 0},
    ]));
    expect(state.revision, 2);
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
        'entry_labels': [
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
