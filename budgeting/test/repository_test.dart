import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';

void main() {
  test('reads every page instead of silently truncating financial totals',
      () async {
    var calls = 0;
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      calls++;
      expect(request.url.queryParameters['order'], startsWith('id.asc'));
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      return http.Response(
          jsonEncode(List.generate(
              offset == 0 ? 500 : 2, (i) => {'id': '${offset + i}'})),
          200,
          headers: {'content-type': 'application/json'},
          request: request);
    }));
    addTearDown(client.dispose);
    final rows = await LedgerRepository(client).rows('transactions');
    expect(rows.length, 502);
    expect(rows.last['id'], '501');
    expect(calls, 2);
  });
  test('profiles and annotations use their real primary keys', () async {
    final orders = <String?>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      orders.add(request.url.queryParameters['order']);
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    await repo.rows('profiles');
    await repo.rows('transaction_annotations');
    expect(orders[0], startsWith('owner_id.asc'));
    expect(orders[1], startsWith('transaction_id.asc'));
  });
  test('edge API uses nested route, JSON body and GET export', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response('{"status":"ok"}', 200,
          headers: {'content-type': 'application/json'});
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    expect((await repo.api('imports/batch/undo'))['status'], 'ok');
    await repo.api('export', get: true);
    expect(
        requests.first.url.path, '/functions/v1/api/api/v1/imports/batch/undo');
    expect(requests.first.body, '{}');
    expect(requests.last.method, 'GET');
  });
  test(
      'sanitized actionable API errors survive without dumping server payloads',
      () async {
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async => http.Response(
            '{"code":"cooldown","message":"Refresh is cooling down.","retryAt":"2026-11-06","private":"secret"}',
            429,
            headers: {'content-type': 'application/json'})));
    addTearDown(client.dispose);
    expect(
        () => LedgerRepository(client).api('accounts/id/balance-refresh'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            'Refresh is cooling down. Try again after 2026-11-06.')));
  });
  test('unexpected API shapes are rejected', () async {
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async => http.Response('[]', 200,
            headers: {'content-type': 'application/json'})));
    addTearDown(client.dispose);
    expect(() => LedgerRepository(client).api('export', get: true),
        throwsFormatException);
  });
  test(
      'nonstandard failure payloads are not presented as trusted validation messages',
      () async {
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async =>
            http.Response('private proxy debug details', 503)));
    addTearDown(client.dispose);
    expect(() => LedgerRepository(client).api('export', get: true),
        throwsA(isA<FunctionException>()));
  });
}
