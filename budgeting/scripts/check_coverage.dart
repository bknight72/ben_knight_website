import 'dart:io';

// Every executable line in the selected LCOV report counts toward the gate.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'Usage: check_coverage.dart report.lcov [required-source-suffix ...]');
    exitCode = 1;
    return;
  }
  final lines = File(args.first).readAsLinesSync();
  final sources = <String>{};
  var found = 0;
  var hit = 0;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      sources.add(line.substring(3).replaceAll('\\', '/'));
    }
    if (line.startsWith('DA:')) {
      found++;
      if (int.parse(line.split(',')[1]) > 0) hit++;
    }
  }
  for (final required in args.skip(1)) {
    if (!sources.any((source) => source.endsWith(required))) {
      stderr.writeln('Missing required production coverage: $required');
      exitCode = 1;
    }
  }
  // VM tests cannot instrument the browser-only interop adapter. Count every
  // nonblank, non-comment line of any omitted library as uncovered, rather than
  // silently dropping it from the denominator (a conservative upper bound).
  if (args.first.endsWith('/lcov.info')) {
    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final path = file.path.replaceAll('\\', '/');
      if (sources.any((source) => source.endsWith(path))) continue;
      final missing = file.readAsLinesSync().where((line) {
        final text = line.trim();
        return text.isNotEmpty && !text.startsWith('//');
      }).length;
      found += missing;
      stdout.writeln('Uninstrumented $path: $missing lines counted uncovered.');
    }
  }
  final coverage = found == 0 ? 0 : hit / found;
  stdout.writeln(
      'Line coverage: ${(coverage * 100).toStringAsFixed(1)}% ($hit/$found)');
  if (coverage < .7) exitCode = 1;
}
