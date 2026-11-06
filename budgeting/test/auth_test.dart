import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_budgeting/app.dart';
import 'package:supabase/supabase.dart';
import 'support.dart';

String jwt(String aal) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'HS256', 'typ': 'JWT'})}.${segment({
        'sub': '00000000-0000-4000-8000-000000000001',
        'aal': aal,
        'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        'amr': []
      })}.signature';
}

Map<String, dynamic> session(String aal, {bool factor = true}) => {
      'access_token': jwt(aal),
      'refresh_token': 'synthetic-refresh-token',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-4000-8000-000000000001',
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'owner@example.test',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z',
        'factors': factor
            ? [
                {
                  'id': 'factor-1',
                  'friendly_name': 'Synthetic TOTP',
                  'factor_type': 'totp',
                  'status': 'verified',
                  'created_at': '2026-01-01T00:00:00Z',
                  'updated_at': '2026-01-01T00:00:00Z'
                }
              ]
            : []
      },
    };

void main() {
  testWidgets('password recovery updates password then requires authenticator',
      (tester) async {
    final requests = <http.Request>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(
            authFlowType: AuthFlowType.implicit,
            autoRefreshToken: false), httpClient: MockClient((request) async {
      requests.add(request);
      final result = request.url.path.endsWith('/token')
          ? session('aal1')
          : session('aal1')['user'];
      return http.Response(jsonEncode(result), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    final callback = Uri.parse(
        'https://budgeting.example/#access_token=${jwt('aal1')}&refresh_token=synthetic&expires_in=3600&token_type=bearer&type=recovery');
    await tester.pumpWidget(
        MaterialApp(home: AuthGate(client: client, callbackUri: callback)));
    await tester.pumpAndSettle();
    expect(find.text('Set a new password'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'short');
    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 12 characters.'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).first, 'synthetic-new-password');
    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();
    expect(
        requests.any((r) =>
            r.method == 'PUT' &&
            jsonDecode(r.body)['password'] == 'synthetic-new-password'),
        isTrue);
    expect(find.text('Authenticator code'), findsOneWidget);
    expect(find.text('TRACKED NET POSITION'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'recovery email is sent to the owner address without exposing a signup action',
      (tester) async {
    http.Request? sent;
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(
            autoRefreshToken: false, authFlowType: AuthFlowType.implicit),
        httpClient: MockClient((request) async {
      sent = request;
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'owner@example.test');
    await tester.tap(find.text('Send recovery email'));
    await tester.pumpAndSettle();
    expect(sent?.url.path, '/auth/v1/recover');
    expect(jsonDecode(sent!.body)['email'], 'owner@example.test');
    expect(find.text('Check your email for a password reset link.'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'MFA protected workspace clears dialogs and loaded balances on session loss',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      Object result;
      if (request.url.path.endsWith('/token')) {
        result = session('aal2');
      } else if (request.url.path.endsWith('/is_budget_owner')) {
        result = true;
      } else if (request.url.path.endsWith('/logout')) {
        result = {};
      } else if (request.url.path.endsWith('/usage')) {
        result = {
          'month': '2026-11',
          'reservedAttempts': 0,
          'limit': 50,
          'remainingAttempts': 50,
          'accounts': []
        };
      } else {
        result = [];
      }
      return http.Response(jsonEncode(result), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'owner@example.test');
    await tester.enterText(find.byType(TextField).last, 'synthetic-password');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Your ledger starts here'), findsOneWidget);
    await tester.tap(find.text('Add your first account'));
    await tester.pumpAndSettle();
    expect(find.text('Add a manual account'), findsOneWidget);
    await client.auth.signOut(scope: SignOutScope.local);
    await tester.pumpAndSettle();
    expect(find.text('Add a manual account'), findsNothing);
    expect(find.text('TRACKED NET POSITION'), findsNothing);
    expect(find.text('Welcome to your ledger.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('password login requires TOTP and rejects wrong owner after MFA',
      (tester) async {
    final calls = <String>[];
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      calls.add(request.url.path);
      Object response;
      if (request.url.path.endsWith('/token')) {
        response = session('aal1');
      } else if (request.url.path.endsWith('/challenge')) {
        response = {
          'id': 'challenge-1',
          'type': 'totp',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60
        };
      } else if (request.url.path.endsWith('/verify')) {
        response = session('aal2');
      } else if (request.url.path.endsWith('/is_budget_owner')) {
        response = false;
      } else {
        response = {};
      }
      return http.Response(jsonEncode(response), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'owner@example.test');
    await tester.enterText(find.byType(TextField).last, 'synthetic-password');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Authenticator code'), findsOneWidget);
    expect(find.text('TRACKED NET POSITION'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.text('Verify and continue'));
    await tester.pumpAndSettle();
    expect(find.text('This identity is not the provisioned ledger owner.'),
        findsOneWidget);
    expect(calls, contains('/auth/v1/factors/factor-1/challenge'));
    expect(calls, contains('/rest/v1/rpc/is_budget_owner'));
    expect(calls.any((path) => path.endsWith('/accounts')), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('enrollment exposes TOTP setup and validates six digit code',
      (tester) async {
    final client = SupabaseClient('https://example.supabase.co', 'public-key',
        isolate: TestJsonIsolate(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      final Object result = request.url.path.endsWith('/token')
          ? session('aal1', factor: false)
          : {
              'id': 'new-factor',
              'type': 'totp',
              'totp': {
                'qr_code':
                    '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20"/></svg>',
                'secret': 'SYNTHETICSETUPKEY',
                'uri': 'otpauth://totp/Synthetic?secret=SYNTHETICSETUPKEY'
              },
            };
      return http.Response(jsonEncode(result), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await tester.pumpWidget(MaterialApp(home: AuthGate(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'owner@example.test');
    await tester.enterText(find.byType(TextField).last, 'synthetic-password');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '));
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'SYNTHETICSETUPKEY');
    await tester.ensureVisible(find.text('Verify and continue'));
    await tester.tap(find.text('Verify and continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a six-digit code.'), findsOneWidget);
    await tester.ensureVisible(find.text('Back to sign in'));
    await tester.tap(find.text('Back to sign in'));
    await tester.pumpAndSettle();
    expect(find.text('SYNTHETICSETUPKEY'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
