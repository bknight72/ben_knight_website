import 'package:flutter_test/flutter_test.dart';
import '../scripts/dev_server.dart' as dev;

void main() {
  const url = 'https://abcdefghijklmnopqrst.supabase.co';
  const key = 'sb_publishable_abcdefghijklmnopqrstuv';
  test('extracts only public Supabase configuration, never Stripe enablement',
      () {
    expect(
        dev.validatePublicConfig({
          'supabaseUrl': url,
          'supabasePublishableKey': key,
          'stripeEnabled': true,
          'stripePublishableKey': 'pk_live_not_forwarded',
        }),
        {'SUPABASE_URL': url, 'SUPABASE_PUBLISHABLE_KEY': key});
  });
  test('rejects secrets, unknown fields, untrusted URLs and malformed keys',
      () {
    for (final value in [
      null,
      [],
      {},
      {
        'supabaseUrl': url,
        'supabasePublishableKey': key,
        'DATABASE_URL': 'private'
      },
      for (final badUrl in [
        'http://abcdefghijklmnopqrst.supabase.co',
        '$url/',
        '$url/path',
        'https://attacker.invalid'
      ])
        {'supabaseUrl': badUrl, 'supabasePublishableKey': key},
      for (final badKey in [
        '',
        'sb_secret_abcdefghijklmnopqrstuv',
        'eyJlegacy',
        'sb_publishable_placeholder123456789'
      ])
        {'supabaseUrl': url, 'supabasePublishableKey': badKey},
    ]) {
      expect(() => dev.validatePublicConfig(value), throwsFormatException);
    }
  });
  test('watches Dart and web assets without financial or generated files', () {
    expect(dev.isFrontendChange('/source/lib/app.dart'), isTrue);
    expect(dev.isFrontendChange('/source/web/assets/image.png'), isTrue);
    expect(dev.isFrontendChange('/source/config.yaml'), isTrue);
    expect(dev.isFrontendChange('/source/.env'), isFalse);
    expect(dev.isFrontendChange('/source/export.csv'), isFalse);
  });
}
