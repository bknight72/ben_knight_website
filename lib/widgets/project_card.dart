import 'package:flutter/material.dart';

import '../models/project.dart';
import '../theme/app_shape_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'project_detail_dialog.dart';

/// A single project tile in the "Featured Work" grid. Tapping opens a
/// [ProjectDetailDialog] with the full placeholder description.
class ProjectCard extends StatelessWidget {
  final Project project;

  const ProjectCard({super.key, required this.project});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => ProjectDetailDialog(project: project),
      ),
      child: Container(
        height: 320,
        decoration: BoxDecoration(
          color: project.placeholderColor,
          border: Theme.of(context).extension<AppShapeTheme>()!.cardBorder,
        ),
        child: Stack(
          children: [
            Center(
              child: Icon(
                project.placeholderIcon,
                size: 56,
                color: Colors.black38,
              ),
            ),
            Positioned(
              left: AppSpacing.lg,
              bottom: AppSpacing.lg,
              right: AppSpacing.lg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    project.title,
                    style: AppTextStyles.cardTitle,
                  ),
                  Text(
                    project.company,
                    style: AppTextStyles.cardSubtitle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
