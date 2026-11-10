import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_test.dart' as fixtures;

class MemorySessionStorage extends LocalStorage {
  String? value;
  MemorySessionStorage(this.value);
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => value != null;
  @override
  Future<String?> accessToken() async => value;
  @override
  Future<void> persistSession(String persistSessionString) async =>
      value = persistSessionString;
  @override
  Future<void> removePersistedSession() async => value = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('SDK persistence clears on remote logout failure', () async {
    final storage = MemorySessionStorage(jsonEncode(fixtures.session('aal2')));
    final sdk = await Supabase.initialize(
        url: 'https://project.supabase.co',
        publishableKey: 'public-key',
        debug: false,
        httpClient: MockClient((request) async => http.Response(
            '{"message":"network failure"}', 500,
            headers: {'content-type': 'application/json'}, request: request)),
        authOptions: FlutterAuthClientOptions(
            authFlowType: AuthFlowType.implicit,
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: storage,
            pkceAsyncStorage: ImplicitAuthStorage()));
    await Future<void>.delayed(Duration.zero);
    expect(sdk.client.auth.currentSession, isNotNull);
    await expectLater(sdk.client.auth.signOut(scope: SignOutScope.local),
        throwsA(isA<AuthException>()));
    await Future<void>.delayed(Duration.zero);
    expect(sdk.client.auth.currentSession, isNull);
    expect(storage.value, isNull);
    await sdk.dispose();
  });
  test('SDK discards late refresh after local logout', () async {
    final response = Completer<http.Response>();
    final sent = Completer<void>();
    final client = SupabaseClient('https://project.supabase.co', 'public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        sent.complete();
        return response.future;
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await client.auth.setInitialSession(jsonEncode(fixtures.session('aal2')));
    final pending = client.auth.refreshSession();
    final settled = pending.then<void>((_) {}, onError: (Object _) {});
    await sent.future;
    await client.auth.signOut(scope: SignOutScope.local);
    response.complete(http.Response(jsonEncode(fixtures.session('aal2')), 200,
        headers: {'content-type': 'application/json'}));
    await settled;
    expect(client.auth.currentSession, isNull);
    await client.dispose();
  });
  test('storage key is project scoped, implicit flow stores no verifier',
      () async {
    expect(sessionStorageKey('https://project.supabase.co'),
        'sb-project-auth-token');
    final storage = ImplicitAuthStorage();
    await storage.setItem(key: 'verifier', value: 'unused');
    expect(await storage.getItem(key: 'verifier'), isNull);
    await storage.removeItem(key: 'verifier');
  });

  test('rotated stored session is reused without spending old refresh token',
      () async {
    var calls = 0;
    final rotated = fixtures.session('aal2')..['refresh_token'] = 'rotated';
    final storage = MemorySessionStorage(jsonEncode(rotated));
    final client = CoordinatedAuthClient(MockClient((request) async {
      calls++;
      return http.Response('{}', 500);
    }), storage, 'sb-project-auth-token',
        Uri.parse('https://project.supabase.co'));
    final result = await client.post(
        Uri.parse(
            'https://project.supabase.co/auth/v1/token?grant_type=refresh_token'),
        body: jsonEncode({'refresh_token': 'old'}));
    expect(result.statusCode, 200);
    expect(jsonDecode(result.body)['refresh_token'], 'rotated');
    expect(calls, 0);
    client.close();
  });

  test('successful refresh persists the SDK session before releasing lock',
      () async {
    final storage = MemorySessionStorage(jsonEncode(fixtures.session('aal2')));
    final next = fixtures.session('aal2')..['refresh_token'] = 'rotated';
    final client = CoordinatedAuthClient(
        MockClient((request) async => http.Response(jsonEncode(next), 200)),
        storage,
        'sb-project-auth-token',
        Uri.parse('https://project.supabase.co'));
    final result = await client.post(
        Uri.parse(
            'https://project.supabase.co/auth/v1/token?grant_type=refresh_token'),
        body: jsonEncode({'refresh_token': 'synthetic-refresh-token'}));
    expect(result.statusCode, 200);
    expect(jsonDecode(storage.value!)['refresh_token'], 'rotated');
    client.close();
  });

  test('logout during refresh cannot repersist credentials', () async {
    final response = Completer<http.Response>();
    final sent = Completer<void>();
    final storage = MemorySessionStorage(jsonEncode(fixtures.session('aal2')));
    final client = CoordinatedAuthClient(MockClient((request) {
      sent.complete();
      return response.future;
    }), storage, 'sb-project-auth-token',
        Uri.parse('https://project.supabase.co'));
    final pending = client.post(
        Uri.parse(
            'https://project.supabase.co/auth/v1/token?grant_type=refresh_token'),
        body: jsonEncode({'refresh_token': 'synthetic-refresh-token'}));
    await sent.future;
    await storage.removePersistedSession();
    response.complete(http.Response(jsonEncode(fixtures.session('aal2')), 200));
    expect((await pending).statusCode, 400);
    expect(storage.value, isNull);
    client.close();
  });

  test('missing credentials deny refresh, unrelated requests pass through',
      () async {
    var calls = 0;
    final client = CoordinatedAuthClient(MockClient((request) async {
      calls++;
      return http.Response('{}', 201);
    }), MemorySessionStorage(null), 'sb-project-auth-token',
        Uri.parse('https://project.supabase.co'));
    expect(
        (await client.post(
                Uri.parse(
                    'https://project.supabase.co/auth/v1/token?grant_type=refresh_token'),
                body: '{}'))
            .statusCode,
        400);
    expect(
        (await client
                .get(Uri.parse('https://project.supabase.co/rest/v1/accounts')))
            .statusCode,
        201);
    expect(calls, 1);
    client.close();
  });

  test('invalid refresh response never overwrites remembered credentials',
      () async {
    final storage = MemorySessionStorage(jsonEncode(fixtures.session('aal2')));
    final original = storage.value;
    final client = CoordinatedAuthClient(
        MockClient(
            (request) async => http.Response('{"message":"revoked"}', 400)),
        storage,
        'sb-project-auth-token',
        Uri.parse('https://project.supabase.co'));
    expect(
        (await client.post(
                Uri.parse(
                    'https://project.supabase.co/auth/v1/token?grant_type=refresh_token'),
                body: jsonEncode({'refresh_token': 'synthetic-refresh-token'})))
            .statusCode,
        400);
    expect(storage.value, original);
    client.close();
  });
}
