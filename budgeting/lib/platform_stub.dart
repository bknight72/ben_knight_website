Future<String?> pickCsv() async => null;
Future<void> download(String name, String content) async {}
Future<void> linkStripe(String key, String secret) async =>
    throw UnsupportedError('Financial Connections requires a web browser.');
void clearAuthUrl() {}
