import 'package:supabase/supabase.dart';
import 'domain.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const stripeKey = String.fromEnvironment('STRIPE_PUBLISHABLE_KEY');
const stripeEnabled = bool.fromEnvironment('STRIPE_ENABLED');

class LedgerRepository {
  final SupabaseClient client;
  LedgerRepository(this.client);

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
