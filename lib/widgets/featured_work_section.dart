import 'package:flutter/material.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'project_card.dart';
import 'section_container.dart';

/// "Featured Work." section: heading followed by a responsive grid of
/// [ProjectCard]s (single column on narrow width, multi-column on wide).
class FeaturedWorkSection extends StatelessWidget {
  const FeaturedWorkSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Featured Work.',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight(900)),
          ),
          const SizedBox(height: AppSpacing.xxxl),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kMobileBreakpoint;
              final columns = wide ? 2 : 1;
              const spacing = AppSpacing.xl;
              final itemWidth =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;

              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final project in PortfolioData.projects)
                    SizedBox(
                      width: itemWidth,
                      child: ProjectCard(project: project),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
