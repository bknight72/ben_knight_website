import 'package:flutter/material.dart';

import '../data/portfolio_data.dart';
import '../theme/app_theme.dart';
import 'section_container.dart';

/// "Skills." section: a wrap of chip widgets, one per placeholder skill.
class SkillsSection extends StatelessWidget {
  const SkillsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Skills.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final skill in PortfolioData.skills)
                Chip(
                  label: Text(skill),
                  backgroundColor: AppColors.placeholderTile,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
