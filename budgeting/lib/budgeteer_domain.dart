import 'dart:math' as math;
import 'domain.dart';

const budgeteerMaxMinor = 9000000000000;
const budgeteerColors = ['teal', 'blue', 'amber', 'rose', 'violet', 'slate'];

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
  const BudgeteerAllocation(this.deposits, this.withdrawals, this.segments);
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
  const BudgeteerState(
      {this.plan,
      this.groups = const [],
      this.entries = const [],
      this.labels = const [],
      this.entryLabels = const []});
  const BudgeteerState.empty() : this();

  int get revision => plan?['revision'] as int? ?? 0;

  static int _compare(Json a, Json b) {
    final position =
        integer(a['sort_position']).compareTo(integer(b['sort_position']));
    return position != 0 ? position : '${a['id']}'.compareTo('${b['id']}');
  }

  List<Json> get orderedGroups => [...groups]..sort(_compare);
  List<Json> get deposits =>
      entries.where((e) => e['kind'] == 'deposit').toList()..sort(_compare);
  List<Json> get withdrawals {
    final result = <Json>[];
    for (final group in [
      ...orderedGroups,
      <String, dynamic>{'id': null}
    ]) {
      final rows = entries
          .where(
              (e) => e['kind'] == 'withdrawal' && e['group_id'] == group['id'])
          .toList()
        ..sort(_compare);
      result.addAll(rows);
    }
    return result;
  }

  BudgeteerAllocation get allocation =>
      BudgeteerAllocation.calculate(deposits, withdrawals);

  factory BudgeteerState.fromJson(Json json) {
    Never invalid() =>
        throw const FormatException('Invalid Budgeteer response.');
    List<Json> rows(String key) {
      final value = json[key];
      if (value is! List || value.any((row) => row is! Map)) invalid();
      return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    }

    final rawPlan = json['plan'];
    if (!json.containsKey('plan') || (rawPlan != null && rawPlan is! Map)) {
      invalid();
    }
    final plan =
        rawPlan == null ? null : Map<String, dynamic>.from(rawPlan as Map);
    if (plan != null &&
        (plan['id'] is! String ||
            plan['revision'] is! int ||
            (plan['revision'] as int) < 1 ||
            plan['month'] is! String)) {
      invalid();
    }
    final groups = rows('groups');
    final entries = rows('entries');
    final labels = rows('labels');
    final assignments = rows('entry_labels');
    bool validNames(List<Json> values) => values.every((row) =>
        row['id'] is String &&
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
            (groups.isNotEmpty ||
                entries.isNotEmpty ||
                assignments.isNotEmpty))) {
      invalid();
    }
    for (final entry in entries) {
      if (!['deposit', 'withdrawal'].contains(entry['kind']) ||
          (entry['group_id'] != null &&
              !groupIds.contains(entry['group_id'])) ||
          (entry['kind'] == 'deposit' && entry['group_id'] != null) ||
          (entry['source_snapshot'] != null &&
              entry['source_snapshot'] is! Map) ||
          (entry['source_current'] != null &&
              entry['source_current'] is! Map)) {
        invalid();
      }
    }
    for (final assignment in assignments) {
      if (!entryIds.contains(assignment['entry_id']) ||
          !labelIds.contains(assignment['label_id'])) {
        invalid();
      }
    }
    final state = BudgeteerState(
        plan: plan,
        groups: groups..sort(_compare),
        entries: entries,
        labels: labels,
        entryLabels: assignments);
    state.allocation;
    return state;
  }
}
