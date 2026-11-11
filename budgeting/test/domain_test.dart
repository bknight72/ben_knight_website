import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/domain.dart';

void main() {
  group('Integer money', () {
    test('parses exact minor units without binary floating-point', () {
      expect(parseMoney('0.01'), 1);
      expect(parseMoney('12.3'), 1230);
      expect(parseMoney('-1024.99'), -102499);
      expect(parseMoney(' 0 '), 0);
      expect(parseMoney('-0.01'), -1);
      expect(parseMoney('1000000.99'), 100000099);
      expect(parseMoney('90000000000.00'), 9000000000000);
    });
    test('rejects locale ambiguity, precision loss and unsupported notation',
        () {
      for (final input in [
        '',
        '.',
        '1.001',
        '1,000.00',
        '1e2',
        '\$4',
        '(4.00)',
        '+5',
        'NaN',
        '90071992547410.00',
        '90000000000.01',
        '01.00'
      ]) {
        expect(() => parseMoney(input), throwsFormatException, reason: input);
      }
    });
    test('formats signed grouped USD', () {
      expect(money(123456), '\$1,234.56');
      expect(money(-1), '-\$0.01');
      expect(money(0), '\$0.00');
      expect(decimalMoney(-123456), '-1234.56');
      expect(decimalMoney(1), '0.01');
    });
  });
  group('Financial reporting', () {
    test('reporting month honors Denver at UTC boundaries and DST', () {
      expect(reportingMonth(DateTime.utc(2026, 12, 1, 6, 59)), '2026-11');
      expect(reportingMonth(DateTime.utc(2026, 12, 1, 7)), '2026-12');
      expect(reportingMonth(DateTime.utc(2026, 7, 1, 5, 59)), '2026-06');
      expect(reportingMonth(DateTime.utc(2026, 7, 1, 6)), '2026-07');
    });
    Json tx(int amount,
            {String status = 'posted',
            String? posted = '2026-11-02',
            String date = '2026-11-01',
            String? category,
            String? kind,
            bool transfer = false,
            bool payment = false}) =>
        {
          'amount_minor': amount,
          'status': status,
          'posted_date': posted,
          'transaction_date': date,
          'category_id': category,
          'category_kind': kind,
          'is_transfer': transfer,
          'is_card_payment': payment,
        };
    test('cash minus card debt; missing balances remain unknown', () {
      expect(netPosition([]), isNull);
      expect(
          netPosition([
            {'type': 'cash', 'balance_minor': null}
          ]),
          isNull);
      expect(
          netPosition([
            {'type': 'cash', 'balance_minor': 50000},
            {'type': 'credit', 'balance_minor': 12000}
          ]),
          38000);
      expect(
          netPosition([
            {'type': 'cash', 'balance_minor': -100},
            {'type': 'credit', 'balance_minor': 500}
          ]),
          -600);
    });
    test('source-specific credit balances preserve debt and overpayments', () {
      for (final kind in ['cash', 'credit']) {
        for (final balance in [-100000, 0, 100000]) {
          final account = {'kind': kind, 'source': 'stripe'};
          expect(accountBalance(account, {'current_minor': balance}),
              kind == 'credit' ? -balance : balance);
          expect(
              accountBalance(
                  account, {'current_minor': balance, 'source': 'manual'}),
              balance);
        }
      }
      expect(
          netPosition([
            {'kind': 'cash', 'balance_minor': 20000},
            {'kind': 'credit', 'balance_minor': 100000},
          ]),
          -80000);
    });
    test('posted only, excludes both sides of transfers and card payments', () {
      final summary = LedgerSummary.calculate([
        tx(100000),
        tx(-1500, category: 'food'),
        tx(-999, status: 'pending'),
        tx(-888, status: 'void'),
        tx(-4000, transfer: true),
        tx(4000, transfer: true),
        tx(-2000, payment: true),
        tx(2000, payment: true),
      ], '2026-11');
      expect(summary.income, 100000);
      expect(summary.spending, 1500);
      expect(summary.categories, {'food': 1500});
      expect(
          LedgerSummary.calculate([
            {...tx(-500), 'excluded_from_budget': true}
          ], '2026-11')
              .spending,
          0);
    });
    test('refunds offset expense category, date fallback and month boundary',
        () {
      final summary = LedgerSummary.calculate([
        tx(-5000, category: 'food', kind: 'expense'),
        tx(2000, category: 'food', kind: 'expense'),
        tx(10000, posted: null),
        tx(-9000, posted: '2026-12-01', date: '2026-11-30'),
      ], '2026-11');
      expect(summary.income, 10000);
      expect(summary.spending, 3000);
      expect(summary.categories['food'], 3000);
    });
    test('pending-to-posted state replacement counts once', () {
      final pending = tx(-200, status: 'pending');
      expect(LedgerSummary.calculate([pending], '2026-11').spending, 0);
      expect(
          LedgerSummary.calculate([
            {...pending, 'status': 'posted'}
          ], '2026-11')
              .spending,
          200);
      expect(
          LedgerSummary.calculate([
            {...pending, 'status': 'void'}
          ], '2026-11')
              .spending,
          0);
    });
    test('income reversals offset income, never add expense budget actuals',
        () {
      final summary = LedgerSummary.calculate(
          [tx(10000, kind: 'income'), tx(-2000, kind: 'income')], '2026-11');
      expect(summary.income, 8000);
      expect(summary.spending, 0);
      expect(summary.categories, isEmpty);
    });
  });
  group('Monthly financial history', () {
    Json account(String id, String kind) => {'id': id, 'kind': kind};
    Json snapshot(String accountId, int? balance, String observed,
            {String id = 'snapshot'}) =>
        {
          'id': id,
          'account_id': accountId,
          'current_minor': balance,
          'observed_at': observed,
        };
    Json expense(int amount, String date, {String status = 'posted'}) => {
          'amount_minor': amount,
          'transaction_date': date,
          'category_kind': 'expense',
          'status': status,
        };

    test('starts in October Denver, labels current month, crosses years', () {
      expect(
          financialHistory([], [], [], now: DateTime.utc(2026, 10, 1, 5, 59)),
          isEmpty);
      final first =
          financialHistory([], [], [], now: DateTime.utc(2026, 10, 1, 6));
      expect(first.single.month, '2026-10');
      expect(first.single.label, '2026-10 (so far)');
      expect(first.single.isCurrent, isTrue);
      final history =
          financialHistory([], [], [], now: DateTime.utc(2027, 1, 1, 7));
      expect(history.map((row) => row.month),
          ['2026-10', '2026-11', '2026-12', '2027-01']);
      expect(history.first.label, '2026-10');
      expect(history.first.isCurrent, isFalse);
      expect(history.last.label, '2027-01 (so far)');
      expect(history.every((row) => row.netWorth == null), isTrue);
      expect(history.every((row) => row.totalDebt == null), isTrue);
      expect(history.first.accountCount, 0);
      expect(history.first.oldestObservation, isNull);
    });

    test('uses strict Denver month boundaries and inclusive current instant',
        () {
      final now = DateTime.utc(2026, 12, 5, 12);
      final history = financialHistory([
        account('cash', 'cash'),
      ], [
        snapshot('cash', 100, '2026-11-01T05:59:59.999999Z'),
        snapshot('cash', 200, '2026-11-01T06:00:00Z'),
        snapshot('cash', 300, '2026-12-01T06:59:59.999999Z'),
        snapshot('cash', 400, '2026-12-01T07:00:00Z'),
        snapshot('cash', 500, now.toIso8601String()),
        snapshot('cash', 900, '2026-12-05T12:00:00.000001Z'),
      ], [], now: now);
      expect(history.map((row) => row.netWorth), [100, 300, 500]);
      expect(history.last.observations['cash'], now);
      expect(history.every((row) => row.totalDebt == 0), isTrue);
    });

    test('compares offset timestamps as instants across DST and stable ties',
        () {
      final snapshots = [
        snapshot('card', 50, '2026-11-01T01:50:00-06:00', id: 'early'),
        snapshot('card', 200, '2026-11-01T01:10:00-07:00', id: 'b'),
        snapshot('card', 100, '2026-11-01T08:10:00Z', id: 'a'),
        snapshot('card', 400, '2026-11-01T08:10:00Z', id: 'b'),
      ];
      final accounts = [account('card', 'credit')];
      for (final input in [snapshots, snapshots.reversed.toList()]) {
        final history = financialHistory(accounts, input, [],
            now: DateTime.utc(2026, 11, 1, 8, 10));
        expect(history.first.totalDebt, isNull);
        expect(history.last.totalDebt, 400);
        expect(history.last.netWorth, -400);
        expect(
            history.last.oldestObservation, DateTime.utc(2026, 11, 1, 8, 10));
      }
    });

    test('missing cash does not hide known credit debt; coverage is explicit',
        () {
      final history = financialHistory([
        {...account('cash', 'cash'), 'created_at': '2026-11-10T00:00:00Z'},
        account('card', 'credit'),
      ], [
        snapshot('card', 250, '2026-09-20T12:00:00Z'),
        snapshot('cash', 500, '2026-11-05T12:00:00Z'),
        snapshot('deleted', 999999, '2026-09-20T12:00:00Z'),
      ], [], now: DateTime.utc(2026, 11, 11));
      final october = history.first;
      expect(october.netWorth, isNull);
      expect(october.totalDebt, 250);
      expect(october.accountCount, 2);
      expect(october.observedAccountCount, 1);
      expect(october.creditAccountCount, 1);
      expect(october.observedCreditAccountCount, 1);
      expect(october.carriedForwardAccountCount, 1);
      expect(october.oldestObservation, DateTime.utc(2026, 9, 20, 12));
      expect(october.oldestCreditObservation, october.oldestObservation);
      expect(history.last.netWorth, 250);
      expect(history.last.observedAccountCount, 2);
      expect(history.last.carriedForwardAccountCount, 1);
      expect(() => october.observations.clear(), throwsUnsupportedError);
    });

    test('missing credit gaps both balances; no credit is zero debt only', () {
      final now = DateTime.utc(2026, 11, 10);
      final snapshots = [snapshot('cash', 0, '2026-10-01T00:00:00Z')];
      final missingCredit = financialHistory(
              [
                account('cash', 'cash'),
                account('card', 'credit'),
              ],
              snapshots,
              [],
              now: now)
          .first;
      expect(missingCredit.netWorth, isNull);
      expect(missingCredit.totalDebt, isNull);
      expect(missingCredit.observedCreditAccountCount, 0);
      expect(missingCredit.oldestCreditObservation, isNull);
      final cashOnly =
          financialHistory([account('cash', 'cash')], snapshots, [], now: now)
              .first;
      expect(cashOnly.netWorth, 0);
      expect(cashOnly.totalDebt, 0);
      final noSnapshots =
          financialHistory([account('cash', 'cash')], [], [], now: now).first;
      expect(noSnapshots.netWorth, isNull);
      expect(noSnapshots.totalDebt, 0);
    });

    test(
        'signed cash and overpaid credit affect net worth, never negative debt',
        () {
      final history = financialHistory([
        {'id': 'cash', 'type': 'cash'},
        {'id': 'overpaid', 'type': 'credit'},
        {'id': 'debt', 'type': 'credit'},
      ], [
        snapshot('cash', -1000, '2026-10-20T00:00:00Z'),
        snapshot('overpaid', -300, '2026-10-21T00:00:00Z'),
        snapshot('debt', 500, '2026-10-22T00:00:00Z'),
      ], [], now: DateTime.utc(2026, 11, 11));
      expect(history.first.netWorth, -1200);
      expect(history.first.totalDebt, 500);
      expect(history.first.oldestObservation, DateTime.utc(2026, 10, 20));
      expect(history.first.oldestCreditObservation, DateTime.utc(2026, 10, 21));
    });

    test('Stripe debt and overpayments use source-aware historical balances',
        () {
      final accounts = [
        {'id': 'cash', 'kind': 'cash', 'source': 'stripe'},
        {'id': 'card', 'kind': 'credit', 'source': 'stripe'},
      ];
      final history = financialHistory(
          accounts,
          [
            snapshot('cash', 20000, '2026-10-20T00:00:00Z'),
            snapshot('card', -100000, '2026-10-20T00:00:00Z'),
            {
              ...snapshot('card', 300, '2026-11-01T12:00:00Z'),
              'source': 'stripe',
            },
          ],
          [],
          now: DateTime.utc(2026, 11, 11));
      expect(history.first.netWorth, -80000);
      expect(history.first.totalDebt, 100000);
      expect(history.last.netWorth, 20300);
      expect(history.last.totalDebt, 0);
      final manualOverride = financialHistory(
              accounts,
              [
                snapshot('cash', -1000, '2026-10-20T00:00:00Z'),
                {
                  ...snapshot('card', 500, '2026-10-20T00:00:00Z'),
                  'source': 'manual',
                },
              ],
              [],
              now: DateTime.utc(2026, 11, 11))
          .first;
      expect(manualOverride.netWorth, -1500);
      expect(manualOverride.totalDebt, 500);
    });

    test('invalid, ambiguous, null and future observations cannot fill gaps',
        () {
      final history = financialHistory([
        account('cash', 'cash'),
      ], [
        snapshot('cash', 100, 'invalid'),
        snapshot('cash', 100, '2026-10-01T12:00:00'),
        snapshot('cash', null, '2026-10-01T12:00:00Z'),
        snapshot('cash', 100, '2026-11-12T12:00:00Z'),
      ], [], now: DateTime.utc(2026, 11, 11));
      expect(history.every((row) => row.netWorth == null), isTrue);
      expect(history.every((row) => row.observations.isEmpty), isTrue);
    });

    test('spending reuses ledger exclusions and cuts off at Denver today', () {
      final history = financialHistory([], [], [
        expense(-100, '2026-10-31'),
        expense(-200, '2026-11-10'),
        expense(700, '2026-11-10'),
        expense(-9999, '2026-11-11'),
        expense(-9999, '2026-11-10', status: 'pending'),
        {...expense(-9999, '2026-11-10'), 'is_transfer': true},
        {...expense(-9999, '2026-11-10'), 'is_card_payment': true},
        {...expense(-9999, '2026-11-10'), 'excluded_from_budget': true},
        {...expense(-9999, '2026-11-10'), 'category_kind': 'income'},
        {...expense(-9999, '2026-11-10'), 'posted_date': '2026-11-11'},
        {...expense(-50, '2026-11-11'), 'posted_date': '2026-11-10'},
      ], now: DateTime.utc(2026, 11, 11, 6, 59));
      expect(history.first.spending, 100);
      expect(history.last.spending, -450);
      final nextDay = financialHistory([], [], [
        expense(-100, '2026-11-11'),
      ], now: DateTime.utc(2026, 11, 11, 7));
      expect(nextDay.last.spending, 100);
    });
  });
  group('CSV structure validation', () {
    test('handles quotes, escaped quotes, embedded newlines and CRLF', () {
      expect(
          parseCsv(
              'date,description,amount\r\n2026-11-01,"Shop, ""Local""",-12.34\r\n2026-11-02,"Line\nTwo",1.20\r\n'),
          [
            ['date', 'description', 'amount'],
            ['2026-11-01', 'Shop, "Local"', '-12.34'],
            ['2026-11-02', 'Line\nTwo', '1.20'],
          ]);
    });
    test('retains a trailing empty column', () {
      expect(parseCsv('a,b\nx,'), [
        ['a', 'b'],
        ['x', '']
      ]);
    });
    test('rejects malformed and oversized input', () {
      for (final input in [
        '',
        'a,b\nx',
        'a"b',
        '"unfinished',
        '"closed"oops',
        'a' * 5242881,
        'a\n' * 10002,
        'a,a\nx,y',
        'a,\nx,y',
        'a\nx\u0000',
        'a\n${'x' * 2001}',
        '${List.generate(101, (i) => 'h$i').join(',')}\n${List.filled(101, 'x').join(',')}'
      ]) {
        expect(() => parseCsv(input), throwsFormatException);
      }
    });
    test('BOM and trimmed headers agree with server mapping', () {
      expect(parseCsv('\uFEFF Date , Description \n2026-11-01,Shop').first,
          ['Date', 'Description']);
    });
    test('limits are UTF8 byte based, not character based', () {
      expect(() => parseCsv('a\n${'é' * 2621441}'), throwsFormatException);
    });
    test('observation dates reject normalization and future dates', () {
      expect(observationDate('2026-02-28', DateTime(2026, 11)),
          DateTime(2026, 2, 28));
      for (final date in ['2026-02-30', '2027-01-01', '2026-1-01', 'invalid']) {
        expect(() => observationDate(date, DateTime(2026, 11)),
            throwsFormatException);
      }
    });
    test('missing and old observations are explicitly stale', () {
      final now = DateTime.utc(2026, 11, 10);
      expect(staleBalance(null, now), isTrue);
      expect(staleBalance('invalid', now), isTrue);
      expect(staleBalance('2026-11-01T00:00:00Z', now), isTrue);
      expect(staleBalance('2026-11-09T00:00:00Z', now), isFalse);
    });
    test('safe errors never expose unknown exception content', () {
      expect(safeMessage(Exception('sensitive value')),
          isNot(contains('sensitive')));
      expect(
          safeMessage(const FormatException('invalid date')), 'invalid date');
      expect(integer('123'), 123);
      expect(integer(null), 0);
      expect(integer(3), 3);
    });
  });
}
