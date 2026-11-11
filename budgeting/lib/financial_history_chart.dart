import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import 'domain.dart';

enum _Metric {
  netWorth('Net worth'),
  debt('Total debt'),
  spending('Monthly spending');

  const _Metric(this.label);
  final String label;

  int? value(MonthlyFinancialHistory month) => switch (this) {
        netWorth => month.netWorth,
        debt => month.totalDebt,
        spending => month.spending,
      };
}

const _ink = Color(0xff183438);
const _accent = Color(0xff007f78);
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _monthLabel(MonthlyFinancialHistory month) {
  final parts = month.month.split('-');
  return '${_months[int.parse(parts[1]) - 1]} ${parts[0]}'
      '${month.isCurrent ? ' (so far)' : ''}';
}

/// Tracked monthly history, independent of the dashboard's month filter.
class FinancialHistoryChart extends StatefulWidget {
  const FinancialHistoryChart({super.key, required this.history});

  final List<MonthlyFinancialHistory> history;

  @override
  State<FinancialHistoryChart> createState() => _FinancialHistoryChartState();
}

class _FinancialHistoryChartState extends State<FinancialHistoryChart> {
  _Metric _metric = _Metric.netWorth;
  String? _selectedMonth;

  void _select(int index) {
    final month = widget.history[index].month;
    if (_selectedMonth != month) setState(() => _selectedMonth = month);
  }

  String _detail(MonthlyFinancialHistory month) {
    if (_metric == _Metric.spending) {
      return month.isCurrent
          ? 'Posted spending through the current reporting date, including refunds. '
              'Transfers, card payments, and reporting exclusions are omitted.'
          : 'Posted spending for the full month, including refunds. '
              'Transfers, card payments, and reporting exclusions are omitted.';
    }
    final debt = _metric == _Metric.debt;
    final observed =
        debt ? month.observedCreditAccountCount : month.observedAccountCount;
    final total = debt ? month.creditAccountCount : month.accountCount;
    final oldest =
        debt ? month.oldestCreditObservation : month.oldestObservation;
    final coverage = '$observed of $total tracked '
        '${debt ? 'credit accounts' : 'accounts'} have observations.';
    var date = '';
    if (oldest != null) {
      reportingMonth(oldest); // Initialize the shared reporting timezone data.
      final local =
          tz.TZDateTime.from(oldest, tz.getLocation('America/Denver'));
      date = ' Oldest included observation: '
          '${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')} '
          '${local.timeZoneName} (America/Denver).';
    }
    final timing = month.isCurrent
        ? ' Current observations, not month-end balances.'
        : ' Observed balances are not guaranteed month-end closing balances; '
            'earlier observations are carried forward.';
    final unavailable = _metric.value(month) == null
        ? ' Unavailable: required balance observations are missing.'
        : '';
    return '$coverage$date$timing$unavailable';
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    final found = history.indexWhere((month) => month.month == _selectedMonth);
    final selected = found < 0 ? history.length - 1 : found;
    final month = history.isEmpty ? null : history[selected];
    return Card(
      color: Colors.white,
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: _ink),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Financial history',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final metric in _Metric.values)
                    ChoiceChip(
                      label: Text(metric.label),
                      selected: _metric == metric,
                      selectedColor: const Color(0xffd6f3eb),
                      labelStyle: const TextStyle(color: _ink),
                      onSelected: (_) => setState(() => _metric = metric),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (month == null)
                const Text('Financial history starts in October 2026.')
              else ...[
                LayoutBuilder(builder: (context, constraints) {
                  final width = math.max(
                      constraints.maxWidth, 110.0 + history.length * 132);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        final direction = event.logicalKey ==
                                LogicalKeyboardKey.arrowRight
                            ? 1
                            : event.logicalKey == LogicalKeyboardKey.arrowLeft
                                ? -1
                                : 0;
                        if (direction == 0) return KeyEventResult.ignored;
                        _select((selected + direction)
                            .clamp(0, history.length - 1));
                        return KeyEventResult.handled;
                      },
                      child: Semantics(
                        label:
                            '${_metric.label} chart. Use the month selector below '
                            'or left and right arrow keys to explore values. '
                            'Missing observations appear as gaps.',
                        child: MouseRegion(
                          onHover: (event) => _select(_HistoryPainter.indexAt(
                              event.localPosition.dx, width, history.length)),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (event) => _select(
                                _HistoryPainter.indexAt(event.localPosition.dx,
                                    width, history.length)),
                            child: CustomPaint(
                              key: const ValueKey('financial-history-plot'),
                              size: Size(width, 260),
                              painter: _HistoryPainter(
                                history: history,
                                metric: _metric,
                                selected: selected,
                                textScaler: MediaQuery.textScalerOf(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: ValueKey('history-month-${month.month}'),
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Select month',
                    labelStyle: TextStyle(color: _ink),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: _ink, fontSize: 14),
                  items: [
                    for (var i = 0; i < history.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(_monthLabel(history[i]),
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (index) {
                    if (index != null) _select(index);
                  },
                ),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: SelectableText(
                    '${_monthLabel(month)}: ${_metric.label}: '
                    '${_metric.value(month) == null ? 'Unavailable' : money(_metric.value(month)!)}',
                    key: const ValueKey('financial-history-value'),
                    style: const TextStyle(
                        color: _ink, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(_detail(month),
                    style: const TextStyle(color: _ink, fontSize: 13)),
                const SizedBox(height: 8),
                const Text(
                    'Gaps mean unavailable balances, not zero. '
                    'Scroll horizontally to explore longer histories.',
                    style: TextStyle(color: _ink, fontSize: 12)),
              ],
              if (_metric == _Metric.netWorth) ...[
                const SizedBox(height: 12),
                const Text(
                  'Tracked net worth is tracked cash minus tracked credit balances. '
                  'It does not include property, investments, or untracked loans.',
                  style: TextStyle(color: _ink, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter({
    required this.history,
    required this.metric,
    required this.selected,
    required this.textScaler,
  });

  final List<MonthlyFinancialHistory> history;
  final _Metric metric;
  final int selected;
  final TextScaler textScaler;
  static const left = 84.0;
  static const right = 68.0;

  static double _x(int index, double width, int count) => count == 1
      ? (left + width - right) / 2
      : left + index * (width - left - right) / (count - 1);

  static int indexAt(double x, double width, int count) => count == 1
      ? 0
      : ((x - left) / (width - left - right) * (count - 1))
          .round()
          .clamp(0, count - 1);

  void _text(Canvas canvas, String text, Offset offset,
      {double width = 76, TextAlign align = TextAlign.right}) {
    final painter = TextPainter(
      text: TextSpan(
          text: text, style: const TextStyle(color: _ink, fontSize: 11)),
      textDirection: TextDirection.ltr,
      textAlign: align,
      textScaler: textScaler,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  String _axisMoney(double cents) {
    final dollars = cents / 100;
    final magnitude = dollars.abs();
    final (divisor, suffix) = magnitude >= 1e12
        ? (1e12, 'T')
        : magnitude >= 1e9
            ? (1e9, 'B')
            : magnitude >= 1e6
                ? (1e6, 'M')
                : magnitude >= 1000
                    ? (1000.0, 'k')
                    : (1.0, '');
    return '${dollars < 0 ? '-' : ''}\$'
        '${(magnitude / divisor).toStringAsFixed(suffix.isEmpty ? 2 : 1)}$suffix';
  }

  @override
  void paint(Canvas canvas, Size size) {
    final values = history.map(metric.value).toList();
    final known = values.whereType<int>();
    var low = 0.0;
    var high = 0.0;
    for (final value in known) {
      low = math.min(low, value.toDouble());
      high = math.max(high, value.toDouble());
    }
    if (low == high) {
      low = -100;
      high = 100;
    }
    final padding = (high - low) * .1;
    low -= padding;
    high += padding;
    const top = 18.0;
    const bottom = 192.0;
    double y(int value) =>
        bottom - (value - low) / (high - low) * (bottom - top);
    final grid = Paint()
      ..color = const Color(0xffdce7e5)
      ..strokeWidth = 1;
    for (var tick = 0; tick <= 4; tick++) {
      final at = top + tick * (bottom - top) / 4;
      canvas.drawLine(Offset(left, at), Offset(size.width - right, at), grid);
      _text(canvas, _axisMoney(high - tick * (high - low) / 4),
          Offset(0, at - 7));
    }
    final line = Paint()
      ..color = _accent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final dot = Paint()..color = _accent;
    Offset? previous;
    for (var i = 0; i < history.length; i++) {
      final x = _x(i, size.width, history.length);
      _text(canvas, _monthLabel(history[i]), Offset(x - 62, bottom + 14),
          width: 124, align: TextAlign.center);
      final value = values[i];
      if (value == null) {
        previous = null;
        canvas.drawCircle(
            Offset(x, bottom + 4),
            4,
            Paint()
              ..color = const Color(0xff677e7c)
              ..style = PaintingStyle.stroke);
        continue;
      }
      final point = Offset(x, y(value));
      if (previous != null) canvas.drawLine(previous, point, line);
      canvas.drawCircle(point, i == selected ? 6 : 4, dot);
      if (i == selected) {
        canvas.drawCircle(
            point,
            10,
            Paint()
              ..color = _accent
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      previous = point;
    }
    if (known.isEmpty) {
      _text(canvas, 'No balance observations available', Offset(left + 8, 90),
          width: size.width - left - right - 16, align: TextAlign.center);
    }
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter oldDelegate) =>
      oldDelegate.history != history ||
      oldDelegate.metric != metric ||
      oldDelegate.selected != selected ||
      oldDelegate.textScaler != textScaler;
}
