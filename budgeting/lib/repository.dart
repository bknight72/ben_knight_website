import 'package:supabase/supabase.dart';
import 'domain.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const stripeKey = String.fromEnvironment('STRIPE_PUBLISHABLE_KEY');
const stripeEnabled = bool.fromEnvironment('STRIPE_ENABLED');

class LedgerRepository {
  final SupabaseClient client;
  LedgerRepository(this.client);

  String? get authenticatedOwner {
    final session = client.auth.currentSession;
    if (session == null ||
        session.isExpired ||
        client.auth.mfa.getAuthenticatorAssuranceLevel().currentLevel?.name !=
            'aal2') {
      return null;
    }
    return session.user.id;
  }

  Future<void> requireOwnerSession(String? owner) async {
    if (owner == null ||
        authenticatedOwner != owner ||
        await client.rpc('is_budget_owner') != true ||
        authenticatedOwner != owner) {
      throw const FormatException(
          'Your owner/MFA session changed. Sign in again before completing the connection.');
    }
  }

  Future<List<Json>> pendingConnections() async {
    final result = await api('connections/pending', get: true);
    final sessions = result['sessions'];
    if (sessions is! List ||
        sessions.any((s) =>
            s is! Map ||
            s['sessionId'] is! String ||
            s['createdAt'] is! String ||
            s['status'] is! String)) {
      throw const FormatException('Pending connections could not be loaded.');
    }
    return sessions.map((s) => Map<String, dynamic>.from(s as Map)).toList();
  }

  Future<Json> completeConnection(String sessionId, String? owner) async {
    await requireOwnerSession(owner);
    final result =
        await api('connections/complete', body: {'sessionId': sessionId});
    await requireOwnerSession(owner);
    if (result['accountIds'] is! List || result['status'] != 'queued') {
      throw const FormatException(
          'Completion could not be confirmed. Retry this pending connection, not a new link.');
    }
    return result;
  }

  Future<Json> api(String path, {Json? body, bool get = false}) async {
    try {
      final response = await client.functions.invoke('api/api/v1/$path',
          method: get ? HttpMethod.get : HttpMethod.post,
          body: get ? null : body ?? <String, dynamic>{});
      if (response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
      throw const FormatException(
          'The service returned an unexpected response.');
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map &&
          details['code'] is String &&
          details['message'] is String) {
        final retry = details['retryAt'];
        throw FormatException(
            '${details['message']}${retry == null ? '' : ' Try again after $retry.'}');
      }
      rethrow;
    }
  }

  Future<List<Json>> rows(String table) async {
    final result = <Json>[];
    // PostgREST's default row cap must not silently truncate monthly totals.
    for (var start = 0;; start += 500) {
      final page = await client
          .from(table)
          .select()
          .order(
            table == 'profiles'
                ? 'owner_id'
                : table == 'transaction_annotations'
                    ? 'transaction_id'
                    : 'id',
            ascending: true,
          )
          .range(start, start + 499);
      result.addAll(List<Json>.from(page));
      if (page.length < 500) return result;
    }
  }
}
