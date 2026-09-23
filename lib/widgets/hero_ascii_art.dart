import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/portfolio_data.dart';
import '../theme/app_theme.dart';

/// Wide, single-row wordmark art shown at [kHeroArtBreakpoint] and above.
/// Every line is padded to equal length by construction below; trailing
/// spaces here are load-bearing and must not be trimmed.
const List<String> _wideArt = [
  '..................................................................................................',
  '..................................................................................................',
  '.....................,,..............gp...........................................................',
  '....`7MMF\'..`7MMF\'...db.......`7MMF\'.\\/......................`7MM"""Yp,...........................',
  '......MM......MM................MM...`\'........................MM....Yb...........................',
  '......MM......MM...`7MM.........MM......`7MMpMMMb.pMMMb........MM....dP....gP"Ya..`7MMpMMMb.......',
  '......MMmmmmmmMM.....MM.........MM........MM....MM....MM.......MM"""bg...,M\'...Yb...MM....MM......',
  '......MM......MM.....MM.........MM........MM....MM....MM.......MM....`Y..8M""""""...MM....MM......',
  '......MM......MM.....MM...,,....MM........MM....MM....MM.......MM....,9..YM.....,...MM....MM......',
  '.....JMML....JMML...JMML..dg...JMML......JMML..JMML..JMML.....JMMmmmd9....`Mbmmd\'..JMML..JMML.....',
  '..........................,j......................................................................',
  '..........................,\'......................................................................',
  '..................................................................................................',
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

// Each non-space character scrambles for its own random duration drawn from
// this range before locking to its final glyph.
const double _kMinScrambleMs = 200;
const double _kMaxScrambleMs = 400;

// Default cap on how many characters may be actively scrambling within a
// single row at once, used when [HeroAsciiArt.maxConcurrentPerRow] isn't
// overridden. A character only starts scrambling once a slot frees up —
// i.e. once fewer than this many characters in that row are currently
// scrambling.
const int _kDefaultMaxConcurrentPerRow = 10;

/// Precomputed per-row reveal timing for one art variant: for every cell,
/// the millisecond (from animation start) at which it begins scrambling
/// ([starts]) and the millisecond at which it locks to its final character
/// ([locks]). Indexed identically to the source art (`[row][col]`); cells
/// that are spaces in the source art are unused (left at 0).
class _RowSchedules {
  final List<List<double>> starts;
  final List<List<double>> locks;

  const _RowSchedules({required this.starts, required this.locks});
}

/// Animated ASCII-art wordmark for the Hero section. On first mount, reveals
/// the art character-by-character within each row: at most
/// [maxConcurrentPerRow] characters per row scramble through random glyphs
/// at once, each for its own randomly-chosen duration. As soon as one
/// finishes and locks to its true character, the next character in that row
/// claims the freed slot and starts scrambling. Because rows differ in
/// length and every character's duration is independently randomized, rows
/// settle at different rates. Spaces in the source art are never scrambled,
/// so the silhouette holds throughout. Runs once, no loop.
class HeroAsciiArt extends StatefulWidget {
  /// Maximum number of characters allowed to scramble concurrently within
  /// any single row. Must be at least 1.
  final int maxConcurrentPerRow;

  const HeroAsciiArt({
    super.key,
    this.maxConcurrentPerRow = _kDefaultMaxConcurrentPerRow,
  }) : assert(
          maxConcurrentPerRow >= 1,
          'maxConcurrentPerRow must be at least 1',
        );

  @override
  State<HeroAsciiArt> createState() => _HeroAsciiArtState();
}

class _HeroAsciiArtState extends State<HeroAsciiArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final Random _random = Random();

  // Per-cell start/lock schedules, one per art variant, generated once up
  // front so timings stay stable across rebuilds instead of being re-rolled
  // every frame.
  late final _RowSchedules _wideSchedule = _generateSchedule(_wideArt);
  late final _RowSchedules _narrowSchedule = _generateSchedule(_narrowArt);

  /// Simulates each row of [art] as a FIFO queue with
  /// [HeroAsciiArt.maxConcurrentPerRow] concurrent scramble "slots": a
  /// character claims whichever slot frees up earliest, so it only starts
  /// once fewer than that many characters to its left (in the same row) are
  /// still scrambling.
  _RowSchedules _generateSchedule(List<String> art) {
    final starts = <List<double>>[];
    final locks = <List<double>>[];
    for (final line in art) {
      final rowStarts = List<double>.filled(line.length, 0);
      final rowLocks = List<double>.filled(line.length, 0);
      final slotFreeAt = List<double>.filled(
        widget.maxConcurrentPerRow,
        0,
      );
      for (var c = 0; c < line.length; c++) {
        if (line[c] == ' ') continue;

        var earliestSlot = 0;
        for (var s = 1; s < slotFreeAt.length; s++) {
          if (slotFreeAt[s] < slotFreeAt[earliestSlot]) earliestSlot = s;
        }

        final start = slotFreeAt[earliestSlot];
        final duration = _kMinScrambleMs +
            _random.nextDouble() * (_kMaxScrambleMs - _kMinScrambleMs);
        final lock = start + duration;

        rowStarts[c] = start;
        rowLocks[c] = lock;
        slotFreeAt[earliestSlot] = lock;
      }
      starts.add(rowStarts);
      locks.add(rowLocks);
    }
    return _RowSchedules(starts: starts, locks: locks);
  }

  double _maxLock(_RowSchedules schedule) {
    var maxVal = 0.0;
    for (final row in schedule.locks) {
      for (final v in row) {
        if (v > maxVal) maxVal = v;
      }
    }
    return maxVal;
  }

  @override
  void initState() {
    super.initState();
    // The controller's duration must cover whichever variant takes longer
    // to fully settle, since the breakpoint (and therefore which schedule
    // is active) isn't known until the first build.
    final totalMs = max(_maxLock(_wideSchedule), _maxLock(_narrowSchedule));
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs > 0 ? totalMs.ceil() : 1),
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

  String _randomGlyph() => _scramblePool[_random.nextInt(_scramblePool.length)];

  List<String> _buildDisplayedLines(
    List<String> sourceArt,
    _RowSchedules schedule,
  ) {
    final elapsedMs = _controller.value * _controller.duration!.inMilliseconds;

    final lines = <String>[];
    for (var r = 0; r < sourceArt.length; r++) {
      final line = sourceArt[r];
      final rowStarts = schedule.starts[r];
      final rowLocks = schedule.locks[r];
      final buffer = StringBuffer();
      for (var c = 0; c < line.length; c++) {
        final sourceChar = line[c];
        if (sourceChar == ' ') {
          buffer.write(' ');
          continue;
        }

        final start = rowStarts[c];
        final lock = rowLocks[c];

        if (elapsedMs < start) {
          buffer.write(' ');
        } else if (elapsedMs < lock) {
          buffer.write(_randomGlyph());
        } else {
          buffer.write(sourceChar);
        }
      }
      lines.add(buffer.toString());
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= kHeroArtBreakpoint;
    final sourceArt = wide ? _wideArt : _narrowArt;
    final schedule = wide ? _wideSchedule : _narrowSchedule;
    final fontSize = wide ? 19.0 : 18.0;
    final displayedLines = _buildDisplayedLines(sourceArt, schedule);

    final textStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize,
      height: 1.0,
      fontWeight: FontWeight.w900,
      color: AppColors.accent,
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
