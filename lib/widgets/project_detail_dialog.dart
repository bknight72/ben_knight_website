import 'package:flutter/material.dart';

import '../models/project.dart';

/// Detail modal shown when a [ProjectCard] is tapped: larger placeholder
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
          padding: const EdgeInsets.all(24),
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
              Container(
                height: 220,
                width: double.infinity,
                color: project.placeholderColor,
                child: Center(
                  child: Icon(
                    project.placeholderIcon,
                    size: 64,
                    color: Colors.black38,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                project.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                project.company,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 16),
              Text(project.description),
            ],
          ),
        ),
      ),
    );
  }
}
