import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/repository.dart';
import 'package:private_budgeting/budgeteer_domain.dart';
import 'package:supabase/supabase.dart';

Json response() => {
      'schema_version': 4,
      'owner_id': 'owner',
      'groups_revision': 7,
      'plan': null,
      'entries': [],
      'groups': [
        {
          'id': 'global',
          'owner_id': 'owner',
          'kind': 'withdrawal',
          'name': 'Shared group',
          'parent_group_id': null,
          'sort_position': 3,
        }
      ],
      'legacy_labels': [],
      'legacy_entry_labels': [],
      'excluded_source_count': 0,
    };

void main() {
  test('v4 reads global groups and revision even without a monthly plan',
      () async {
    final requests = <http.Request>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(response()), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    for (final month in ['2026-11', '2027-01']) {
      final state = await repo.budgeteerRead(month);
      expect(state.plan, isNull);
      expect(state.revision, 0);
      expect(state.groupsRevision, 7);
      expect(state.groups.single['id'], 'global');
      expect(state.groups.single['sort_position'], 3);
      expect(requests.last.url.path, '/rest/v1/rpc/budgeteer_read');
      expect(jsonDecode(requests.last.body), {'p_month': '$month-01'});
    }
    expect(() => repo.budgeteerRead('2026-13'), throwsFormatException);
    expect(requests.length, 2);
  });

  test(
      'all mutations inject v4 and expected global revision without editing payload',
      () async {
    final requests = <http.Request>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(response()), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    final operations = <String, Json>{
      'initialize': {},
      'group_save': {
        'name': 'Child',
        'kind': 'withdrawal',
        'color_key': 'teal',
        'parent_group_id': 'global',
      },
      'legacy_label_convert': {
        'confirmed': true,
        'label_id': 'legacy',
        'entry_ids': ['e'],
        'group_id': 'global',
      },
      'entry_save': {'name': 'Rent', 'group_id': 'global'},
      'sources_include': {},
      'sources_restore': {},
      'entry_delete': {'id': 'target'},
      'group_delete': {'id': 'global'},
      'reorder': {
        'group_ids': ['global'],
        'entry_ids': ['e']
      },
      'source_refresh': {'id': 'target'},
    };
    var revision = 0;
    for (final operation in operations.entries) {
      await repo.budgeteerMutate(
          '2026-11', revision, operation.key, operation.value,
          groupsRevision: 7);
      expect(requests.last.url.path, '/rest/v1/rpc/budgeteer_mutate');
      expect(jsonDecode(requests.last.body), {
        'p_month': '2026-11-01',
        'p_revision': revision,
        'p_operation': operation.key,
        'p_payload': {
          ...operation.value,
          'schema_version': 4,
          'expected_groups_revision': 7,
        }
      });
      expect(operation.value.containsKey('schema_version'), isFalse);
      expect(operation.value.containsKey('expected_groups_revision'), isFalse);
      revision++;
    }
    final payload = {
      'kind': 'deposit',
      'name': 'Salary',
      'color_key': 'hex_12ab34',
      'parent_group_id': null,
      'schema_version': 1,
      'expected_groups_revision': 100,
    };
    await repo.budgeteerMutate('2026-11', revision, 'group_save', payload,
        groupsRevision: 0);
    expect(jsonDecode(requests.last.body)['p_payload'], {
      ...payload,
      'schema_version': 4,
      'expected_groups_revision': 0,
    });
    expect(payload['schema_version'], 1);
    expect(payload['expected_groups_revision'], 100);
  });

  test('old server schemas and missing RPCs show actionable upgrade errors',
      () async {
    var mode = 0;
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      final body = mode < 2
          ? {...response(), 'schema_version': mode == 0 ? null : 3}
          : {
              'code': mode == 2 ? 'P0001' : 'PGRST202',
              'message': mode == 2
                  ? 'budgeteer_schema_upgrade_required'
                  : 'Could not find budgeteer_read in the schema cache'
            };
      return http.Response(jsonEncode(body), mode < 2 ? 200 : 400,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    for (mode = 0; mode < 4; mode++) {
      await expectLater(
          repo.budgeteerRead('2026-11'),
          throwsA(isA<BudgeteerSchemaException>()
              .having((e) => e.message, 'message', contains('then reload'))));
    }
  });

  test('a returned monthly plan must match the requested month', () async {
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              ...response(),
              'plan': {
                'id': 'p',
                'owner_id': 'owner',
                'month': '2026-12-01',
                'revision': 1,
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request)));
    addTearDown(client.dispose);
    await expectLater(LedgerRepository(client).budgeteerRead('2026-11'),
        throwsFormatException);
    await expectLater(
        LedgerRepository(client)
            .budgeteerMutate('2026-11', 1, 'initialize', {}, groupsRevision: 7),
        throwsFormatException);
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
        repo.budgeteerMutate('2026-11', 1, 'group_save', {}, groupsRevision: 7),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            allOf(contains('budgeteer_conflict'), contains('global groups')))));
    mode = 2;
    await expectLater(
        repo.budgeteerRead('2026-11'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            isNot(contains('private financial')))));
  });
}
