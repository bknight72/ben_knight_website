import 'dart:js_interop';

@JS('budgetBridge.pickCsv')
external JSPromise<JSString?> _pickCsv();
@JS('budgetBridge.download')
external void _download(JSString name, JSString content);
@JS('budgetBridge.linkStripe')
external JSPromise<JSAny?> _linkStripe(JSString key, JSString secret);
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
Future<void> linkStripe(String key, String secret) async {
  try {
    await _linkStripe(key.toJS, secret.toJS).toDart;
  } catch (_) {
    throw const FormatException(
        'Bank connection was cancelled or failed. No connection was completed.');
  }
}

void clearAuthUrl() => _clearAuthUrl();
