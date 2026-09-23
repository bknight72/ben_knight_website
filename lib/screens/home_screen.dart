import 'package:flutter/material.dart';

import '../widgets/about_section.dart';
import '../widgets/featured_work_section.dart';
import '../widgets/footer_section.dart';
import '../widgets/hero_section.dart';
import '../widgets/nav_bar.dart';

/// Assembles the whole single-page portfolio: fixed nav, then a vertically
/// scrolling column of sections. Owns the [GlobalKey]s used to scroll to
/// each section when a nav link is tapped.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _aboutKey = GlobalKey();
  final _workKey = GlobalKey();
  final _experienceKey = GlobalKey();
  final _skillsKey = GlobalKey();
  final _contactKey = GlobalKey();

  GlobalKey _keyFor(NavSection section) {
    switch (section) {
      case NavSection.about:
        return _aboutKey;
      case NavSection.work:
        return _workKey;
      case NavSection.experience:
        return _experienceKey;
      case NavSection.skills:
        return _skillsKey;
      case NavSection.contact:
        return _contactKey;
    }
  }

  void _scrollToSection(NavSection section) {
    final context = _keyFor(section).currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final navBar = NavBar(onSectionTap: _scrollToSection);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: navBar,
      drawer: NavBar(
          onSectionTap: (section) {
            Navigator.of(context).pop();
            // Wait for the drawer's close animation before scrolling so
            // ensureVisible measures the final (unobscured) layout.
            Future.delayed(
              const Duration(milliseconds: 250),
              () => _scrollToSection(section),
            );
          },
          showAsDrawer: true),
      body: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(
              height: MediaQuery.paddingOf(context).top +
                  navBar.preferredSize.height,
            ),
            const HeroSection(),
            KeyedSubtree(key: _workKey, child: const FeaturedWorkSection()),
            KeyedSubtree(key: _aboutKey, child: const AboutSection()),
            const FooterSection(),
          ],
        ),
      ),
    );
  }
}
