import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/app.dart';
import 'package:supabase/supabase.dart';

String totp(String secret) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = 0, value = 0;
  final key = <int>[];
  for (final c in secret.toUpperCase().replaceAll('=', '').split('')) {
    final digit = alphabet.indexOf(c);
    if (digit < 0) {
      throw const FormatException('Invalid synthetic TOTP fixture.');
    }
    value = (value << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      key.add((value >> bits) & 255);
    }
  }
  final counter = ByteData(8)
    ..setUint64(0, DateTime.now().millisecondsSinceEpoch ~/ 30000);
  final digest = Hmac(sha1, key).convert(counter.buffer.asUint8List()).bytes;
  final offset = digest.last & 15;
  final code = ((digest[offset] & 127) << 24) |
      (digest[offset + 1] << 16) |
      (digest[offset + 2] << 8) |
      digest[offset + 3];
  return (code % 1000000).toString().padLeft(6, '0');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local real Auth MFA PostgREST and Edge workflow',
      (tester) async {
    const url = String.fromEnvironment('TEST_SUPABASE_URL');
    const key = String.fromEnvironment('TEST_SUPABASE_KEY');
    const email = String.fromEnvironment('TEST_OWNER_EMAIL');
    const password = String.fromEnvironment('TEST_OWNER_PASSWORD');
    const secret = String.fromEnvironment('TEST_OWNER_TOTP_SECRET');
    final host = Uri.parse(url).host;
    expect([
      'localhost',
      '127.0.0.1',
      'host.docker.internal',
      'kong',
      'supabase_kong_private-budgeting'
    ], contains(host), reason: 'Must never run against hosted financial data.');
    expect([key, email, password, secret].every((v) => v.isNotEmpty), isTrue,
        reason: 'Synthetic local fixtures must be explicitly supplied.');
    final client = SupabaseClient(url, key);
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, email);
    await tester.enterText(find.byType(TextField).last, password);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Authenticator code'), findsOneWidget);
    expect(find.text('TRACKED NET POSITION'), findsNothing);
    await tester.enterText(find.byType(TextField).first, totp(secret));
    await tester.tap(find.text('Verify and continue'));
    await tester.pumpAndSettle();
    expect(find.text('TRACKED NET POSITION'), findsOneWidget);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add manual account'));
    await tester.pumpAndSettle();
    final name = 'Synthetic browser ${DateTime.now().millisecondsSinceEpoch}';
    await tester.enterText(find.byType(TextField).at(0), name);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    final rows = await client.from('accounts').select().eq('name', name);
    expect(rows, hasLength(1));
    expect(rows.single['source'], 'manual');
    final usage = await client.functions
        .invoke('api/api/v1/usage', method: HttpMethod.get);
    expect(usage.status, 200);
    expect(usage.data['limit'], 50);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text(name), findsNothing);
    expect(client.auth.currentSession, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
