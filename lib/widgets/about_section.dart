import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import 'section_container.dart';

/// "About." section: portrait alongside bio paragraphs.
/// Stacks vertically on narrow layouts.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'About.',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight(900)),
          ),
          const SizedBox(height: AppSpacing.xxxl),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kMobileBreakpoint;
              final portrait = DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(80),
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(80),
                  child: Image.asset(
                    'web/assets/images/benoutdoors.jpg',
                    width: 160,
                    height: 240,
                    fit: BoxFit.cover,
                  ),
                ),
              );
              final bodyLarge = Theme.of(context).textTheme.bodyLarge;
              final text = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final paragraph in PortfolioData.aboutParagraphs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: paragraph.endsWith(PortfolioData.email)
                          ? Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: paragraph.substring(
                                      0,
                                      paragraph.length -
                                          PortfolioData.email.length,
                                    ),
                                  ),
                                  const WidgetSpan(
                                    alignment: PlaceholderAlignment.baseline,
                                    baseline: TextBaseline.alphabetic,
                                    child: _AboutEmailLink(),
                                  ),
                                ],
                              ),
                              style: AppTextStyles.relaxed(bodyLarge),
                            )
                          : Text(
                              paragraph,
                              style: AppTextStyles.relaxed(bodyLarge),
                            ),
                    ),
                ],
              );

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    portrait,
                    const SizedBox(width: AppSpacing.xxxl),
                    Expanded(child: text),
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: portrait),
                  const SizedBox(height: AppSpacing.xl),
                  text,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AboutEmailLink extends StatefulWidget {
  const _AboutEmailLink();

  @override
  State<_AboutEmailLink> createState() => _AboutEmailLinkState();
}

class _AboutEmailLinkState extends State<_AboutEmailLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        hoverColor: Colors.transparent,
        onHover: (hovered) => setState(() => _hovered = hovered),
        onTap: () => launchUrl(
          Uri.parse(PortfolioData.mailtoUrl),
          mode: LaunchMode.externalApplication,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          color: _hovered
              ? AppColors.accent.withValues(alpha: 0.15)
              : Colors.transparent,
          child: Text(
            PortfolioData.email,
            style: AppTextStyles.relaxed(Theme.of(context).textTheme.bodyLarge)
                ?.copyWith(decoration: TextDecoration.underline),
          ),
        ),
      ),
    );
  }
}
