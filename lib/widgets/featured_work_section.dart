import 'package:flutter/material.dart';

import '../data/portfolio_data.dart';
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
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kMobileBreakpoint;
              final columns = wide ? 3 : 1;
              const spacing = 24.0;
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
