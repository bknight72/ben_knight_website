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
      "I'm a security-focused software developer from LA. \n\nI've built Alarm management & response platforms, contributed to browser-extension based red-teaming tools, and am currently working on an AI-powered parser for US drone manuals.";

  static const String email = 'benknighty@gmail.com';
  static const String githubUrl = 'https://github.com/bknight72';
  static const String linkedinUrl =
      'https://www.linkedin.com/in/ben-knight-b909231a8/';
  static const String substackUrl = 'https://ben411.substack.com/';

  static String get mailtoUrl => 'mailto:$email';

  static const List<Project> projects = [
    Project(
      title: 'NIAR',
      company: 'Novacoast',
      description:
          'A short placeholder description of project one — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileOne,
    ),
    Project(
      title: 'Nori',
      company: 'Novacoast',
      description:
          'A short placeholder description of project two — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileTwo,
    ),
    Project(
      title: 'Placeholder Project Three',
      company: 'Novacoast',
      description:
          'A short placeholder description of project three — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileThree,
    ),
    Project(
      title: 'Placeholder Project Three',
      company: 'Just for me',
      description:
          'A short placeholder description of project three — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileThree,
    ),
    Project(
      title: 'Keyless Entry',
      company: 'Brigham Young University',
      description:
          'A short placeholder description of project three — what it does, '
          'the problem it solves, and the impact it had. Replace with real '
          'project details.',
      placeholderIcon: Icons.image_outlined,
      placeholderColor: AppPlaceholderColors.tileThree,
    ),
  ];

  static const List<String> aboutParagraphs = [
    'I\'ve been interested in software and digital creation since my mom first bought me a'
        ' Game Boy Advanced. This love of transistor computation led me to learn software development'
        ' formally in university and I\'ve never looked back since. To me, the beauty of'
        ' programs can be found in their thoughtful design and that drives me to continue my learning'
        ' beyond schooling. As the frontier of the information era stretches'
        ' forward towards dark and cavenous possibilities, our understanding will be a'
        ' singular source of blazing light. ',
    'Out of the office, if I\'m not out walking my small dog, Bungo, you can catch me grabbing a drink with'
        ' friends, out camping, or watching some spectacular baseball. I\'m also a writer, which you should be able to tell from'
        ' the amount of commas I used in that last sentence. ',
    'If you want to talk to me about anything, go ahead and send me an email at benknighty@gmail.com',
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

  static const String footerText = '© 2026 Ben Knight. Built with Flutter.';
}

/// Distinct placeholder tile colors used for project cards so cards are
/// visually distinguishable before real screenshots are added.
class AppPlaceholderColors {
  AppPlaceholderColors._();

  static const Color tileOne = Color(0xFFEEEEEE);
  static const Color tileTwo = Color(0xFFE3EDEA);
  static const Color tileThree = Color(0xFFE8E8E8);
}
