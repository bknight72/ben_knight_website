import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'platform.dart' as platform;

String sessionStorageKey(String url) =>
    'sb-${Uri.parse(url).host.split('.').first}-auth-token';

Future<void> initializeSession(String url, String key) async {
  final storage =
      SharedPreferencesLocalStorage(persistSessionKey: sessionStorageKey(url));
  await storage.initialize();
  final saved = await storage.accessToken();
  if (saved != null) {
    try {
      if (Session.fromJson(jsonDecode(saved)) == null) {
        await storage.removePersistedSession();
      }
    } catch (_) {
      await storage.removePersistedSession();
    }
  }
  await Supabase.initialize(
      url: url,
      publishableKey: key,
      debug: false,
      httpClient: CoordinatedAuthClient(
          http.Client(), storage, sessionStorageKey(url), Uri.parse(url)),
      authOptions: FlutterAuthClientOptions(
          authFlowType: AuthFlowType.implicit,
          detectSessionInUri: false,
          localStorage: storage,
          pkceAsyncStorage: ImplicitAuthStorage()));
  // Initialization launches recovery lazily. Drain its storage-read microtasks
  // before rendering; network refresh remains guarded by SDK session versions.
  await Future<void>.delayed(Duration.zero);
}

// Implicit callbacks are application-owned and never need PKCE storage.
class ImplicitAuthStorage extends GotrueAsyncStorage {
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}

/// The SDK deduplicates within one client and broadcasts rotations, but does
/// not serialize refresh HTTP requests between browser tabs.
class CoordinatedAuthClient extends http.BaseClient {
  final http.Client inner;
  final LocalStorage storage;
  final String storageKey;
  final Uri origin;
  CoordinatedAuthClient(this.inner, this.storage, this.storageKey, this.origin);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != origin.origin ||
        request.url.path != '${origin.path}/auth/v1/token' ||
        request.url.queryParameters['grant_type'] != 'refresh_token' ||
        request is! http.Request) {
      return inner.send(request);
    }
    return platform.withSessionLock(storageKey, () async {
      final token = jsonDecode(request.body)['refresh_token'];
      final saved = await storage.accessToken();
      if (saved == null) return _invalidRefresh(request);
      final current = jsonDecode(saved) as Map<String, dynamic>;
      if (current['refresh_token'] != token) {
        return _response(jsonEncode(current), 200, request);
      }
      final response =
          await http.Response.fromStream(await inner.send(request));
      // Logout in another tab wins over an in-flight refresh, even before the
      // SDK's BroadcastChannel event has reached this tab.
      if (await storage.accessToken() == null) return _invalidRefresh(request);
      if (response.statusCode == 200) {
        final session = Session.fromJson(jsonDecode(response.body));
        if (session != null) {
          await storage.persistSession(jsonEncode(session.toJson()));
        }
      }
      return _response(response.body, response.statusCode, request);
    });
  }

  http.StreamedResponse _invalidRefresh(http.BaseRequest request) => _response(
      '{"message":"Remembered session was signed out.","code":"refresh_token_not_found"}',
      400,
      request);

  http.StreamedResponse _response(
          String body, int status, http.BaseRequest request) =>
      http.StreamedResponse(Stream.value(utf8.encode(body)), status,
          headers: {'content-type': 'application/json'}, request: request);

  @override
  void close() => inner.close();
}
