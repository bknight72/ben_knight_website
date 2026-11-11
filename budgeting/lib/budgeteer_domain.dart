import 'dart:math' as math;
import 'domain.dart';

const budgeteerMaxMinor = 9000000000000;
const budgeteerColors = ['teal', 'blue', 'amber', 'rose', 'violet', 'slate'];

class BudgeteerSchemaException extends FormatException {
  const BudgeteerSchemaException()
      : super('Budgeteer requires schema version 4. Ask the administrator to '
            'deploy the global groups database migration, then reload.');
}

class BudgeteerGroupTotals {
  final int direct;
  final int directFunded;
  final int subtree;
  final int subtreeFunded;
  const BudgeteerGroupTotals(
      this.direct, this.directFunded, this.subtree, this.subtreeFunded);
  int get directUnfunded => direct - directFunded;
  int get subtreeUnfunded => subtree - subtreeFunded;
}

/// Input IDs are `deposit-group:<id>` or `deposit-ungrouped`; withdrawal IDs
/// are `group:<id>`, `direct:<id>`, or `ungrouped`, connected through `income`.
/// Edges carry funded cents only; deficits and remaining income are separate.
class BudgeteerFlow {
  final String source;
  final String target;
  final int funded;
  const BudgeteerFlow(this.source, this.target, this.funded);
}

/// A bank association is a reference, never authority to edit the ledger.
bool eligibleBudgeteerSource(Json row, String kind) {
  final amount = integer(row['amount_minor']);
  if (row['status'] != 'posted' ||
      row['is_transfer'] == true ||
      row['is_card_payment'] == true ||
      row['excluded_from_budget'] == true) {
    return false;
  }
  return kind == 'deposit'
      ? amount > 0 && row['category_kind'] != 'expense'
      : kind == 'withdrawal' && amount < 0 && row['category_kind'] != 'income';
}

bool sourceChanged(Json entry) {
  if (entry['source_state'] == 'changed') return true;
  final original = entry['source_snapshot'];
  final current = entry['source_current'];
  if (original is! Map || current is! Map) return false;
  return [
    'amount_minor',
    'status',
    'transaction_date',
    'posted_date',
    'description'
  ].any((key) => original[key] != current[key]);
}

class BudgeteerSegment {
  final Json entry;
  final int funded;
  final int unfunded;
  const BudgeteerSegment(this.entry, this.funded, this.unfunded);
}

class BudgeteerAllocation {
  final int deposits;
  final int withdrawals;
  final List<BudgeteerSegment> segments;
  final Map<String?, BudgeteerGroupTotals> totals;
  final List<BudgeteerFlow> flows;
  const BudgeteerAllocation(this.deposits, this.withdrawals, this.segments,
      {this.totals = const {}, this.flows = const []});
  int get remaining => math.max(0, deposits - withdrawals);
  int get deficit => math.max(0, withdrawals - deposits);

  factory BudgeteerAllocation.calculate(
      List<Json> deposits, List<Json> withdrawals) {
    int total(List<Json> rows) {
      var sum = 0;
      for (final row in rows) {
        final value = row['amount_minor'];
        if (value is! int || value <= 0 || value > budgeteerMaxMinor) {
          throw const FormatException('Invalid Budgeteer amount.');
        }
        sum += value;
        if (sum > budgeteerMaxMinor) {
          throw const FormatException(
              'Budgeteer total exceeds supported range.');
        }
      }
      return sum;
    }

    final funding = total(deposits);
    final spending = total(withdrawals);
    var available = funding;
    final segments = <BudgeteerSegment>[];
    for (final entry in withdrawals) {
      final amount = entry['amount_minor'] as int;
      final funded = math.min(available, amount);
      segments.add(BudgeteerSegment(entry, funded, amount - funded));
      available -= funded;
    }
    return BudgeteerAllocation(funding, spending, List.unmodifiable(segments));
  }
}

class BudgeteerState {
  final Json? plan;
  final List<Json> groups;
  final List<Json> entries;
  final List<Json> labels;
  final List<Json> entryLabels;
  final int groupsRevision;
  final int excludedSourceCount;
  const BudgeteerState(
      {this.plan,
      this.groups = const [],
      this.entries = const [],
      this.labels = const [],
      this.entryLabels = const [],
      this.groupsRevision = 0,
      this.excludedSourceCount = 0});
  const BudgeteerState.empty() : this();

  int get revision => plan?['revision'] as int? ?? 0;

  static int _compare(Json a, Json b) {
    final position =
        integer(a['sort_position']).compareTo(integer(b['sort_position']));
    return position != 0 ? position : '${a['id']}'.compareTo('${b['id']}');
  }

  List<Json> childrenOf(Object? parentId, {String kind = 'withdrawal'}) =>
      groups
          .where((group) =>
              group['parent_group_id'] == parentId &&
              (group['kind'] ?? 'withdrawal') == kind)
          .toList()
        ..sort(_compare);

  List<Json> get depositGroups => childrenOf(null, kind: 'deposit');

  List<Json> directDeposits(Object? groupId) =>
      deposits.where((entry) => entry['group_id'] == groupId).toList();

  List<Json> get depositInputs => [
        for (final group in [...depositGroups, null])
          if (directDeposits(group?['id']).isNotEmpty)
            {
              'id': group == null
                  ? 'deposit-ungrouped'
                  : 'deposit-group:${group['id']}',
              'name': group?['name'] ?? 'Ungrouped',
              'color_key': group?['color_key'] ?? 'teal',
              'amount_minor': directDeposits(group?['id']).fold<int>(
                  0, (sum, entry) => sum + integer(entry['amount_minor'])),
            },
      ];

  List<Json> get orderedGroups {
    final result = <Json>[];
    final pending = childrenOf(null).reversed.toList();
    while (pending.isNotEmpty) {
      final group = pending.removeLast();
      result.add(group);
      pending.addAll(childrenOf(group['id']).reversed);
    }
    return List.unmodifiable(result);
  }

  List<Json> pathOf(Object id) {
    final byId = {for (final group in groups) group['id']: group};
    if (!byId.containsKey(id)) throw ArgumentError.value(id, 'id');
    final path = <Json>[];
    Json? group = byId[id];
    while (group != null) {
      path.add(group);
      group = byId[group['parent_group_id']];
    }
    return List.unmodifiable(path.reversed);
  }

  int depthOf(Object id) => pathOf(id).length - 1;

  Set<String> descendantIds(Object id) {
    pathOf(
        id); // Reject unknown IDs instead of silently treating them as roots.
    final result = <String>{};
    final pending = childrenOf(id);
    while (pending.isNotEmpty) {
      final group = pending.removeLast();
      result.add(group['id'] as String);
      pending.addAll(childrenOf(group['id']));
    }
    return Set.unmodifiable(result);
  }

  List<Json> directWithdrawals(Object? groupId) => entries
      .where((e) => e['kind'] == 'withdrawal' && e['group_id'] == groupId)
      .toList()
    ..sort(_compare);
  List<Json> get deposits =>
      entries.where((e) => e['kind'] == 'deposit').toList()..sort(_compare);
  List<Json> get withdrawals {
    final result = <Json>[];
    for (final group in [
      ...orderedGroups,
      <String, dynamic>{'id': null}
    ]) {
      result.addAll(directWithdrawals(group['id']));
    }
    return result;
  }

  BudgeteerGroupTotals groupTotals(Object? id) {
    if (id != null) pathOf(id);
    return allocation.totals[id]!;
  }

  BudgeteerAllocation get allocation {
    final base = BudgeteerAllocation.calculate(deposits, withdrawals);
    final direct = <String?, int>{null: 0};
    final funded = <String?, int>{null: 0};
    for (final group in orderedGroups) {
      direct[group['id'] as String] = 0;
      funded[group['id'] as String] = 0;
    }
    for (final segment in base.segments) {
      final id = segment.entry['group_id'] as String?;
      direct[id] = direct[id]! + segment.funded + segment.unfunded;
      funded[id] = funded[id]! + segment.funded;
    }
    final subtree = {...direct};
    final subtreeFunded = {...funded};
    for (final group in orderedGroups.reversed) {
      final id = group['id'] as String;
      final parent = group['parent_group_id'] as String?;
      if (parent != null) {
        subtree[parent] = subtree[parent]! + subtree[id]!;
        subtreeFunded[parent] = subtreeFunded[parent]! + subtreeFunded[id]!;
      }
    }
    final flows = <BudgeteerFlow>[];
    void flow(String source, String target, int amount) {
      if (amount > 0) flows.add(BudgeteerFlow(source, target, amount));
    }

    for (final deposit in depositInputs) {
      flow(deposit['id'] as String, 'income', deposit['amount_minor'] as int);
    }
    for (final group in orderedGroups) {
      final id = group['id'] as String;
      final parent = group['parent_group_id'];
      flow(parent == null ? 'income' : 'group:$parent', 'group:$id',
          subtreeFunded[id]!);
      flow('group:$id', 'direct:$id', funded[id]!);
    }
    flow('income', 'ungrouped', funded[null]!);
    return BudgeteerAllocation(base.deposits, base.withdrawals, base.segments,
        totals: Map.unmodifiable({
          for (final id in direct.keys)
            id: BudgeteerGroupTotals(
                direct[id]!, funded[id]!, subtree[id]!, subtreeFunded[id]!)
        }),
        flows: List.unmodifiable(flows));
  }

  factory BudgeteerState.fromJson(Json json) {
    if (json['schema_version'] is! int || json['schema_version'] != 4) {
      throw const BudgeteerSchemaException();
    }
    Never invalid() =>
        throw const FormatException('Invalid Budgeteer response.');
    Object? readonly(Object? value) {
      if (value is Map) {
        return Map<String, dynamic>.unmodifiable(value
            .map((key, child) => MapEntry(key as String, readonly(child))));
      }
      if (value is List) return List.unmodifiable(value.map(readonly));
      return value;
    }

    List<Json> rows(String key) {
      final value = json[key];
      if (value is! List || value.any((row) => row is! Map)) invalid();
      return List.unmodifiable(value.map((row) => readonly(row) as Json));
    }

    final owner = json['owner_id'];
    final groupsRevision = json['groups_revision'];
    if (owner is! String ||
        owner.isEmpty ||
        groupsRevision is! int ||
        groupsRevision < 0) {
      invalid();
    }
    final rawPlan = json['plan'];
    if (!json.containsKey('plan') || (rawPlan != null && rawPlan is! Map)) {
      invalid();
    }
    final plan =
        rawPlan == null ? null : Map<String, dynamic>.from(rawPlan as Map);
    if (plan != null &&
        (plan['id'] is! String ||
            plan['owner_id'] != owner ||
            plan['revision'] is! int ||
            (plan['revision'] as int) < 1 ||
            plan['month'] is! String ||
            !RegExp(r'^\d{4}-(0[1-9]|1[0-2])-01$')
                .hasMatch(plan['month'] as String))) {
      invalid();
    }
    final groups = rows('groups');
    final entries = rows('entries');
    final labels = rows('legacy_labels');
    final assignments = rows('legacy_entry_labels');
    final excludedSourceCount = json['excluded_source_count'];
    if (excludedSourceCount is! int || excludedSourceCount < 0) invalid();
    bool validNames(List<Json> values) => values.every((row) =>
        row['id'] is String &&
        (row['id'] as String).isNotEmpty &&
        row['name'] is String &&
        (row['name'] as String).trim().isNotEmpty);
    if (!validNames(groups) || !validNames(entries) || !validNames(labels)) {
      invalid();
    }
    final groupIds = groups.map((row) => row['id']).toSet();
    final entryIds = entries.map((row) => row['id']).toSet();
    final labelIds = labels.map((row) => row['id']).toSet();
    if (groupIds.length != groups.length ||
        entryIds.length != entries.length ||
        labelIds.length != labels.length ||
        (plan == null &&
            (entries.isNotEmpty ||
                assignments.isNotEmpty ||
                excludedSourceCount != 0))) {
      invalid();
    }
    void validateGroups(List<Json> values) {
      final byId = {for (final group in values) group['id']: group};
      if (!validNames(values) || byId.length != values.length) invalid();
      for (final group in values) {
        if (!['deposit', 'withdrawal'].contains(group['kind']) ||
            group['owner_id'] != owner ||
            group.containsKey('plan_id') ||
            group['sort_position'] is! int ||
            (group['sort_position'] as int) < 0 ||
            (group['kind'] == 'deposit' && group['parent_group_id'] != null) ||
            !group.containsKey('parent_group_id') ||
            (group['parent_group_id'] != null &&
                !byId.containsKey(group['parent_group_id']))) {
          invalid();
        }
        final parent = byId[group['parent_group_id']];
        if (parent != null && parent['kind'] != group['kind']) invalid();
      }
      final complete = <Object?>{};
      for (final id in byId.keys) {
        final visiting = <Object?>{};
        Object? current = id;
        while (current != null && !complete.contains(current)) {
          if (!visiting.add(current)) invalid();
          current = byId[current]!['parent_group_id'];
        }
        complete.addAll(visiting);
      }
    }

    validateGroups(groups);
    for (final entry in entries) {
      if (!['deposit', 'withdrawal'].contains(entry['kind']) ||
          (entry['group_id'] != null &&
              !groupIds.contains(entry['group_id'])) ||
          (entry['group_id'] != null &&
              groups.singleWhere((g) => g['id'] == entry['group_id'])['kind'] !=
                  entry['kind']) ||
          (entry['source_snapshot'] != null &&
              entry['source_snapshot'] is! Map) ||
          (entry['source_current'] != null &&
              entry['source_current'] is! Map) ||
          (entry.containsKey('plan_id') && entry['plan_id'] != plan?['id']) ||
          (entry.containsKey('owner_id') && entry['owner_id'] != owner)) {
        invalid();
      }
    }
    final assignmentIds = <String>{};
    for (final assignment in assignments) {
      final snapshot = assignment['entry_snapshot'];
      if (!labelIds.contains(assignment['label_id']) ||
          (assignment.containsKey('plan_id') &&
              assignment['plan_id'] != plan?['id']) ||
          (assignment.containsKey('owner_id') &&
              assignment['owner_id'] != owner) ||
          !assignmentIds.add(
              '${assignment['entry_id']}\u0000${assignment['label_id']}')) {
        invalid();
      }
      if (snapshot != null || !entryIds.contains(assignment['entry_id'])) {
        if (snapshot is! Map ||
            snapshot['id'] is! String ||
            snapshot['id'] != assignment['entry_id'] ||
            snapshot['kind'] != 'withdrawal' ||
            snapshot['plan_id'] != plan?['id'] ||
            snapshot['plan_id'] != assignment['plan_id'] ||
            snapshot['owner_id'] is! String ||
            snapshot['owner_id'] != assignment['owner_id'] ||
            snapshot['owner_id'] != plan?['owner_id'] ||
            snapshot['name'] is! String ||
            (snapshot['name'] as String).trim().isEmpty ||
            snapshot['amount_minor'] is! int ||
            snapshot['amount_minor'] <= 0 ||
            snapshot['amount_minor'] > budgeteerMaxMinor ||
            (snapshot['source_snapshot'] != null &&
                snapshot['source_snapshot'] is! Map)) {
          invalid();
        }
      }
    }
    final state = BudgeteerState(
        plan: plan == null ? null : Map.unmodifiable(plan),
        groups: groups,
        entries: entries,
        labels: labels,
        entryLabels: assignments,
        groupsRevision: groupsRevision,
        excludedSourceCount: excludedSourceCount);
    state.allocation;
    return state;
  }
}
