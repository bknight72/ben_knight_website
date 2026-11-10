import 'package:flutter/material.dart';
import 'app.dart';
import 'config.dart';
import 'session.dart';
import 'repository.dart' show supabaseUrl, supabaseKey;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final config = await AppConfig.load();
    if (supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty) {
      try {
        await initializeSession(supabaseUrl, supabaseKey);
      } catch (_) {
        runApp(const BudgetApp(sessionError: true));
        return;
      }
    }
    runApp(BudgetApp(config: config));
  } catch (_) {
    runApp(const BudgetApp(configurationError: true));
  }
}
