import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:private_budgeting/config.dart';
import 'package:private_budgeting/main.dart' as entry;
import 'package:private_budgeting/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const valid = '''
currency: USD
reporting_timezone: America/Denver
supported_reporting_timezones: [America/Denver]
budget_rollover: false
max_import_bytes: 5242880
max_import_rows: 10000
stripe_enabled: false
builder: Novacoast-VCA-805
''';
  test('loads real bundled public defaults', () async {
    final config = await AppConfig.load();
    expect(config.currency, 'USD');
    expect(config.reportingTimezone, 'America/Denver');
    expect(config.stripeAllowed, isFalse);
    expect(
        AppConfig.parse(valid.replaceFirst(
                'stripe_enabled: false', 'stripe_enabled: true'))
            .stripeAllowed,
        isTrue);
  });
  test('unsupported or secret-bearing YAML fails closed', () {
    for (final text in [
      '[]',
      valid.replaceFirst('USD', 'EUR'),
      valid.replaceFirst('America/Denver', 'UTC'),
      valid.replaceFirst('rollover: false', 'rollover: true'),
      valid.replaceFirst('5242880', '999'),
      valid.replaceFirst('10000', '10001'),
      valid.replaceFirst('stripe_enabled: false', 'stripe_enabled: yes'),
      '$valid\napi_key: never-allowed',
      valid.replaceFirst('[America/Denver]', '[UTC]')
    ]) {
      expect(() => AppConfig.parse(text), throwsA(isA<FormatException>()));
    }
  });
  test('frontend import bounds agree with authoritative backend contract', () {
    final source =
        File('supabase/functions/_shared/core.ts').readAsStringSync();
    final bytesExpression = RegExp(r'export const MAX_BYTES\s*=\s*([^;]+);')
        .firstMatch(source)!
        .group(1)!;
    final serverBytes = bytesExpression
        .split('*')
        .map((part) => int.parse(part.trim()))
        .reduce((a, b) => a * b);
    final serverRows = int.parse(RegExp(r'export const MAX_ROWS\s*=\s*(\d+);')
        .firstMatch(source)!
        .group(1)!);
    expect(maxImportBytes, serverBytes);
    expect(maxImportRows, serverRows);
  });
  testWidgets('application entry loads asset before safe unconfigured UI',
      (tester) async {
    await tester.runAsync(entry.main);
    await tester.pumpAndSettle();
    expect(find.textContaining('No account or financial data'), findsOneWidget);
  });
  testWidgets('invalid configuration is visible and does not show auth inputs',
      (tester) async {
    await tester.pumpWidget(const BudgetApp(configurationError: true));
    expect(find.textContaining('No financial service was initialized'),
        findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
