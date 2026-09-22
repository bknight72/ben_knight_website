import 'package:flutter/material.dart';

/// A single role in the "Experience" section timeline.
@immutable
class ExperienceEntry {
  final String role;
  final String company;
  final String dateRange;
  final List<String> bullets;

  const ExperienceEntry({
    required this.role,
    required this.company,
    required this.dateRange,
    required this.bullets,
  });
}
