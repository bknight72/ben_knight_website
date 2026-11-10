import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/repository.dart';
import 'package:supabase/supabase.dart';
import 'auth_test.dart' show session;

void main() {
  test('pending API uses GET and rejects malformed summaries', () async {
    var malformed = false;
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        httpClient: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, endsWith('/connections/pending'));
      return http.Response(
          jsonEncode({
            'sessions': malformed
                ? [{}]
                : [
                    {
                      'sessionId': 'original',
                      'createdAt': '2026-11-10',
                      'status': 'pending'
                    }
                  ]
          }),
          200,
          headers: {'content-type': 'application/json'});
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    expect((await repo.pendingConnections()).single['sessionId'], 'original');
    malformed = true;
    await expectLater(repo.pendingConnections(), throwsFormatException);
  });

  test('completion checks owner/MFA before and after accepting async work',
      () async {
    var ownerAllowed = true;
    var completionCalls = 0;
    var loseOwner = false;
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      Object result;
      if (request.url.path.endsWith('/token')) {
        result = session('aal2');
      } else if (request.url.path.endsWith('/is_budget_owner')) {
        result = ownerAllowed;
      } else {
        completionCalls++;
        expect(jsonDecode(request.body), {'sessionId': 'original'});
        if (loseOwner) ownerAllowed = false;
        result = {
          'accountIds': ['a'],
          'status': 'queued'
        };
      }
      return http.Response(jsonEncode(result), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    final repo = LedgerRepository(client);
    await expectLater(
        repo.completeConnection('original', null), throwsFormatException);
    expect(completionCalls, 0);
    await client.auth
        .signInWithPassword(email: 'owner@example.test', password: 'synthetic');
    final owner = repo.authenticatedOwner;
    expect(owner, isNotNull);
    expect(
        (await repo.completeConnection('original', owner))['status'], 'queued');
    loseOwner = true;
    await expectLater(
        repo.completeConnection('original', owner), throwsFormatException);
    expect(completionCalls, 2);
    await expectLater(
        repo.completeConnection('original', owner), throwsFormatException);
    expect(completionCalls, 2);
  });
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
