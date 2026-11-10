Future<String?> pickCsv() async => null;
Future<void> download(String name, String content) async {}
Future<bool> linkStripe(String key, String secret) async =>
    throw UnsupportedError('Financial Connections requires a web browser.');
void clearStripe() {}
void clearAuthUrl() {}
