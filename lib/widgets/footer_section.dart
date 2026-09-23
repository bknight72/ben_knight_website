import 'package:flutter/material.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import 'nav_wave.dart';
import 'section_container.dart';

/// Dark footer with repeated social links and copyright/placeholder notice.
/// Always at the bottom of the page; not a nav scroll target.
class FooterSection extends StatelessWidget {
  const FooterSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: const NavWaveClipper(topEdge: true),
      child: CustomPaint(
        foregroundPainter: const NavWavePainter(topEdge: true),
        child: SectionContainer(
          backgroundColor: AppColors.darkAccent,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.xxxl,
          ),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sm),
              Text(
                PortfolioData.footerText,
                textAlign: TextAlign.center,
                style: AppTextStyles.footerCaption,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
