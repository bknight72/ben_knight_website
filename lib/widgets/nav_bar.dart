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

/// Navigation UI for the page header.
class NavBar extends StatelessWidget implements PreferredSizeWidget {
  final void Function(NavSection section) onSectionTap;
  final VoidCallback? onMenuTap;

  const NavBar({
    super.key,
    required this.onSectionTap,
    this.onMenuTap,
  });

  // Toolbar plus the wave beneath it.
  @override
  Size get preferredSize => const Size.fromHeight(64 + NavWave.height);

  bool _isWide(BuildContext context) =>
      MediaQuery.of(context).size.width >= kMobileBreakpoint;

  @override
  Widget build(BuildContext context) {
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
              padding: EdgeInsets.symmetric(
                horizontal: wide ? AppSpacing.xl : AppSpacing.xxxl,
              ),
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
                    IconButton(
                      style:
                          IconButton.styleFrom(overlayColor: AppColors.accent),
                      icon: const SizedBox(
                        width: 28,
                        height: 28,
                        child: CustomPaint(
                          key: ValueKey('mobile-menu-open-icon'),
                          painter: _MenuIconPainter(),
                        ),
                      ),
                      onPressed: onMenuTap,
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
}

class _MenuIconPainter extends CustomPainter {
  const _MenuIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.text
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final y in [6.0, 14.0, 22.0]) {
      canvas.drawLine(Offset(3, y), Offset(size.width - 3, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MenuIconPainter oldDelegate) => false;
}

/// Full-screen mobile navigation, rendered above the page and header.
class MobileNavOverlay extends StatelessWidget {
  final VoidCallback onClose;

  const MobileNavOverlay({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent.withValues(alpha: 0.88),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: AppSpacing.md,
              right: AppSpacing.xxxl,
              child: _MobileCloseButton(onPressed: onClose),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (label, url) in [
                    ('github', PortfolioData.githubUrl),
                    ('linkedin', PortfolioData.linkedinUrl),
                    ('substack', PortfolioData.substackUrl),
                    ('email', PortfolioData.mailtoUrl),
                  ])
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                      child: _MobileMenuLink(
                        label: label,
                        url: url,
                        onClose: onClose,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileMenuLink extends StatefulWidget {
  final String label;
  final String url;
  final VoidCallback onClose;

  const _MobileMenuLink({
    required this.label,
    required this.url,
    required this.onClose,
  });

  @override
  State<_MobileMenuLink> createState() => _MobileMenuLinkState();
}

class _MobileMenuLinkState extends State<_MobileMenuLink> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onHover: (hovered) => setState(() => _isHovered = hovered),
      onPressed: () {
        widget.onClose();
        _launchUrl(widget.url);
      },
      style: TextButton.styleFrom(overlayColor: Colors.transparent),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedDefaultTextStyle(
              key: ValueKey('mobile-menu-style-${widget.label}'),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: _isHovered ? Colors.white : AppColors.text,
                    decoration: TextDecoration.none,
                  ),
              child: Text(widget.label),
            ),
            const SizedBox(height: 2),
            AnimatedContainer(
              key: ValueKey('mobile-menu-underline-${widget.label}'),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              height: 2,
              color: _isHovered ? Colors.white : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileCloseButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _MobileCloseButton({required this.onPressed});

  @override
  State<_MobileCloseButton> createState() => _MobileCloseButtonState();
}

class _MobileCloseButtonState extends State<_MobileCloseButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onHover: (hovered) => setState(() => _isHovered = hovered),
      onPressed: widget.onPressed,
      style: IconButton.styleFrom(overlayColor: Colors.transparent),
      icon: TweenAnimationBuilder<Color?>(
        key: const ValueKey('mobile-menu-close-color'),
        tween: ColorTween(end: _isHovered ? Colors.white : AppColors.text),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        builder: (context, color, child) => SizedBox(
          width: 28,
          height: 28,
          child: CustomPaint(
            painter: _CloseIconPainter(color ?? AppColors.text),
          ),
        ),
      ),
    );
  }
}

class _CloseIconPainter extends CustomPainter {
  final Color color;

  const _CloseIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        const Offset(3, 3), Offset(size.width - 3, size.height - 3), paint);
    canvas.drawLine(
        Offset(size.width - 3, 3), Offset(3, size.height - 3), paint);
  }

  @override
  bool shouldRepaint(covariant _CloseIconPainter oldDelegate) =>
      oldDelegate.color != color;
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
