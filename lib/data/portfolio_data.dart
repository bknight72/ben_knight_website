import 'package:flutter/material.dart';

import '../models/experience_entry.dart';
import '../models/project.dart';

/// Centralized placeholder content for the portfolio site.
///
/// Every string/link here is an explicit placeholder — replace with real
/// content when ready. Keeping all copy in one place means later edits
/// touch only this file, not widget logic.
class PortfolioData {
  PortfolioData._();

  static const String name = 'Ben Knight';

  static const String heroHeadline =
      "Hey, I'm Ben — A Software\nEngineer from Placeholder City.";

  static const String heroSubtext =
      "I've built [placeholder achievement one], contributed to "
      "[placeholder achievement two], and am currently working on "
      "[placeholder achievement three].";

  static const String email = 'placeholder@example.com';
  static const String githubUrl = 'https://github.com/placeholder';
  static const String linkedinUrl = 'https://linkedin.com/in/placeholder';
  static const String twitterUrl = 'https://twitter.com/placeholder';

  static String get mailtoUrl => 'mailto:$email';

  static const List<Project> projects = [
    Project(
      title: 'Placeholder Project One',
      company: 'Placeholder Company A',
      description:
          'A short placeholder description of project one — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileOne,
    ),
    Project(
      title: 'Placeholder Project Two',
      company: 'Placeholder Company B',
      description:
          'A short placeholder description of project two — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileTwo,
    ),
    Project(
      title: 'Placeholder Project Three',
      company: 'Placeholder Company C',
      description:
          'A short placeholder description of project three — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileThree,
    ),
  ];

  static const List<String> aboutParagraphs = [
    'Placeholder about-me paragraph one. Talk about your background, what '
        'got you into software engineering, and what drives you.',
    'Placeholder about-me paragraph two. Mention placeholder interests, '
        'placeholder hobbies, or placeholder values relevant to your work.',
  ];

  static const List<ExperienceEntry> experience = [
    ExperienceEntry(
      role: 'Placeholder Senior Role',
      company: 'Placeholder Company A',
      dateRange: '2024 — Present',
      bullets: [
        'Placeholder bullet describing a key responsibility or achievement.',
        'Placeholder bullet describing another key responsibility.',
        'Placeholder bullet describing measurable impact or outcome.',
      ],
    ),
    ExperienceEntry(
      role: 'Placeholder Mid-Level Role',
      company: 'Placeholder Company B',
      dateRange: '2021 — 2024',
      bullets: [
        'Placeholder bullet describing a key responsibility or achievement.',
        'Placeholder bullet describing another key responsibility.',
      ],
    ),
    ExperienceEntry(
      role: 'Placeholder Junior Role',
      company: 'Placeholder Company C',
      dateRange: '2019 — 2021',
      bullets: [
        'Placeholder bullet describing a key responsibility or achievement.',
        'Placeholder bullet describing another key responsibility.',
      ],
    ),
  ];

  static const List<String> skills = [
    'Flutter',
    'Dart',
    'Placeholder Skill A',
    'Placeholder Skill B',
    'Placeholder Skill C',
    'Placeholder Skill D',
    'Placeholder Skill E',
    'Placeholder Skill F',
    'Placeholder Skill G',
    'Placeholder Skill H',
  ];

  static const String contactPrompt =
      "Have a placeholder opportunity in mind? I'd love to hear about it.";

  static const String footerText =
      '© 2026 Ben Knight. Built with Flutter. '
      'Placeholder content — replace before publishing.';
}

/// Distinct placeholder tile colors used for project cards so cards are
/// visually distinguishable before real screenshots are added.
class AppPlaceholderColors {
  AppPlaceholderColors._();

  static const Color tileOne = Color(0xFFEEEEEE);
  static const Color tileTwo = Color(0xFFE3EDEA);
  static const Color tileThree = Color(0xFFE8E8E8);
}
