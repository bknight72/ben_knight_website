import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'section_container.dart';

/// Text-only hero/intro section: bold headline, subtext, and a plain
/// underlined email CTA — mirrors the reference site's landing block.
class HeroSection extends StatelessWidget {
  const HeroSection({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SectionContainer(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.hero,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              PortfolioData.heroHeadline,
              style: textTheme.headlineMedium,
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              PortfolioData.heroSubtext,
              style: textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w300,
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            InkWell(
              onTap: () => launchUrl(
                Uri.parse(PortfolioData.mailtoUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(
                PortfolioData.email,
                style: AppTextStyles.emailCta,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
