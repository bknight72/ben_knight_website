import 'package:flutter/material.dart';

import '../models/project.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// Detail modal shown when a [ProjectCard] is tapped: larger project
/// image, title, company, and full description — mirrors the reference
/// site's project modal.
class ProjectDetailDialog extends StatelessWidget {
  final Project project;

  const ProjectDetailDialog({super.key, required this.project});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              SizedBox(
                height: 220,
                width: double.infinity,
                child: Image.asset(project.imagePath, fit: BoxFit.cover),
              ),
              // 20px gap: one-off, not part of the shared AppSpacing scale.
              const SizedBox(height: 20),
              Text(
                project.title,
                style: AppTextStyles.cardTitle,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                project.company,
                style: AppTextStyles.cardSubtitle,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(project.description),
            ],
          ),
        ),
      ),
    );
  }
}
