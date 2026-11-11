import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';

void main() {
  test('Budgeteer RPCs use month scope and revision checked mutations',
      () async {
    final requests = <http.Request>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode({
            'plan': null,
            'entries': [],
            'groups': [],
            'labels': [],
            'entry_labels': [],
            'excluded_source_count': 0
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request);
    }));
    addTearDown(client.dispose);
    final repository = LedgerRepository(client);
    expect((await repository.budgeteerRead('2026-11')).revision, 0);
    await repository
        .budgeteerMutate('2026-11', 0, 'entry_save', {'name': 'Rent'});
    expect(requests.first.url.path, '/rest/v1/rpc/budgeteer_read');
    expect(jsonDecode(requests.first.body), {'p_month': '2026-11-01'});
    expect(jsonDecode(requests.last.body), {
      'p_month': '2026-11-01',
      'p_revision': 0,
      'p_operation': 'entry_save',
      'p_payload': {'name': 'Rent'}
    });
    expect(() => repository.budgeteerRead('2026-13'), throwsFormatException);
    expect(requests.length, 2);
    await repository.budgeteerMutate('2026-11', 3, 'sources_include', {});
    expect(jsonDecode(requests.last.body), {
      'p_month': '2026-11-01',
      'p_revision': 3,
      'p_operation': 'sources_include',
      'p_payload': {}
    });
    await repository.budgeteerMutate('2026-11', 4, 'sources_restore', {});
    expect(jsonDecode(requests.last.body)['p_operation'], 'sources_restore');
  });

  test('Budgeteer rejects malformed data and sanitizes database errors',
      () async {
    var mode = 0;
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      if (mode == 0) {
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      return http.Response(
          jsonEncode({
            'code': 'P0001',
            'message':
                mode == 1 ? 'budgeteer_conflict' : 'private financial details',
            'details': 'sensitive',
            'hint': null
          }),
          400,
          headers: {'content-type': 'application/json'},
          request: request);
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    await expectLater(repo.budgeteerRead('2026-11'), throwsFormatException);
    mode = 1;
    await expectLater(
        repo.budgeteerMutate('2026-11', 1, 'group_save', {}),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('budgeteer_conflict'))));
    mode = 2;
    await expectLater(
        repo.budgeteerRead('2026-11'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            isNot(contains('private financial')))));
  });
}
