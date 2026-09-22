import 'package:flutter/material.dart';

/// A single portfolio project entry shown in the "Featured Work" section.
///
/// All fields are placeholder-friendly: swap in real copy and, once real
/// screenshots exist, replace [placeholderIcon]-based rendering in
/// `ProjectCard`/`ProjectDetailDialog` with `Image.asset(...)`.
@immutable
class Project {
  final String title;
  final String company;
  final String description;
  final IconData placeholderIcon;
  final Color placeholderColor;

  const Project({
    required this.title,
    required this.company,
    required this.description,
    required this.placeholderIcon,
    required this.placeholderColor,
  });
}
