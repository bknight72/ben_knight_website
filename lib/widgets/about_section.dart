import 'package:flutter/material.dart';

import '../data/portfolio_data.dart';
import '../theme/app_theme.dart';
import 'section_container.dart';

/// "About." section: placeholder avatar alongside placeholder bio
/// paragraphs. Stacks vertically on narrow layouts.
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
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kMobileBreakpoint;
              final avatar = Container(
                width: 140,
                height: 140,
                decoration: const BoxDecoration(
                  color: AppColors.placeholderTile,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_outline,
                  size: 64,
                  color: Colors.black38,
                ),
              );
              final text = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final paragraph in PortfolioData.aboutParagraphs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        paragraph,
                        style: const TextStyle(height: 1.5),
                      ),
                    ),
                ],
              );

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    avatar,
                    const SizedBox(width: 32),
                    Expanded(child: text),
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: avatar),
                  const SizedBox(height: 24),
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
