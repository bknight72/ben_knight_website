import 'package:flutter_test/flutter_test.dart';
import 'package:private_budgeting/platform_stub.dart' as platform;

void main() {
  test('nonbrowser file selection and export do not persist data', () async {
    expect(await platform.pickCsv(), isNull);
    await platform.download('synthetic.json', '{}');
  });
  test('nonbrowser cannot invoke bank connections', () async {
    expect(() => platform.linkStripe('pk_test_synthetic', 'synthetic-secret'),
        throwsUnsupportedError);
    platform.clearAuthUrl();
  });
}
