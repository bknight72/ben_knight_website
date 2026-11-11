import 'dart:async';
import 'dart:convert';
import 'dart:io';

Map<String, String> validatePublicConfig(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a public configuration JSON object.');
  }
  const allowed = {
    'supabaseUrl',
    'supabasePublishableKey',
    'stripeEnabled',
    'stripePublishableKey',
  };
  final url = value['supabaseUrl'];
  final key = value['supabasePublishableKey'];
  if (value.keys.any((key) => !allowed.contains(key)) ||
      url is! String ||
      !RegExp(r'^https://[a-z0-9]{20}\.supabase\.co$').hasMatch(url) ||
      key is! String ||
      !RegExp(r'^sb_publishable_[A-Za-z0-9_-]{20,}$').hasMatch(key) ||
      RegExp(r'placeholder|your[_-]|example', caseSensitive: false)
          .hasMatch(key)) {
    throw const FormatException(
        'Invalid public configuration; values withheld. Only a hosted Supabase URL and publishable key are accepted.');
  }
  // Do not forward the published manifest's Stripe settings to development.
  return {'SUPABASE_URL': url, 'SUPABASE_PUBLISHABLE_KEY': key};
}

bool isFrontendChange(String path) =>
    path.endsWith('.dart') || path.contains('/web/') || path.endsWith('.yaml');

Future<String> fetch(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 20));
  final response = await request.close().timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw const HttpException('Public configuration could not be downloaded.');
  }
  return response
      .transform(utf8.decoder)
      .join()
      .timeout(const Duration(seconds: 20));
}

Future<void> main() async {
  final client = HttpClient();
  Process? flutter;
  final signals = <StreamSubscription<ProcessSignal>>[];
  Timer? watcher;
  try {
    final local = File('/source/public-config.json');
    final config = validatePublicConfig(jsonDecode(await (local.existsSync()
        ? local.readAsString()
        : fetch(
            client,
            Uri.parse(
                'https://budgeting.benknight.dev/release-config.json')))));
    stdout.writeln('REAL BACKEND: sign in with your existing password and MFA. '
        'Edits affect real records. Stripe is disabled.');
    stdout.writeln(
        'Host Chrome provides browser debugging, not a Dart debugger.');

    // This probe is anonymous and never reads financial data or changes settings.
    try {
      final request = await client
          .openUrl('OPTIONS',
              Uri.parse('${config['SUPABASE_URL']}/functions/v1/api'))
          .timeout(const Duration(seconds: 15));
      request.headers.set('Origin', 'http://localhost:8180');
      request.headers.set('Access-Control-Request-Method', 'GET');
      request.headers.set('Access-Control-Request-Headers',
          'authorization,apikey,content-type');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final allowed = response.headers.value('access-control-allow-origin');
      if (response.statusCode != 204 || allowed != 'http://localhost:8180') {
        stderr.writeln('BACKEND CORS WARNING: Edge features may be blocked. '
            'Add http://localhost:8180 to ALLOWED_ORIGINS while retaining the production origin. '
            'Password/MFA and direct ledger reads use separate Supabase services.');
      }
      await response.drain<void>();
    } catch (_) {
      stderr.writeln(
          'BACKEND CORS WARNING: could not verify the local Edge origin.');
    }
    client.close(force: true);

    // Generated files stay in a Docker volume, outside the checkout and releases.
    await Directory('/workspace').create(recursive: true);
    await File('/source/pubspec.yaml').copy('/workspace/pubspec.yaml');
    for (final entry in ['lib', 'web', 'config.yaml']) {
      final link = Link('/workspace/$entry');
      if (!await link.exists()) await link.create('/source/$entry');
    }
    final pub = await Process.start('flutter', ['pub', 'get'],
        workingDirectory: '/workspace');
    await Future.wait(
        [stdout.addStream(pub.stdout), stderr.addStream(pub.stderr)]);
    if (await pub.exitCode != 0) {
      throw StateError('Container dependency resolution failed.');
    }

    flutter = await Process.start(
        'flutter',
        [
          'run',
          '-d',
          'web-server',
          '--debug',
          '--no-pub',
          '--web-hostname=0.0.0.0',
          '--web-port=8180',
          '--no-web-resources-cdn',
          '--pid-file=/workspace/flutter.pid',
          for (final entry in config.entries)
            '--dart-define=${entry.key}=${entry.value}',
          '--dart-define=STRIPE_ENABLED=false',
          '--dart-define=STRIPE_PUBLISHABLE_KEY=',
        ],
        workingDirectory: '/workspace');
    final process = flutter;
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signals.add(
          signal.watch().listen((_) => process.kill(ProcessSignal.sigterm)));
    }
    var ready = false;
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stdout.writeln(line);
      if (!ready && line.contains('is being served at http://')) {
        ready = true;
        stdout.writeln('BUDGETING_DEV_READY http://localhost:8180');
        stdout.writeln(
            'Save lib/ or web/ files to reload. Use the Restart UI task if state must be reset.');
      }
    });
    final errors = stderr.addStream(process.stderr);
    // Poll metadata: macOS Docker bind mounts do not reliably forward inotify.
    String fingerprint() {
      final entries = <String>[];
      for (final root in ['/source/lib', '/source/web']) {
        for (final file in Directory(root).listSync(recursive: true)) {
          if (file is! File || !isFrontendChange(file.path)) continue;
          final stat = file.statSync();
          entries.add(
              '${file.path}:${stat.modified.microsecondsSinceEpoch}:${stat.size}');
        }
      }
      entries.sort();
      return entries.join('\n');
    }

    var previous = fingerprint();
    watcher = Timer.periodic(const Duration(milliseconds: 750), (_) {
      try {
        final current = fingerprint();
        if (!ready || current == previous) return;
        previous = current;
        final pidFile = File('/workspace/flutter.pid');
        if (pidFile.existsSync()) {
          final pid = int.tryParse(pidFile.readAsStringSync().trim());
          if (pid != null) Process.killPid(pid, ProcessSignal.sigusr1);
        }
      } on FileSystemException {
        // Editors can replace a file while the metadata scan is in flight.
      }
    });
    exitCode = await process.exitCode;
    await output.cancel();
    await errors;
  } catch (error) {
    stderr.writeln('Failure category: ${error.runtimeType}');
    stderr.writeln(
        'Development startup failed; values withheld. Check Docker logs above, '
        'network/CA trust, or supply BUDGETING_DEV_PUBLIC_CONFIG with only '
        'supabaseUrl and supabasePublishableKey. Never use a backend .env.');
    exitCode = 1;
  } finally {
    watcher?.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
    flutter?.kill(ProcessSignal.sigterm);
    client.close(force: true);
  }
}
