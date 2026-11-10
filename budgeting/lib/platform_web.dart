import 'dart:js_interop';
import 'package:web/web.dart' as web;

@JS('budgetBridge.pickCsv')
external JSPromise<JSString?> _pickCsv();
@JS('budgetBridge.download')
external void _download(JSString name, JSString content);
@JS('budgetBridge.linkStripe')
external JSPromise<JSString> _linkStripe(JSString key, JSString secret);
@JS('budgetBridge.clearStripe')
external void _clearStripe();
@JS('budgetBridge.clearAuthUrl')
external void _clearAuthUrl();

Future<String?> pickCsv() async {
  try {
    return (await _pickCsv().toDart)?.toDart;
  } catch (_) {
    throw const FormatException(
        'CSV could not be read. Choose a readable file no larger than 5 MB.');
  }
}

Future<void> download(String name, String content) async =>
    _download(name.toJS, content.toJS);
Future<bool> linkStripe(String key, String secret) async {
  String result;
  try {
    result = (await _linkStripe(key.toJS, secret.toJS).toDart).toDart;
  } catch (_) {
    throw const FormatException(
        'The bank connection could not be completed. Check pending connections before starting another link.');
  }
  if (result == 'cancelled') return false;
  if (result == 'load_failed') {
    throw const FormatException(
        'Stripe could not load. Check your connection or browser blocking settings, then try again.');
  }
  if (result != 'completed') {
    throw const FormatException(
        'The bank connection failed. Check pending connections before starting another link.');
  }
  return true;
}

void clearAuthUrl() => _clearAuthUrl();
void clearStripe() => _clearStripe();

Future<T> withSessionLock<T>(String key, Future<T> Function() action) async {
  // Web Locks have no persistent metadata and are released when a tab closes.
  // Unsupported browsers fail closed rather than race rotating refresh tokens.
  if (!web.window.isSecureContext) {
    throw const FormatException('Remembered sessions require HTTPS.');
  }
  late T result;
  await web.window.navigator.locks
      .request(
          '$key-refresh',
          ((web.Lock? lock) {
            return (() async {
              result = await action();
              return null;
            })()
                .toJS;
          }).toJS)
      .toDart;
  return result;
}
