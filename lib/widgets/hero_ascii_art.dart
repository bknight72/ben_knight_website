import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/portfolio_data.dart';
import '../theme/app_theme.dart';

/// Wide, single-row wordmark art shown at [kHeroArtBreakpoint] and above.
/// Every line is padded to equal length by construction below; trailing
/// spaces here are load-bearing and must not be trimmed.
const List<String> _wideArt = [
  '                ,,                    gp                                                           ',
  '`7MMF\'  `7MMF\'  db              `7MMF\'\\/                      `7MM"""Yp,                           ',
  '  MM      MM                      MM  `\'                        MM    Yb                           ',
  '  MM      MM  `7MM                MM    `7MMpMMMb.pMMMb.        MM    dP  .gP"Ya `7MMpMMMb.        ',
  '  MMmmmmmmMM    MM                MM      MM    MM    MM        MM"""bg. ,M\'   Yb  MM    MM        ',
  '  MM      MM    MM                MM      MM    MM    MM        MM    `Y 8M""""""  MM    MM        ',
  '  MM      MM    MM       ,,       MM      MM    MM    MM        MM    ,9 YM.    ,  MM    MM      ,,',
  '.JMML.  .JMML..JMML.     dg     .JMML.  .JMML  JMML  JMML.    .JMMmmmd9   `Mbmmd\'.JMML  JMML.    db',
  '                         ,j                                                                        ',
  '                        ,\'                                                                         ',
];

/// Narrower, stacked wordmark art shown below [kHeroArtBreakpoint]. The two
/// blocks (top logo mark, bottom "Ben" word) are separated by a blank line.
const List<String> _narrowArt = [
  ',,                    gp                  ',
  '`7MMF\'  `7MMF\'  db              `7MMF\'\\/                  ',
  '  MM      MM                      MM  `\'                  ',
  '  MM      MM  `7MM                MM    `7MMpMMMb.pMMMb.  ',
  '  MMmmmmmmMM    MM                MM      MM    MM    MM  ',
  '  MM      MM    MM                MM      MM    MM    MM  ',
  '  MM      MM    MM       ,,       MM      MM    MM    MM  ',
  '.JMML.  .JMML..JMML.     dg     .JMML.  .JMML  JMML  JMML.',
  '                         ,j                               ',
  '                        ,\'                                ',
  '',
  '`7MM"""Yp,                                                ',
  '  MM    Yb                                                ',
  '  MM    dP  .gP"Ya `7MMpMMMb.                             ',
  '  MM"""bg. ,M\'   Yb  MM    MM                             ',
  '  MM    `Y 8M""""""  MM    MM                             ',
  '  MM    ,9 YM.    ,  MM    MM      ,,                     ',
  '.JMMmmmd9   `Mbmmd\'.JMML  JMML.    db',
];

/// Pool of glyphs used for the transient "scramble" state as each column of
/// the art decodes in. Intentionally broader than the character set the art
/// itself actually uses, for a glitchier reveal.
const String _scramblePool =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()_+-=[]{}<>?/|~';

const Duration _kRevealDuration = Duration(milliseconds: 1200);
const double _kScrambleWindowMs = 250;

/// Animated ASCII-art wordmark for the Hero section. On first mount, reveals
/// the art left-to-right in a column wave: each not-yet-reached column is
/// blank, the currently-active column scrambles through random glyphs, and
/// settled columns show the true character. Spaces in the source art are
/// never scrambled, so the silhouette holds throughout. Runs once, no loop.
class HeroAsciiArt extends StatefulWidget {
  const HeroAsciiArt({super.key});

  @override
  State<HeroAsciiArt> createState() => _HeroAsciiArtState();
}

class _HeroAsciiArtState extends State<HeroAsciiArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _kRevealDuration,
    )..forward();
    _controller.addListener(_onTick);
  }

  void _onTick() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  String _randomGlyph() =>
      _scramblePool[_random.nextInt(_scramblePool.length)];

  List<String> _buildDisplayedLines(List<String> sourceArt) {
    final totalCols = sourceArt.fold<int>(
      0,
      (max, line) => line.length > max ? line.length : max,
    );
    if (totalCols <= 1) return sourceArt;

    final elapsedMs = _controller.value * _kRevealDuration.inMilliseconds;
    final revealSpan = _kRevealDuration.inMilliseconds - _kScrambleWindowMs;

    return sourceArt.map((line) {
      final buffer = StringBuffer();
      for (var c = 0; c < line.length; c++) {
        final sourceChar = line[c];
        if (sourceChar == ' ') {
          buffer.write(' ');
          continue;
        }

        final activation = (c / (totalCols - 1)) * revealSpan;
        final lock = activation + _kScrambleWindowMs;

        if (elapsedMs < activation) {
          buffer.write(' ');
        } else if (elapsedMs < lock) {
          buffer.write(_randomGlyph());
        } else {
          buffer.write(sourceChar);
        }
      }
      return buffer.toString();
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= kHeroArtBreakpoint;
    final sourceArt = wide ? _wideArt : _narrowArt;
    final fontSize = wide ? 10.0 : 9.0;
    final displayedLines = _buildDisplayedLines(sourceArt);

    final textStyle = GoogleFonts.dmMono(
      fontSize: fontSize,
      height: 1.0,
      color: AppColors.text,
    );

    return Semantics(
      label: PortfolioData.heroHeadline,
      child: ExcludeSemantics(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in displayedLines)
                Text(line, style: textStyle, softWrap: false),
            ],
          ),
        ),
      ),
    );
  }
}
