import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// Identifies a scrollable section that the nav can jump to.
enum NavSection { about, work, experience, skills, contact }

extension NavSectionLabel on NavSection {
  String get label {
    switch (this) {
      case NavSection.about:
        return 'About';
      case NavSection.work:
        return 'Work';
      case NavSection.experience:
        return 'Experience';
      case NavSection.skills:
        return 'Skills';
      case NavSection.contact:
        return 'Contact';
    }
  }
}

Future<void> _launchUrl(String url) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Fixed top navigation bar. On wide layouts it shows inline section links,
/// social icons, and a "hire me" button. On narrow layouts it collapses to
/// a hamburger that opens a [Drawer] with the same links (see [buildDrawer]).
class NavBar extends StatelessWidget implements PreferredSizeWidget {
  final void Function(NavSection section) onSectionTap;

  const NavBar({super.key, required this.onSectionTap});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  bool _isWide(BuildContext context) =>
      MediaQuery.of(context).size.width >= kMobileBreakpoint;

  @override
  Widget build(BuildContext context) {
    final wide = _isWide(context);

    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: AppSpacing.xl,
      title: Text(
        PortfolioData.name,
        style: AppTextStyles.navBrand,
      ),
      actions: wide
          ? [
              for (final section in NavSection.values)
                TextButton(
                  onPressed: () => onSectionTap(section),
                  child: Text(
                    section.label,
                    style: const TextStyle(color: AppColors.text),
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              const _SocialIconRow(),
              const SizedBox(width: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.xl),
                child: ElevatedButton(
                  onPressed: () => _launchUrl(PortfolioData.mailtoUrl),
                  child: const Text('Hire Me'),
                ),
              ),
            ]
          : [
              Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: 'Open navigation menu',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
    );
  }

  /// Drawer shown on narrow layouts, containing the same section links,
  /// social icons, and hire-me action as the wide inline nav.
  static Widget buildDrawer({
    required void Function(NavSection section) onSectionTap,
  }) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  PortfolioData.name,
                  style: AppTextStyles.navBrand.copyWith(fontSize: 22),
                ),
              ),
            ),
            for (final section in NavSection.values)
              ListTile(
                title: Text(section.label),
                onTap: () => onSectionTap(section),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('GitHub'),
              onTap: () => _launchUrl(PortfolioData.githubUrl),
            ),
            ListTile(
              leading: const Icon(Icons.business_center),
              title: const Text('LinkedIn'),
              onTap: () => _launchUrl(PortfolioData.linkedinUrl),
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: const Text('Twitter'),
              onTap: () => _launchUrl(PortfolioData.twitterUrl),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ElevatedButton(
                onPressed: () => _launchUrl(PortfolioData.mailtoUrl),
                child: const Text('Hire Me'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocialIconRow extends StatelessWidget {
  const _SocialIconRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.code),
          tooltip: 'GitHub (placeholder)',
          onPressed: () => _launchUrl(PortfolioData.githubUrl),
        ),
        IconButton(
          icon: const Icon(Icons.business_center),
          tooltip: 'LinkedIn (placeholder)',
          onPressed: () => _launchUrl(PortfolioData.linkedinUrl),
        ),
        IconButton(
          icon: const Icon(Icons.alternate_email),
          tooltip: 'Twitter (placeholder)',
          onPressed: () => _launchUrl(PortfolioData.twitterUrl),
        ),
      ],
    );
  }
}
