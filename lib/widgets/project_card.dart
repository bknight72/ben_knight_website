import 'package:flutter/material.dart';

import '../models/project.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import 'project_detail_dialog.dart';

/// A single project tile in the "Featured Work" grid. Tapping opens a
/// [ProjectDetailDialog] with the full placeholder description.
class ProjectCard extends StatefulWidget {
  final Project project;

  const ProjectCard({super.key, required this.project});

  @override
  State<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<ProjectCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    return Semantics(
      label: '${project.title}, ${project.company}',
      button: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(50),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(50),
            onHover: (hovering) => setState(() => _hovered = hovering),
            onFocusChange: (focused) => setState(() => _focused = focused),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => ProjectDetailDialog(project: project),
            ),
            child: Container(
              height: 420,
              color: project.placeholderColor,
              child: Stack(
                children: [
                  Center(
                    child: Icon(
                      project.placeholderIcon,
                      size: 56,
                      color: Colors.black38,
                    ),
                  ),
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _hovered || _focused ? 1 : 0,
                      child: ColoredBox(
                        color: AppColors.accent.withValues(alpha: 0.7),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xxxxl),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  project.company,
                                  style: AppTextStyles.cardSubtitle.copyWith(
                                      color: Colors.white, fontSize: 18),
                                ),
                                Text(
                                  project.title,
                                  style: AppTextStyles.cardTitle.copyWith(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight(800)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
