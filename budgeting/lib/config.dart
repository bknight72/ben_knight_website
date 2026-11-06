import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

const maxImportBytes = 5242880;
const maxImportRows = 10000;

class AppConfig {
  final String currency;
  final String reportingTimezone;
  final bool stripeAllowed;
  const AppConfig(
      {this.currency = 'USD',
      this.reportingTimezone = 'America/Denver',
      this.stripeAllowed = false});

  factory AppConfig.parse(String text) {
    final Object? value;
    try {
      value = loadYaml(text);
    } on YamlException {
      throw const FormatException('Public configuration is not valid YAML.');
    }
    if (value is! YamlMap ||
        value['currency'] != 'USD' ||
        value['reporting_timezone'] != 'America/Denver' ||
        value['budget_rollover'] != false ||
        value['max_import_bytes'] != maxImportBytes ||
        value['max_import_rows'] != maxImportRows ||
        value['stripe_enabled'] is! bool) {
      throw const FormatException(
          'Public configuration must use USD, America/Denver, no rollover, and supported import limits.');
    }
    const allowed = {
      'currency',
      'reporting_timezone',
      'supported_reporting_timezones',
      'budget_rollover',
      'max_import_bytes',
      'max_import_rows',
      'stripe_enabled',
      'builder'
    };
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException(
          'Public configuration contains unsupported keys. Never put credentials in config.yaml.');
    }
    final zones = value['supported_reporting_timezones'];
    if (zones is! YamlList ||
        zones.length != 1 ||
        zones.single != 'America/Denver') {
      throw const FormatException(
          'Only America/Denver reporting is supported.');
    }
    return AppConfig(
        currency: value['currency'] as String,
        reportingTimezone: value['reporting_timezone'] as String,
        stripeAllowed: value['stripe_enabled'] as bool);
  }

  static Future<AppConfig> load({AssetBundle? bundle}) async =>
      AppConfig.parse(await (bundle ?? rootBundle).loadString('config.yaml'));
}
