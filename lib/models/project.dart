import 'package:flutter/material.dart';

/// A single portfolio project entry shown in the "Featured Work" section.
///
/// All fields are placeholder-friendly: swap in real copy and screenshots
/// when ready.
@immutable
class Project {
  final String title;
  final String company;
  final String description;
  final String imagePath;

  const Project({
    required this.title,
    required this.company,
    required this.description,
    required this.imagePath,
  });
}
