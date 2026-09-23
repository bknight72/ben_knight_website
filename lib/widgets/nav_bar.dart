import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import 'nav_wave.dart';

/// Identifies a scrollable section that the nav can jump to.
enum NavSection { about, work, experience, skills, contact }

Future<void> _launchUrl(String url) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

ButtonStyle _hireMeButtonStyle(BuildContext context) => TextButton.styleFrom(
      overlayColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      backgroundColor: Colors.white,
      foregroundColor: AppColors.accent,
      side: const BorderSide(
        color: AppColors.accent,
        width: 2.0,
      ),
      shape: const StadiumBorder(),
      fixedSize: const Size(120, 40),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
    );

/// Navigation UI for the page header and its compact-layout drawer.
class NavBar extends StatelessWidget implements PreferredSizeWidget {
  final void Function(NavSection section) onSectionTap;
  final bool showAsDrawer;

  const NavBar({
    super.key,
    required this.onSectionTap,
    this.showAsDrawer = false,
  });

  // Toolbar plus the wave beneath it.
  @override
  Size get preferredSize => const Size.fromHeight(64 + NavWave.height);

  bool _isWide(BuildContext context) =>
      MediaQuery.of(context).size.width >= kMobileBreakpoint;

  @override
  Widget build(BuildContext context) {
    if (showAsDrawer) return _buildDrawer();

    final wide = _isWide(context);

    return ClipPath(
      clipper: const NavWaveClipper(),
      child: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        toolbarHeight: 64,
        // Center the brand + actions within a 600px column (matching the
        // site's other content columns) instead of letting them spread across
        // the full browser width.
        title: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Row(
                children: [
                  Text(
                    PortfolioData.name,
                    style: AppTextStyles.navBrand,
                  ),
                  const Spacer(),
                  if (wide) ...[
                    const _SocialIconRow(),
                    const SizedBox(width: AppSpacing.lg),
                    const _HireMeButton(),
                  ] else
                    Builder(
                      builder: (context) => IconButton(
                        icon: const Icon(Icons.menu),
                        tooltip: 'Open navigation menu',
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // A shallow repeating wave replaces the straight bottom border.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(NavWave.height),
          child: const SizedBox(
            height: NavWave.height,
            width: double.infinity,
            child: CustomPaint(painter: NavWavePainter()),
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer() {
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
            ListTile(
              title: const Text(
                'github',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () => _launchUrl(PortfolioData.githubUrl),
            ),
            ListTile(
              title: const Text(
                'linkedin',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () => _launchUrl(PortfolioData.linkedinUrl),
            ),
            ListTile(
              title: const Text(
                'substack',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () => _launchUrl(PortfolioData.substackUrl),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: const _HireMeButton(),
            ),
          ],
        ),
      ),
    );
  }
}

class _HireMeButton extends StatefulWidget {
  const _HireMeButton();

  @override
  State<_HireMeButton> createState() => _HireMeButtonState();
}

class _HireMeButtonState extends State<_HireMeButton> {
  static const _shadowOffset = 5.0;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: SizedBox(
        width: 120 + _shadowOffset,
        height: 40 + _shadowOffset,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              left: _isHovered ? 0 : _shadowOffset,
              top: _isHovered ? 0 : _shadowOffset,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: const SizedBox(
                  width: 120,
                  height: 40,
                  child: ColoredBox(color: AppColors.accent),
                ),
              ),
            ),
            TextButton(
              style: _hireMeButtonStyle(context),
              onPressed: () => _launchUrl(PortfolioData.mailtoUrl),
              child: const Text('hire me'),
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
        _SocialLink(
          label: 'github',
          url: PortfolioData.githubUrl,
        ),
        _SocialLink(
          label: 'linkedin',
          url: PortfolioData.linkedinUrl,
        ),
        _SocialLink(
          label: 'substack',
          url: PortfolioData.substackUrl,
        ),
      ],
    );
  }
}

class _SocialLink extends StatelessWidget {
  final String label;
  final String url;

  const _SocialLink({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: TextButton(
        onPressed: () => _launchUrl(url),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight(800), color: AppColors.text),
        ),
      ),
    );
  }
}
