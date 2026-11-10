import 'dart:js_interop';

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
