import 'package:flutter/material.dart';
import 'app.dart';
import 'config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(BudgetApp(config: await AppConfig.load()));
  } catch (_) {
    runApp(const BudgetApp(configurationError: true));
  }
}
