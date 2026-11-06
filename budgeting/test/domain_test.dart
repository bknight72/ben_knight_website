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
