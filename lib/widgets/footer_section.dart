import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import '../theme/app_theme.dart';
import 'section_container.dart';

/// Dark footer with repeated social links and copyright/placeholder notice.
/// Always at the bottom of the page; not a nav scroll target.
class FooterSection extends StatelessWidget {
  const FooterSection({super.key});

  Future<void> _launch(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    return SectionContainer(
      backgroundColor: AppColors.darkAccent,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.code, color: Colors.white),
                tooltip: 'GitHub (placeholder)',
                onPressed: () => _launch(PortfolioData.githubUrl),
              ),
              IconButton(
                icon: const Icon(Icons.business_center, color: Colors.white),
                tooltip: 'LinkedIn (placeholder)',
                onPressed: () => _launch(PortfolioData.linkedinUrl),
              ),
              IconButton(
                icon: const Icon(Icons.alternate_email, color: Colors.white),
                tooltip: 'Twitter (placeholder)',
                onPressed: () => _launch(PortfolioData.twitterUrl),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            PortfolioData.footerText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
