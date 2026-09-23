import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import 'hero_ascii_art.dart';
import 'section_container.dart';

/// Hero/intro section: animated ASCII-art wordmark in place of a plain text
/// headline, subtext, and a plain underlined email CTA — mirrors the
/// reference site's landing block.
class HeroSection extends StatefulWidget {
  const HeroSection({super.key});

  @override
  State<HeroSection> createState() => _HeroSectionState();
}

class _HeroSectionState extends State<HeroSection> {
  bool _emailHovered = false;

  @override
  Widget build(BuildContext context) {
    const emailRadius = BorderRadius.all(Radius.circular(30));

    return SectionContainer(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.hero),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: HeroAsciiArt(),
          ),
          const SizedBox(height: AppSpacing.xxxl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth / 2),
              child: Text(
                PortfolioData.heroSubtext,
                textAlign: TextAlign.justify,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight(400)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              decoration: BoxDecoration(
                color: _emailHovered ? AppColors.accent : Colors.white,
                borderRadius: emailRadius,
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: emailRadius,
                  hoverColor: Colors.transparent,
                  onHover: (hovered) => setState(() => _emailHovered = hovered),
                  onTap: () => launchUrl(
                    Uri.parse(PortfolioData.mailtoUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                      style: Theme.of(context).textTheme.bodyLarge!.merge(
                            AppTextStyles.emailCta.copyWith(
                              color:
                                  _emailHovered ? Colors.white : Colors.black,
                              decorationColor:
                                  _emailHovered ? Colors.white : Colors.black,
                            ),
                          ),
                      child: const Text(PortfolioData.email),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
