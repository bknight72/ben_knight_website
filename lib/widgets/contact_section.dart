import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/portfolio_data.dart';
import 'section_container.dart';

/// "Contact." section: short prompt, prominent hire-me/email button, and
/// the same social icon row as the nav/footer.
class ContactSection extends StatelessWidget {
  const ContactSection({super.key});

  Future<void> _launch(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    return SectionContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Contact.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            PortfolioData.contactPrompt,
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () => _launch(PortfolioData.mailtoUrl),
                icon: const Icon(Icons.email_outlined),
                label: const Text('Hire Me'),
              ),
              IconButton(
                icon: const Icon(Icons.code),
                tooltip: 'GitHub (placeholder)',
                onPressed: () => _launch(PortfolioData.githubUrl),
              ),
              IconButton(
                icon: const Icon(Icons.business_center),
                tooltip: 'LinkedIn (placeholder)',
                onPressed: () => _launch(PortfolioData.linkedinUrl),
              ),
              IconButton(
                icon: const Icon(Icons.alternate_email),
                tooltip: 'Twitter (placeholder)',
                onPressed: () => _launch(PortfolioData.twitterUrl),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
