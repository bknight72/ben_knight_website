import 'dart:convert';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

/// Synchronous JSON avoids isolate scheduling outside widget-test fake time.
class TestJsonIsolate extends YAJsonIsolate {
  @override
  Future<void> initialize() async {}
  @override
  Future<dynamic> decode(String json) async => jsonDecode(json);
  @override
  Future<String> encode(Object? json) async => jsonEncode(json);
  @override
  Future<void> dispose() async {}
}
