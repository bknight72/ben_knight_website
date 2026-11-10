import 'package:flutter/material.dart';

import 'budgeteer_domain.dart';
import 'domain.dart';
import 'repository.dart';

const _ink = Color(0xff102e2c);
const _teal = Color(0xff17695c);
const _canvas = Color(0xfff4f6f3);
const _muted = Color(0xff637570);
const _danger = Color(0xffa53d43);
const _palette = <String, Color>{
  'teal': _teal,
  'blue': Color(0xff426c9b),
  'amber': Color(0xffa87522),
  'rose': Color(0xffa45371),
  'violet': Color(0xff77629c),
  'slate': Color(0xff657782),
};

/// A server-backed planning workspace. Bank sources are always read-only.
class BudgeteerPage extends StatefulWidget {
  final LedgerRepository repository;
  final String month;
  final List<Json> transactions;

  const BudgeteerPage({
    super.key,
    required this.repository,
    required this.month,
    required this.transactions,
  });

  @override
  State<BudgeteerPage> createState() => _BudgeteerPageState();
}

class _BudgeteerPageState extends State<BudgeteerPage> {
  BudgeteerState _state = BudgeteerState.empty();
  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  bool _saved = false;
  bool _conflict = false;
  String? _error;
  String? _selected;
  String? _retryOperation;
  Json? _retryPayload;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BudgeteerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.month != widget.month ||
        oldWidget.repository != widget.repository) {
      _generation++;
      _state = BudgeteerState.empty();
      _loaded = false;
      _selected = null;
      _retryOperation = null;
      _retryPayload = null;
      _saving = false;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _saved = false;
    });
    try {
      final result = await widget.repository.budgeteerRead(widget.month);
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = result;
        _loaded = true;
        _conflict = false;
        _retryOperation = null;
        _retryPayload = null;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = 'Could not load this plan. Please retry.');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<bool> _mutate(String operation, Json payload) async {
    if (_disabled) return false;
    final generation = _generation;
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      final result = await widget.repository
          .budgeteerMutate(widget.month, _state.revision, operation, payload);
      if (!mounted || generation != _generation) return false;
      setState(() {
        _state = result;
        _saved = true;
        _retryOperation = null;
        _retryPayload = null;
      });
      return true;
    } catch (error) {
      if (!mounted || generation != _generation) return false;
      setState(() {
        _conflict = error.toString().contains('budgeteer_conflict');
        _retryOperation = operation;
        _retryPayload = payload;
        _error = _conflict
            ? 'This plan changed elsewhere. Reload, review, then reapply your change.'
            : 'Could not save. Your last saved plan is unchanged. Please retry.';
      });
      return false;
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _saving = false);
      }
    }
  }

  bool get _disabled => !_loaded || _saving || _loading || _conflict;
  String _id(Json row) => '${row['id']}';
  Color _color(Json? row) => _palette[row?['color_key']] ?? _teal;
  Json? _group(Object? id) {
    for (final group in _state.groups) {
      if (group['id'] == id) return group;
    }
    return null;
  }

  List<Json> _inGroup(Object? id) =>
      _state.withdrawals.where((entry) => entry['group_id'] == id).toList();

  Future<void> _order(List<Json> groups, List<Json> withdrawals) async {
    await _mutate('reorder', {
      'groups': groups.map(_id).toList(),
      'entries': [
        for (final entry in [..._state.deposits, ...withdrawals])
          {'id': entry['id'], 'group_id': entry['group_id']},
      ],
    });
  }

  Future<void> _moveGroup(int index, int target) async {
    if (target < 0 || target >= _state.groups.length) return;
    final groups = [..._state.groups];
    groups.insert(target, groups.removeAt(index));
    await _order(groups, [
      for (final group in groups) ..._inGroup(group['id']),
      ..._inGroup(null),
    ]);
  }

  Future<void> _moveEntry(Json entry, Object? groupId, int target) async {
    final destination = _inGroup(groupId)
      ..removeWhere((row) => row['id'] == entry['id']);
    destination.insert(
        target.clamp(0, destination.length), {...entry, 'group_id': groupId});
    final ordered = <Json>[];
    for (final id in [..._state.groups.map((row) => row['id']), null]) {
      ordered.addAll(id == groupId
          ? destination
          : _inGroup(id).where((row) => row['id'] != entry['id']));
    }
    await _order(_state.groups, ordered);
  }

  Widget _panel({required Widget child, Color color = Colors.white}) =>
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _ink.withValues(alpha: .07)),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final allocation = _state.allocation;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(
        spacing: 20,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('BUDGETEER',
                style: TextStyle(
                    color: _teal,
                    fontSize: 11,
                    letterSpacing: 2.4,
                    fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text('Give every dollar a place.',
                style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                    letterSpacing: -.7)),
          ]),
          Text(widget.month, style: const TextStyle(color: _muted)),
          Semantics(
            liveRegion: true,
            child: Text(
                _saving
                    ? 'Saving...'
                    : _saved
                        ? 'Saved to your plan'
                        : 'Monthly funding plan',
                style: const TextStyle(color: _muted, fontSize: 12)),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text('Plan with pooled deposits. Bank transactions stay untouched.',
          style: TextStyle(color: _muted)),
      const SizedBox(height: 20),
      if (_loading)
        const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator())),
      if (_error != null) ...[
        _panel(
            color: const Color(0xfffff1ed),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                    liveRegion: true,
                    child:
                        Text(_error!, style: const TextStyle(color: _danger))),
                TextButton.icon(
                    onPressed: _saving || _loading ? null : _load,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                        _conflict ? 'Reload plan to reapply' : 'Reload plan')),
                if (!_conflict && _retryOperation != null)
                  TextButton.icon(
                      onPressed: _saving || _loading
                          ? null
                          : () => _mutate(_retryOperation!, _retryPayload!),
                      icon: const Icon(Icons.replay),
                      label: const Text('Retry change')),
              ],
            )),
        const SizedBox(height: 16),
      ],
      if (!_loading) ...[
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final items = [
            _total('Pooled deposits', allocation.deposits, _teal),
            _total('Planned withdrawals', allocation.withdrawals, _ink),
            _total(
                allocation.deficit > 0 ? 'Funding deficit' : 'Remaining',
                allocation.deficit > 0
                    ? allocation.deficit
                    : allocation.remaining,
                allocation.deficit > 0 ? _danger : _teal),
          ];
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final item in items)
              SizedBox(
                  width: width >= 650 ? (width - 24) / 3 : width, child: item),
          ]);
        }),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: _disabled ? null : () => _entryDialog('deposit'),
              icon: const Icon(Icons.add),
              label: const Text('Add deposit')),
          OutlinedButton.icon(
              onPressed: _disabled ? null : () => _entryDialog('withdrawal'),
              icon: const Icon(Icons.add),
              label: const Text('Add withdrawal')),
          TextButton.icon(
              onPressed: _disabled ? null : _labelsDialog,
              icon: const Icon(Icons.sell_outlined),
              label: const Text('Manage labels')),
        ]),
        const SizedBox(height: 24),
        LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          final funding = _funding(wide);
          final editor = _withdrawals();
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 290, child: funding),
              const SizedBox(width: 20),
              Expanded(child: editor),
            ]);
          }
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [funding, const SizedBox(height: 20), editor]);
        }),
        const SizedBox(height: 20),
        _deposits(),
      ],
    ]);
  }

  Widget _total(String label, int amount, Color color) => _panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 8),
        Text(money(amount),
            style: TextStyle(
                color: color,
                fontSize: 25,
                fontWeight: FontWeight.w700,
                letterSpacing: -.6)),
      ]));

  Widget _funding(bool wide) {
    final allocation = _state.allocation;
    final capacity = allocation.deposits;
    return _panel(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Your funding stack',
            style: TextStyle(
                color: _ink, fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('${money(capacity)} capacity',
            style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 20),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 100,
            height: wide ? 420 : 280,
            child: Semantics(
              label: 'Funding bar. ${money(capacity)} deposited. '
                  '${money(allocation.remaining)} remaining. '
                  '${money(allocation.deficit)} unfunded.',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: LayoutBuilder(builder: (context, constraints) {
                  var offset = 0.0;
                  final segments = <Widget>[];
                  if (capacity > 0) {
                    for (var i = 0; i < allocation.segments.length; i++) {
                      final segment = allocation.segments[i];
                      final height =
                          constraints.maxHeight * segment.funded / capacity;
                      if (height <= 0) continue;
                      final selected = segment.entry['id'] == _selected;
                      final number = i + 1;
                      segments.add(Positioned(
                        top: offset,
                        left: 0,
                        right: 0,
                        height: height,
                        child: Semantics(
                          button: true,
                          selected: selected,
                          label: '$number. ${segment.entry['name']}, '
                              '${money(segment.funded)} funded',
                          child: Tooltip(
                            message: '${segment.entry['name']}: '
                                '${money(segment.funded)} funded',
                            child: Material(
                              color: _color(_group(segment.entry['group_id'])),
                              child: InkWell(
                                onTap: () => setState(
                                    () => _selected = _id(segment.entry)),
                                child: Container(
                                  decoration: BoxDecoration(
                                      border: Border.all(
                                          color: selected ? _ink : Colors.white,
                                          width: selected ? 3 : .5)),
                                  alignment: Alignment.center,
                                  child: height >= 27
                                      ? Text('$number',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700))
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ));
                      offset += height;
                    }
                  }
                  return Stack(children: [
                    Positioned.fill(
                        child: Container(color: const Color(0xffdce8df))),
                    ...segments,
                  ]);
                }),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.south, color: _teal),
              const SizedBox(height: 8),
              const Text('Funded in order',
                  style: TextStyle(color: _ink, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                  'Numbers match the withdrawal list. Select either to highlight.',
                  style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 16),
              if (capacity == 0)
                const Text(
                    'No funding yet. Add a deposit to give this plan capacity.',
                    style: TextStyle(color: _danger, fontSize: 12))
              else ...[
                Container(width: 20, height: 8, color: const Color(0xffdce8df)),
                const SizedBox(height: 6),
                Text('${money(allocation.remaining)}\nremaining',
                    style: const TextStyle(color: _teal, fontSize: 12)),
              ],
              if (allocation.deficit > 0) ...[
                const SizedBox(height: 18),
                const Icon(Icons.warning_amber_rounded, color: _danger),
                Text('${money(allocation.deficit)}\nunfunded',
                    style: const TextStyle(
                        color: _danger, fontWeight: FontWeight.w700)),
                const Text('Overflow is outside deposit capacity.',
                    style: TextStyle(color: _muted, fontSize: 12)),
              ],
            ],
          )),
        ]),
      ],
    ));
  }

  Widget _withdrawals() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Withdrawal order',
                  style: TextStyle(
                      fontSize: 20, color: _ink, fontWeight: FontWeight.w700)),
              TextButton.icon(
                  onPressed: _disabled ? null : () => _namedDialog(false),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add group')),
            ],
          ),
          const Text(
              'First in line, first funded. Move items with handles or arrow controls.',
              style: TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 12),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _state.groups.length,
            onReorderItem: (oldIndex, newIndex) {
              if (_disabled) return;
              _moveGroup(oldIndex, newIndex);
            },
            itemBuilder: (context, index) => Padding(
              key: ValueKey('group-${_id(_state.groups[index])}'),
              padding: const EdgeInsets.only(bottom: 12),
              child: _groupSection(_state.groups[index], index),
            ),
          ),
          _groupSection(null, null),
        ],
      );

  Widget _groupSection(Json? group, int? groupIndex) {
    final entries = _inGroup(group?['id']);
    return _panel(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (groupIndex != null)
              ReorderableDragStartListener(
                  index: groupIndex,
                  enabled: !_disabled,
                  child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Tooltip(
                          message: 'Drag group',
                          child: Icon(Icons.drag_indicator,
                              color: _muted, size: 20)))),
            Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    color: _color(group), shape: BoxShape.circle)),
            Text('${group?['name'] ?? 'Ungrouped'}',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, color: _ink)),
            Text(
                money(entries.fold<int>(
                    0, (total, row) => total + integer(row['amount_minor']))),
                style: const TextStyle(color: _muted, fontSize: 12)),
            if (group != null) ...[
              IconButton(
                  tooltip: 'Move ${group['name']} group up',
                  onPressed: _disabled || groupIndex == 0
                      ? null
                      : () => _moveGroup(groupIndex!, groupIndex - 1),
                  icon: const Icon(Icons.arrow_upward, size: 18)),
              IconButton(
                  tooltip: 'Move ${group['name']} group down',
                  onPressed: _disabled || groupIndex == _state.groups.length - 1
                      ? null
                      : () => _moveGroup(groupIndex!, groupIndex + 1),
                  icon: const Icon(Icons.arrow_downward, size: 18)),
              IconButton(
                  tooltip: 'Edit group ${group['name']}',
                  onPressed:
                      _disabled ? null : () => _namedDialog(false, row: group),
                  icon: const Icon(Icons.edit_outlined, size: 18)),
              IconButton(
                  tooltip: 'Delete group ${group['name']}',
                  onPressed: _disabled
                      ? null
                      : () => _confirm(
                          'Delete group?',
                          'Its withdrawals will move to Ungrouped.',
                          'group_delete',
                          {'id': group['id']}),
                  icon: const Icon(Icons.delete_outline, size: 18)),
            ],
          ],
        ),
        if (entries.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No withdrawals here yet.',
                  style: TextStyle(color: _muted, fontSize: 12))),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: entries.length,
          onReorderItem: (oldIndex, newIndex) {
            if (_disabled) return;
            _moveEntry(entries[oldIndex], group?['id'], newIndex);
          },
          itemBuilder: (context, index) => _entryCard(
              entries[index], index, entries.length,
              key: ValueKey('entry-${_id(entries[index])}')),
        ),
      ],
    ));
  }

  Widget _entryCard(Json entry, int index, int length, {Key? key}) {
    final selected = _selected == entry['id'];
    final position =
        _state.withdrawals.indexWhere((row) => row['id'] == entry['id']) + 1;
    final segment = _state.allocation.segments
        .where((segment) => segment.entry['id'] == entry['id'])
        .first;
    final labels = _state.labels.where((label) => _state.entryLabels.any(
        (link) =>
            link['entry_id'] == entry['id'] &&
            link['label_id'] == label['id']));
    return Container(
      key: key,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: selected ? const Color(0xffe8f2ec) : _canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? _teal : Colors.transparent, width: 2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
            selected: selected,
            child: InkWell(
              onTap: () => setState(() => _selected = _id(entry)),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: _color(_group(entry['group_id'])),
                        borderRadius: BorderRadius.circular(7)),
                    child: Text('$position',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700))),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${entry['name']}',
                        style: const TextStyle(
                            color: _ink, fontWeight: FontWeight.w700)),
                    Text(money(integer(entry['amount_minor'])),
                        style: const TextStyle(color: _ink, fontSize: 16)),
                    Text(
                        segment.unfunded > 0
                            ? '${money(segment.funded)} funded / ${money(segment.unfunded)} unfunded'
                            : 'Fully funded',
                        style: TextStyle(
                            fontSize: 11,
                            color: segment.unfunded > 0 ? _danger : _teal)),
                  ],
                )),
              ]),
            )),
        if (labels.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 5, runSpacing: 5, children: [
            for (final label in labels)
              Chip(
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: _color(label).withValues(alpha: .3)),
                  label: Text('${label['name']}',
                      style: TextStyle(fontSize: 11, color: _color(label)))),
          ]),
        ],
        _sourceDetails(entry),
        Wrap(
          spacing: 0,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ReorderableDragStartListener(
                index: index,
                enabled: !_disabled,
                child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Tooltip(
                        message: 'Drag withdrawal',
                        child: Icon(Icons.drag_indicator,
                            color: _muted, size: 20)))),
            IconButton(
                tooltip: 'Move ${entry['name']} up',
                onPressed: _disabled || index == 0
                    ? null
                    : () => _moveEntry(entry, entry['group_id'], index - 1),
                icon: const Icon(Icons.arrow_upward, size: 18)),
            IconButton(
                tooltip: 'Move ${entry['name']} down',
                onPressed: _disabled || index == length - 1
                    ? null
                    : () => _moveEntry(entry, entry['group_id'], index + 1),
                icon: const Icon(Icons.arrow_downward, size: 18)),
            PopupMenuButton<String>(
              enabled: !_disabled,
              tooltip: 'Move ${entry['name']} to group',
              icon: const Icon(Icons.drive_file_move_outline, size: 19),
              itemBuilder: (context) => [
                const PopupMenuItem(value: '', child: Text('Ungrouped')),
                for (final group in _state.groups)
                  PopupMenuItem(
                      value: _id(group), child: Text('${group['name']}')),
              ],
              onSelected: (id) {
                final target = id.isEmpty ? null : id;
                if (target != entry['group_id']) {
                  _moveEntry(entry, target, _inGroup(target).length);
                }
              },
            ),
            IconButton(
                tooltip: 'Edit ${entry['name']}',
                onPressed: _disabled
                    ? null
                    : () => _entryDialog('withdrawal', entry: entry),
                icon: const Icon(Icons.edit_outlined, size: 18)),
            IconButton(
                tooltip: 'Delete ${entry['name']}',
                onPressed: _disabled
                    ? null
                    : () => _confirm(
                        'Remove withdrawal?',
                        'Only this planning item is removed. Its bank source is untouched.',
                        'entry_delete',
                        {'id': entry['id']}),
                icon: const Icon(Icons.delete_outline, size: 18)),
          ],
        ),
      ]),
    );
  }

  Widget _sourceDetails(Json entry) {
    final snapshot = entry['source_snapshot'];
    if (entry['source_transaction_id'] == null && snapshot == null) {
      return const SizedBox.shrink();
    }
    final changed = sourceChanged(entry);
    final current = entry['source_current'];
    final unavailable = current == null;
    final details = current is Map
        ? current
        : snapshot is Map
            ? snapshot
            : null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            unavailable
                ? 'Bank source unavailable. Plan retained.'
                : changed
                    ? 'Bank source changed. Review before refreshing.'
                    : 'Linked bank source (read-only)',
            style: TextStyle(
                color: unavailable || changed ? _danger : _muted,
                fontSize: 11)),
        if (details != null)
          Text(
              '${details['name'] ?? details['merchant_name'] ?? details['description'] ?? 'Bank transaction'}'
              ' / ${details['posted_date'] ?? details['transaction_date'] ?? 'date unavailable'}'
              ' / ${money(integer(details['amount_minor']))}'
              ' / ${details['status'] ?? 'status unavailable'}',
              style: const TextStyle(color: _muted, fontSize: 11)),
        if (entry['source_transaction_id'] != null)
          Wrap(spacing: 8, children: [
            if (changed && !unavailable)
              TextButton(
                  onPressed: _disabled
                      ? null
                      : () => _confirm(
                          'Refresh planning item?',
                          'Replace the planned name and amount with the current bank source. '
                              'The bank transaction will not change.',
                          'source_refresh',
                          {'id': entry['id']}),
                  child: const Text('Refresh from source')),
            TextButton(
                onPressed: _disabled
                    ? null
                    : () => _confirm(
                        'Unlink bank source?',
                        'Keep this planning item and its independent amount.',
                        'source_unlink',
                        {'id': entry['id']}),
                child: const Text('Unlink source')),
          ]),
      ]),
    );
  }

  Widget _deposits() => _panel(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Deposit pool',
              style: TextStyle(
                  fontSize: 18, color: _ink, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text(
              'Explicit planning deposits, not an account balance or automatic import.',
              style: TextStyle(color: _muted, fontSize: 12)),
          if (_state.deposits.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                    'Start with a deposit. Nothing is added automatically.',
                    style: TextStyle(color: _muted))),
          for (final entry in _state.deposits)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('${entry['name']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        Text(money(integer(entry['amount_minor'])),
                            style: const TextStyle(
                                color: _teal, fontWeight: FontWeight.w700)),
                        IconButton(
                            tooltip: 'Edit ${entry['name']}',
                            onPressed: _disabled
                                ? null
                                : () => _entryDialog('deposit', entry: entry),
                            icon: const Icon(Icons.edit_outlined, size: 18)),
                        IconButton(
                            tooltip: 'Delete ${entry['name']}',
                            onPressed: _disabled
                                ? null
                                : () => _confirm(
                                    'Remove deposit?',
                                    'This reduces plan capacity. Bank transactions remain unchanged.',
                                    'entry_delete',
                                    {'id': entry['id']}),
                            icon: const Icon(Icons.delete_outline, size: 18)),
                      ],
                    ),
                    _sourceDetails(entry),
                  ]),
            ),
        ],
      ));

  Widget _dialogError(StateSetter update, bool busy) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            const SizedBox(height: 12),
            Semantics(
                liveRegion: true,
                child: Text(_error!, style: const TextStyle(color: _danger))),
          ],
          if (_conflict)
            TextButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        update(() {});
                        await _load();
                        if (mounted) update(() {});
                      },
                icon: const Icon(Icons.refresh),
                label: const Text('Reload, then reapply')),
        ],
      );

  Future<void> _entryDialog(String kind, {Json? entry}) async {
    final name = TextEditingController(text: '${entry?['name'] ?? ''}');
    final amount = TextEditingController(
        text:
            entry == null ? '' : decimalMoney(integer(entry['amount_minor'])));
    final form = GlobalKey<FormState>();
    String groupId = '${entry?['group_id'] ?? ''}';
    String sourceId = '${entry?['source_transaction_id'] ?? ''}';
    final labelIds = <String>{
      for (final link in _state.entryLabels)
        if (link['entry_id'] == entry?['id']) '${link['label_id']}',
    };
    var busy = false;
    final month = widget.month;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(builder: (context, update) {
        final sources = widget.transactions
            .where((row) =>
                eligibleBudgeteerSource(row, kind) &&
                !_state.entries.any((existing) =>
                    existing['id'] != entry?['id'] &&
                    existing['source_transaction_id'] == row['id']))
            .toList();
        final sourceExists = sources.any((row) => row['id'] == sourceId);
        final validGroup =
            groupId.isEmpty || _state.groups.any((row) => row['id'] == groupId);
        return _ControllerScope(
            controllers: [name, amount],
            child: AlertDialog(
              title: Text('${entry == null ? 'Add' : 'Edit'} $kind'),
              content: SizedBox(
                  width: 460,
                  child: SingleChildScrollView(
                    child: Form(
                        key: form,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                                'Planning only. No bank data is changed.',
                                style: TextStyle(color: _muted, fontSize: 12)),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              initialValue: sourceId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Bank source (optional)'),
                              items: [
                                const DropdownMenuItem(
                                    value: '',
                                    child: Text('Manual planning item')),
                                if (sourceId.isNotEmpty && !sourceExists)
                                  DropdownMenuItem(
                                      value: sourceId,
                                      child: const Text(
                                          'Existing source (unavailable)')),
                                for (final source in sources)
                                  DropdownMenuItem(
                                      value: _id(source),
                                      child: Text(
                                          '${source['name'] ?? source['merchant_name'] ?? source['description'] ?? 'Transaction'}'
                                          ' / ${money(integer(source['amount_minor']))}'
                                          ' / ${source['posted_date'] ?? source['transaction_date'] ?? ''}',
                                          overflow: TextOverflow.ellipsis)),
                              ],
                              onChanged: busy
                                  ? null
                                  : (value) => update(() {
                                        sourceId = value ?? '';
                                        final matches = sources.where(
                                            (row) => row['id'] == sourceId);
                                        if (matches.isNotEmpty) {
                                          final source = matches.first;
                                          name.text =
                                              '${source['name'] ?? source['merchant_name'] ?? source['description'] ?? 'Bank transaction'}';
                                          amount.text = decimalMoney(
                                              integer(source['amount_minor'])
                                                  .abs());
                                        }
                                      }),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                                controller: name,
                                enabled: !busy,
                                decoration:
                                    const InputDecoration(labelText: 'Name'),
                                maxLength: 120,
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                        ? 'Enter a name.'
                                        : null),
                            const SizedBox(height: 8),
                            TextFormField(
                                controller: amount,
                                enabled: !busy,
                                decoration: const InputDecoration(
                                    labelText: 'Amount (USD)',
                                    prefixText: r'$ '),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                validator: (value) {
                                  try {
                                    if (parseMoney(value ?? '') <= 0) {
                                      return 'Enter an amount above zero.';
                                    }
                                  } on FormatException {
                                    return 'Use a valid positive USD amount, for example 125.50.';
                                  }
                                  return null;
                                }),
                            if (kind == 'withdrawal') ...[
                              const SizedBox(height: 16),
                              DropdownButtonFormField<String>(
                                key: ValueKey(
                                    'entry-group-$validGroup-$groupId'),
                                initialValue: validGroup ? groupId : '',
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: 'Group'),
                                items: [
                                  const DropdownMenuItem(
                                      value: '', child: Text('Ungrouped')),
                                  for (final group in _state.groups)
                                    DropdownMenuItem(
                                        value: _id(group),
                                        child: Text('${group['name']}',
                                            overflow: TextOverflow.ellipsis)),
                                ],
                                onChanged: busy
                                    ? null
                                    : (value) =>
                                        update(() => groupId = value ?? ''),
                              ),
                              const SizedBox(height: 16),
                              const Text('Reusable labels',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                              Wrap(spacing: 6, runSpacing: 4, children: [
                                for (final label in _state.labels)
                                  FilterChip(
                                      label: Text('${label['name']}'),
                                      selected: labelIds.contains(_id(label)),
                                      onSelected: busy
                                          ? null
                                          : (selected) => update(() {
                                                selected
                                                    ? labelIds.add(_id(label))
                                                    : labelIds
                                                        .remove(_id(label));
                                              })),
                              ]),
                              TextButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          await _labelsDialog();
                                          if (context.mounted) update(() {});
                                        },
                                  child: const Text('Create or edit labels')),
                            ],
                            _dialogError(update, busy),
                          ],
                        )),
                  )),
              actions: [
                TextButton(
                    onPressed: busy ? null : () => Navigator.pop(dialogContext),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: busy || _conflict || _loading
                        ? null
                        : () async {
                            if (!form.currentState!.validate() ||
                                widget.month != month) {
                              return;
                            }
                            update(() => busy = true);
                            final result = await _mutate('entry_save', {
                              if (entry != null) 'id': entry['id'],
                              'kind': kind,
                              'name': name.text.trim(),
                              'amount_minor': parseMoney(amount.text),
                              'group_id': kind == 'withdrawal' &&
                                      validGroup &&
                                      groupId.isNotEmpty
                                  ? groupId
                                  : null,
                              if (entry == null ||
                                  sourceId !=
                                      '${entry['source_transaction_id'] ?? ''}')
                                'source_transaction_id':
                                    sourceId.isEmpty ? null : sourceId,
                              'label_ids': kind == 'withdrawal'
                                  ? labelIds
                                      .where((id) => _state.labels
                                          .any((label) => label['id'] == id))
                                      .toList()
                                  : <String>[],
                            });
                            if (!dialogContext.mounted) return;
                            if (result) {
                              Navigator.pop(dialogContext);
                            } else {
                              update(() => busy = false);
                            }
                          },
                    child: Text(busy ? 'Saving...' : 'Save $kind')),
              ],
            ));
      }),
    );
  }

  Future<void> _namedDialog(bool label, {Json? row}) async {
    final name = TextEditingController(text: '${row?['name'] ?? ''}');
    final form = GlobalKey<FormState>();
    var color = '${row?['color_key'] ?? 'teal'}';
    if (!_palette.containsKey(color)) color = 'teal';
    var busy = false;
    final type = label ? 'label' : 'group';
    final month = widget.month;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => _ControllerScope(
            controllers: [name],
            child: AlertDialog(
              title: Text('${row == null ? 'Create' : 'Edit'} $type'),
              content: SizedBox(
                  width: 360,
                  child: SingleChildScrollView(
                    child: Form(
                        key: form,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                                controller: name,
                                enabled: !busy,
                                decoration: InputDecoration(
                                    labelText:
                                        '${label ? 'Label' : 'Group'} name'),
                                maxLength: 80,
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                        ? 'Enter a name.'
                                        : null),
                            const SizedBox(height: 12),
                            const Text('Color'),
                            Wrap(spacing: 6, runSpacing: 4, children: [
                              for (final item in _palette.entries)
                                ChoiceChip(
                                    label: Text(item.key),
                                    avatar: Icon(Icons.circle,
                                        color: item.value, size: 14),
                                    selected: color == item.key,
                                    onSelected: busy
                                        ? null
                                        : (_) =>
                                            update(() => color = item.key)),
                            ]),
                            _dialogError(update, busy),
                          ],
                        )),
                  )),
              actions: [
                TextButton(
                    onPressed: busy ? null : () => Navigator.pop(dialogContext),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: busy || _conflict || _loading
                        ? null
                        : () async {
                            if (!form.currentState!.validate() ||
                                widget.month != month) {
                              return;
                            }
                            update(() => busy = true);
                            final result = await _mutate('${type}_save', {
                              if (row != null) 'id': row['id'],
                              'name': name.text.trim(),
                              'color_key': color,
                              if (label && row != null)
                                'expected_updated_at': _state.labels
                                        .where(
                                            (item) => item['id'] == row['id'])
                                        .map((item) => item['updated_at'])
                                        .firstOrNull ??
                                    row['updated_at'],
                            });
                            if (!dialogContext.mounted) return;
                            if (result) {
                              Navigator.pop(dialogContext);
                            } else {
                              update(() => busy = false);
                            }
                          },
                    child: Text(busy ? 'Saving...' : 'Save $type')),
              ],
            )),
      ),
    );
  }

  Future<void> _labelsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Reusable labels'),
          content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                        'Shared across monthly plans. Deleting a label removes '
                        'its assignments, never its withdrawals.',
                        style: TextStyle(color: _muted, fontSize: 12)),
                    if (_state.labels.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No custom labels yet.')),
                    for (final label in _state.labels)
                      Row(children: [
                        Icon(Icons.sell_outlined,
                            color: _color(label), size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text('${label['name']}')),
                        IconButton(
                            tooltip: 'Edit label ${label['name']}',
                            onPressed: _disabled
                                ? null
                                : () async {
                                    await _namedDialog(true, row: label);
                                    if (context.mounted) update(() {});
                                  },
                            icon: const Icon(Icons.edit_outlined, size: 18)),
                        IconButton(
                            tooltip: 'Delete label ${label['name']}',
                            onPressed: _disabled
                                ? null
                                : () async {
                                    await _confirm(
                                        'Delete label?',
                                        'Remove this label from all plans. Planning entries remain.',
                                        'label_delete', {
                                      'id': label['id'],
                                      'expected_updated_at': label['updated_at']
                                    });
                                    if (context.mounted) update(() {});
                                  },
                            icon: const Icon(Icons.delete_outline, size: 18)),
                      ]),
                    _dialogError(update, false),
                  ],
                ),
              )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
            FilledButton.icon(
                onPressed: _disabled
                    ? null
                    : () async {
                        await _namedDialog(true);
                        if (context.mounted) update(() {});
                      },
                icon: const Icon(Icons.add),
                label: const Text('New label')),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(
      String title, String message, String operation, Json payload) async {
    var busy = false;
    final month = widget.month;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(message), _dialogError(update, busy)],
          )),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: busy || _conflict || _loading
                    ? null
                    : () async {
                        if (widget.month != month) return;
                        update(() => busy = true);
                        final refreshedPayload = <String, dynamic>{...payload};
                        if (operation == 'label_delete') {
                          final matching = _state.labels
                              .where((row) => row['id'] == payload['id']);
                          if (matching.isNotEmpty) {
                            refreshedPayload['expected_updated_at'] =
                                matching.first['updated_at'];
                          }
                        }
                        final result =
                            await _mutate(operation, refreshedPayload);
                        if (!dialogContext.mounted) return;
                        if (result) {
                          Navigator.pop(dialogContext);
                        } else {
                          update(() => busy = false);
                        }
                      },
                child: Text(busy ? 'Saving...' : 'Confirm')),
          ],
        ),
      ),
    );
  }
}

class _ControllerScope extends StatefulWidget {
  final List<TextEditingController> controllers;
  final Widget child;
  const _ControllerScope({required this.controllers, required this.child});

  @override
  State<_ControllerScope> createState() => _ControllerScopeState();
}

class _ControllerScopeState extends State<_ControllerScope> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
