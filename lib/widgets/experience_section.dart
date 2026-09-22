import 'package:flutter/material.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'section_container.dart';

/// "Experience." section: vertical list of role/company/date cards, each
/// with placeholder achievement bullets.
class ExperienceSection extends StatelessWidget {
  const ExperienceSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Experience.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: AppSpacing.xxxl),
          for (final entry in PortfolioData.experience)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpacing.md,
                    children: [
                      Text(
                        entry.role,
                        style: AppTextStyles.experienceRole,
                      ),
                      Text(
                        '· ${entry.company}',
                        style: AppTextStyles.experienceMeta,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    entry.dateRange,
                    style: AppTextStyles.experienceDate,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final bullet in entry.bullets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('•  '),
                          Expanded(child: Text(bullet)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
