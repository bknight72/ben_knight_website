import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() {
  usePathUrlStrategy();
  runApp(const MyApp());
}

/// Root widget for the portfolio site. All content is placeholder text —
/// see lib/data/portfolio_data.dart to replace it with real content.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ben Knight — Portfolio (Placeholder)',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: const HomeScreen(),
    );
  }
}
