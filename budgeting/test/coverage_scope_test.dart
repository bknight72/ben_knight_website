import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first-party coverage scope contains every production Dart module', () {
    final modules = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.path.replaceAll('\\', '/'))
        .toSet();
    expect(
        modules,
        {
          'lib/app.dart',
          'lib/budgeteer.dart',
          'lib/budgeteer_domain.dart',
          'lib/config.dart',
          'lib/domain.dart',
          'lib/main.dart',
          'lib/platform.dart',
          'lib/platform_stub.dart',
          'lib/platform_web.dart',
          'lib/repository.dart',
          'lib/session.dart',
        },
        reason:
            'Any new production module must be added to the fixed coverage denominator. Browser adapters must not silently vanish from VM coverage.');
  });
}
