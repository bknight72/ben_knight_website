import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/config.dart';
import 'package:private_budgeting/domain.dart';
import 'package:private_budgeting/repository.dart';
import 'workspace_test.dart' show FixtureRepository;

class LinkingRepository extends FixtureRepository {
  List<Json> pending = [];
  final calls = <String>[];
  String? owner = 'owner';
  bool pendingFails = false;
  bool completionFails = false;
  Json completion = {
    'accountIds': ['a'],
    'status': 'queued'
  };
  String? syncError;
  String state = 'active';

  LinkingRepository() : super(stripe: true);

  @override
  String? get authenticatedOwner => owner;

  @override
  Future<void> requireOwnerSession(String? expected) async {
    if (expected == null || expected != owner) {
      throw const FormatException('Owner/MFA session changed. Sign in again.');
    }
  }

  @override
  Future<Json> api(String path, {Json? body, bool get = false}) async {
    calls.add(path);
    if (path == 'connections/pending') {
      if (pendingFails) throw Exception('private error');
      return {'sessions': pending};
    }
    if (path == 'connections/session') {
      pending = [
        {
          'sessionId': 'fcsess_original',
          'createdAt': '2026-11-10',
          'status': 'pending'
        }
      ];
      return {
        'sessionId': 'fcsess_original',
        'clientSecret': 'transient-secret'
      };
    }
    if (path == 'connections/complete') {
      expect(body, {'sessionId': 'fcsess_original'});
      if (completionFails) {
        throw const FormatException('Completion unavailable. Retry later.');
      }
      pending = [];
      return completion;
    }
    return super.api(path, body: body, get: get);
  }

  @override
  Future<List<Json>> rows(String table) async {
    final result = await super.rows(table);
    if (table == 'accounts') {
      result.first.addAll({'connection_state': state, 'sync_error': syncError});
    }
    return result;
  }
}

Future<void> mountLinking(WidgetTester tester, LinkingRepository repo,
    {bool mobile = false, Future<bool> Function(String, String)? modal}) async {
  tester.view.physicalSize = Size(mobile ? 390 : 1440, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(repo.client.dispose);
  await tester.pumpWidget(MaterialApp(
      home: LedgerShell(
    repository: repo,
    onLogout: () async {},
    config: const AppConfig(stripeAllowed: true),
    linkBank: modal ?? ((_, __) async => true),
  )));
  await tester.pumpAndSettle();
  if (mobile) {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Accounts'));
  await tester.pumpAndSettle();
}

void main() {
  test('queued and partial completion do not claim confirmed feeds', () {
    expect(
        completionMessage({'status': 'queued'}), contains('not yet confirmed'));
    expect(
        completionMessage({
          'accountStatuses': [
            {'status': 'active'},
            {'status': 'failed'}
          ]
        }),
        contains('partial or pending'));
  });

  testWidgets(
      'pending connections do not render a section or retry controls on mobile',
      (tester) async {
    final repo = LinkingRepository()
      ..pending = [
        {
          'sessionId': 'fcsess_original',
          'createdAt': '2026-11-10',
          'status': 'processing'
        }
      ]
      ..completionFails = true;
    await mountLinking(tester, repo, mobile: true);
    expect(find.text('Unfinished bank connections'), findsNothing);
    expect(find.text('Retry completion'), findsNothing);
    expect(find.textContaining('2026-11-10 / processing'), findsNothing);
    expect(find.text('Connect bank'), findsOneWidget);
    expect(repo.calls, isNot(contains('connections/complete')));
    expect(repo.calls, isNot(contains('connections/session')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending load failure disables new links without hiding accounts',
      (tester) async {
    final repo = LinkingRepository()..pendingFails = true;
    await mountLinking(tester, repo);
    expect(find.textContaining('Pending connections could not be loaded'),
        findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Connect bank'))
            .onPressed,
        isNull);
    expect(find.text('Synthetic checking'), findsOneWidget);
    expect(find.textContaining('private error'), findsNothing);
  });

  for (final error in [
    'connection_inactive',
    'balance_not_ready',
    'balance_unavailable',
    'retry_exhausted',
    'subscription_pending'
  ]) {
    testWidgets('account status is explicit: $error', (tester) async {
      final repo = LinkingRepository()
        ..syncError = error
        ..state = error == 'connection_inactive' ? 'error' : 'active';
      await mountLinking(tester, repo);
      expect(
          find.text(connectionState(
              {'sync_error': error, 'connection_state': repo.state})),
          findsOneWidget);
      if (error == 'connection_inactive' || error == 'balance_not_ready') {
        expect(
            tester
                .widget<OutlinedButton>(
                    find.widgetWithText(OutlinedButton, 'Request paid refresh'))
                .onPressed,
            isNull);
      }
    });
  }

  testWidgets(
      'disconnect cleanup remains retryable and warns about ongoing charges',
      (tester) async {
    await mountLinking(tester, LinkingRepository()..state = 'disconnecting');
    expect(find.textContaining('may continue charging'), findsOneWidget);
    expect(find.text('Retry disconnect'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Request paid refresh'))
            .onPressed,
        isNull);
  });

  testWidgets(
      'exhausted feed recovery confirms cost and never creates a new link',
      (tester) async {
    final repo = LinkingRepository()..syncError = 'retry_exhausted';
    await mountLinking(tester, repo);
    await tester.tap(find.text('Retry transaction subscription'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ongoing charges'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('accounts/a/subscription-retry'));
    expect(repo.calls, isNot(contains('connections/session')));
    expect(find.textContaining('recovery queued, not yet confirmed'),
        findsOneWidget);
  });

  if (stripeEnabled && stripeKey.isNotEmpty) {
    for (final outcome in [
      'completed',
      'cancelled',
      'load_failed',
      'auth_lost'
    ]) {
      testWidgets('modal outcome $outcome preserves completion boundaries',
          (tester) async {
        final repo = LinkingRepository();
        final modal = Completer<bool>();
        await mountLinking(tester, repo, modal: (key, secret) {
          expect(secret, 'transient-secret');
          return modal.future;
        });
        await tester.tap(find.text('Connect bank'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pump();
        expect(find.text('Waiting for bank consent...'), findsOneWidget);
        if (outcome == 'auth_lost') repo.owner = null;
        if (outcome == 'load_failed') {
          modal.completeError(const FormatException('Stripe could not load.'));
        } else {
          modal.complete(outcome != 'cancelled');
        }
        await tester.pumpAndSettle();
        expect(repo.calls.where((p) => p == 'connections/complete').length,
            outcome == 'completed' ? 1 : 0);
        expect(find.textContaining('not yet confirmed'),
            outcome == 'completed' ? findsOneWidget : findsNothing);
        expect(find.text('Unfinished bank connections'), findsNothing);
        expect(find.text('Retry completion'), findsNothing);
        expect(find.textContaining('transient-secret'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
