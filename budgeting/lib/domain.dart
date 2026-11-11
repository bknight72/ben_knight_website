import 'dart:convert';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'config.dart';

bool _zonesLoaded = false;
tz.TZDateTime _reportingDateTime(DateTime instant) {
  if (!_zonesLoaded) {
    tzdata.initializeTimeZones();
    _zonesLoaded = true;
  }
  return tz.TZDateTime.from(instant, tz.getLocation('America/Denver'));
}

String reportingMonth(DateTime instant) {
  final local = _reportingDateTime(instant);
  return '${local.year}-${local.month.toString().padLeft(2, '0')}';
}

/// Money stays in integer cents across parsing, reporting, and API boundaries.
int parseMoney(String input) {
  final value = input.trim();
  if (!RegExp(r'^-?(0|[1-9]\d{0,10})(\.\d{1,2})?$').hasMatch(value)) {
    throw const FormatException('Use a decimal amount, for example 1250.50.');
  }
  final negative = value.startsWith('-');
  final parts = value.replaceFirst('-', '').split('.');
  final cents = int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  if (cents > 9000000000000) {
    throw const FormatException('Amount exceeds the supported range.');
  }
  return negative ? -cents : cents;
}

String money(int cents) {
  final digits = (cents.abs() ~/ 100).toString();
  final grouped = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (match) => '${match[1]},');
  return '${cents < 0 ? '-' : ''}\$$grouped.${(cents.abs() % 100).toString().padLeft(2, '0')}';
}

String decimalMoney(int cents) =>
    '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';

typedef Json = Map<String, dynamic>;

int integer(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class LedgerSummary {
  final int income;
  final int spending;
  final Map<String, int> categories;
  const LedgerSummary(this.income, this.spending, this.categories);

  factory LedgerSummary.calculate(List<Json> transactions, String month) {
    var income = 0;
    var spending = 0;
    final categories = <String, int>{};
    for (final row in transactions) {
      if (row['status'] != 'posted' ||
          row['is_transfer'] == true ||
          row['is_card_payment'] == true ||
          row['excluded_from_budget'] == true) {
        continue;
      }
      final date = '${row['posted_date'] ?? row['transaction_date'] ?? ''}';
      if (!date.startsWith(month)) continue;
      final amount = integer(row['amount_minor']);
      final category = '${row['category_id'] ?? 'uncategorized'}';
      if (row['category_kind'] == 'income' ||
          (amount > 0 && row['category_kind'] != 'expense')) {
        income += amount;
      } else {
        spending -= amount;
        categories[category] = (categories[category] ?? 0) - amount;
      }
    }
    return LedgerSummary(income, spending, categories);
  }
}

/// Balances are observations of retained accounts, not exact closing balances.
class MonthlyFinancialHistory {
  final String month;
  final bool isCurrent;
  final int? netWorth;
  final int? totalDebt;
  final int spending;
  final int accountCount;
  final int creditAccountCount;
  final int observedCreditAccountCount;
  final Map<String, DateTime> observations;
  final DateTime? oldestObservation;
  final DateTime? oldestCreditObservation;

  const MonthlyFinancialHistory({
    required this.month,
    required this.isCurrent,
    required this.netWorth,
    required this.totalDebt,
    required this.spending,
    required this.accountCount,
    required this.creditAccountCount,
    required this.observedCreditAccountCount,
    required this.observations,
    required this.oldestObservation,
    required this.oldestCreditObservation,
  });

  String get label => '$month${isCurrent ? ' (so far)' : ''}';
  int get observedAccountCount => observations.length;
  int get carriedForwardAccountCount => observations.values
      .where((date) => reportingMonth(date).compareTo(month) < 0)
      .length;
}

/// Empty before October 2026. Missing observations never become zero balances.
List<MonthlyFinancialHistory> financialHistory(
  List<Json> accounts,
  List<Json> snapshots,
  List<Json> transactions, {
  required DateTime now,
}) {
  final localNow = _reportingDateTime(now);
  final currentMonth = reportingMonth(now);
  final today = '$currentMonth-${localNow.day.toString().padLeft(2, '0')}';
  final ordered = <({Json row, DateTime observed})>[];
  for (final row in snapshots) {
    final timestamp = '${row['observed_at']}';
    // A timestamp without an offset is not an unambiguous observation instant.
    if (!RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false)
        .hasMatch(timestamp)) {
      continue;
    }
    final observed = DateTime.tryParse(timestamp)?.toUtc();
    if (observed == null || row['current_minor'] == null) continue;
    ordered.add((row: row, observed: observed));
  }
  ordered.sort((a, b) {
    var comparison = a.observed.compareTo(b.observed);
    if (comparison == 0) {
      comparison = '${a.row['id'] ?? ''}'.compareTo('${b.row['id'] ?? ''}');
    }
    // Also deterministic for imported/test rows without distinct snapshot IDs.
    return comparison != 0
        ? comparison
        : integer(a.row['current_minor'])
            .compareTo(integer(b.row['current_minor']));
  });
  final currentTransactions = transactions.where((row) {
    final date = '${row['posted_date'] ?? row['transaction_date'] ?? ''}';
    return date.compareTo(today) <= 0;
  }).toList();
  final history = <MonthlyFinancialHistory>[];
  final latest = <String, ({Json row, DateTime observed})>{};
  var cursor = 0;
  for (var start = tz.TZDateTime(localNow.location, 2026, 10);
      !start.isAfter(localNow);
      start = tz.TZDateTime(localNow.location, start.year, start.month + 1)) {
    final month = reportingMonth(start);
    final isCurrent = month == currentMonth;
    final boundary =
        tz.TZDateTime(localNow.location, start.year, start.month + 1);
    while (cursor < ordered.length &&
        (isCurrent
            ? !ordered[cursor].observed.isAfter(now)
            : ordered[cursor].observed.isBefore(boundary))) {
      final snapshot = ordered[cursor++];
      latest['${snapshot.row['account_id']}'] = snapshot;
    }
    var netWorth = 0;
    var debt = 0;
    var creditCount = 0;
    var observedCreditCount = 0;
    DateTime? oldest;
    DateTime? oldestCredit;
    final observations = <String, DateTime>{};
    for (final account in accounts) {
      final credit = (account['type'] ?? account['kind']) == 'credit';
      if (credit) creditCount++;
      final id = '${account['id']}';
      final snapshot = latest[id];
      if (snapshot == null) continue;
      final balance = accountBalance(account, snapshot.row);
      final observed = snapshot.observed;
      observations[id] = observed;
      if (oldest == null || observed.isBefore(oldest)) oldest = observed;
      netWorth += credit ? -balance : balance;
      if (credit) {
        observedCreditCount++;
        if (balance > 0) debt += balance;
        if (oldestCredit == null || observed.isBefore(oldestCredit)) {
          oldestCredit = observed;
        }
      }
    }
    history.add(MonthlyFinancialHistory(
      month: month,
      isCurrent: isCurrent,
      netWorth: accounts.isNotEmpty && observations.length == accounts.length
          ? netWorth
          : null,
      totalDebt: accounts.isNotEmpty && observedCreditCount == creditCount
          ? debt
          : null,
      spending: LedgerSummary.calculate(
              isCurrent ? currentTransactions : transactions, month)
          .spending,
      accountCount: accounts.length,
      creditAccountCount: creditCount,
      observedCreditAccountCount: observedCreditCount,
      observations: Map.unmodifiable(observations),
      oldestObservation: oldest,
      oldestCreditObservation: oldestCredit,
    ));
  }
  return history;
}

/// Stripe snapshots use negative liabilities; manual snapshots use positive debt.
int accountBalance(Json account, Json snapshot) {
  final balance = integer(snapshot['current_minor']);
  return (account['type'] ?? account['kind']) == 'credit' &&
          (snapshot['source'] ?? account['source']) == 'stripe'
      ? -balance
      : balance;
}

/// A missing balance is not zero. Credit balances are positive liabilities.
int? netPosition(List<Json> accounts) {
  if (accounts.isEmpty || accounts.any((a) => a['balance_minor'] == null)) {
    return null;
  }
  return accounts.fold<int>(
      0,
      (sum, a) =>
          sum +
          ((a['type'] ?? a['kind']) == 'credit'
              ? -integer(a['balance_minor'])
              : integer(a['balance_minor'])));
}

/// RFC 4180-style quoted fields, including escaped quotes and embedded newlines.
List<List<String>> parseCsv(String text) {
  if (utf8.encode(text).length > maxImportBytes) {
    throw const FormatException('CSV exceeds 5 MB.');
  }
  if (text.contains('\u0000')) {
    throw const FormatException('CSV contains null bytes.');
  }
  text = text.replaceFirst(RegExp(r'^\uFEFF'), '');
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var quoted = false;
  var closed = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      if (field.isNotEmpty || closed) {
        throw const FormatException('Unexpected CSV quote.');
      }
      quoted = true;
    } else if (c == ',' || c == '\n' || c == '\r') {
      row.add(field.toString());
      if (row.length > 100) {
        throw const FormatException('CSV exceeds 100 columns.');
      }
      field = StringBuffer();
      closed = false;
      if (c != ',') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        if (row.any((cell) => cell.isNotEmpty)) rows.add(row);
        row = [];
        if (rows.length > maxImportRows + 1) {
          throw const FormatException('CSV exceeds 10,000 rows.');
        }
      }
    } else {
      if (closed) {
        throw const FormatException('Unexpected text after CSV quote.');
      }
      field.write(c);
    }
    if (field.length > 2000) {
      throw const FormatException('CSV field exceeds 2,000 characters.');
    }
  }
  if (quoted) throw const FormatException('Unclosed CSV quote.');
  row.add(field.toString());
  if (row.length > 100) throw const FormatException('CSV exceeds 100 columns.');
  if (row.any((cell) => cell.isNotEmpty)) rows.add(row);
  if (rows.isEmpty) throw const FormatException('CSV is empty.');
  if (rows.length > maxImportRows + 1) {
    throw const FormatException('CSV exceeds 10,000 rows.');
  }
  final width = rows.first.length;
  rows[0] = rows.first.map((header) => header.trim()).toList();
  if (rows.first.any((h) => h.isEmpty) || rows.first.toSet().length != width) {
    throw const FormatException('Headers must be nonempty and unique.');
  }
  if (rows.length < 2) {
    throw const FormatException(
        'CSV requires a header and at least one data row.');
  }
  if (rows.any((row) => row.length != width)) {
    throw const FormatException('CSV rows have inconsistent column counts.');
  }
  return rows;
}

String safeMessage(Object error) {
  if (error is FormatException) return error.message;
  return 'The request could not be confirmed. Check your connection and refresh before retrying; the server may have received it.';
}

DateTime observationDate(String value, DateTime now) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Use YYYY-MM-DD.');
  }
  final date = DateTime.tryParse(value);
  if (date == null ||
      date.toIso8601String().substring(0, 10) != value ||
      date.isAfter(now)) {
    throw const FormatException(
        'Enter a valid observation date, not in the future.');
  }
  return date;
}

bool staleBalance(Object? observedAt, DateTime now) {
  final date = DateTime.tryParse('$observedAt');
  return date == null ||
      now.toUtc().difference(date.toUtc()) > const Duration(days: 7);
}
