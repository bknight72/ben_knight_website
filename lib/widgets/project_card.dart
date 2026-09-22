import 'package:flutter/material.dart';

import '../models/project.dart';
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
          border: Border.all(color: Colors.black12),
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
              left: 16,
              bottom: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    project.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    project.company,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.black54,
                    ),
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
