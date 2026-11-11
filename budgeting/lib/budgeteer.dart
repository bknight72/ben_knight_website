import 'package:flutter/material.dart';

import 'budgeteer_domain.dart';
import 'domain.dart';
import 'repository.dart';

const _ink = Color(0xff102e2c);
const _teal = Color(0xff17695c);
const _canvas = Color(0x00202421);
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
  final Widget? toolbar;
  final Widget? footer;
  final bool groupsOnly;

  const BudgeteerPage({
    super.key,
    required this.repository,
    required this.month,
    required this.transactions,
    this.toolbar,
    this.footer,
    this.groupsOnly = false,
  });

  @override
  State<BudgeteerPage> createState() => _BudgeteerPageState();
}

class _BudgeteerPageState extends State<BudgeteerPage> {
  BudgeteerState _state = BudgeteerState.empty();
  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  bool _conflict = false;
  String? _error;
  String? _selected;
  final _groupKeys = <Object?, GlobalKey>{};
  final _collapsedGroups = <Object?>{};
  final _contentScroll = ScrollController();
  final _contentKey = GlobalKey();
  GlobalKey? _selectedGroup;
  int _tab = 0;
  String? _retryOperation;
  Json? _retryPayload;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _contentScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BudgeteerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.month != widget.month ||
        oldWidget.repository != widget.repository ||
        oldWidget.groupsOnly != widget.groupsOnly) {
      _generation++;
      _state = BudgeteerState.empty();
      _loaded = false;
      _selected = null;
      _selectedGroup = null;
      _groupKeys.clear();
      _collapsedGroups.clear();
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
      _loaded = false;
      _error = null;
    });
    try {
      final repository = widget.repository;
      final month = widget.month;
      final existing = await repository.budgeteerRead(month);
      if (!mounted || generation != _generation) return;
      final result = widget.groupsOnly
          ? existing
          : await repository.budgeteerMutate(
              month, existing.revision, 'sources_include', {},
              groupsRevision: existing.groupsRevision);
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = result;
        _loaded = true;
        _conflict = false;
        _retryOperation = null;
        _retryPayload = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _conflict = error.toString().contains('budgeteer_conflict');
        _error = _conflict
            ? 'This plan or shared groups changed elsewhere. Reload to include all transactions.'
            : error is BudgeteerSchemaException
                ? error.message
                : widget.groupsOnly
                    ? 'Could not load shared groups. Please retry.'
                    : 'Could not load this plan. Please retry.';
      });
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
      _error = null;
    });
    try {
      final result = await widget.repository.budgeteerMutate(
          widget.month, _state.revision, operation, payload,
          groupsRevision: _state.groupsRevision);
      if (!mounted || generation != _generation) return false;
      setState(() {
        _state = result;
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
            ? 'This plan or shared groups changed elsewhere. Reload, review, then reapply your change.'
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
  Color _color(Json? row) {
    final key = '${row?['color_key'] ?? ''}';
    if (RegExp(r'^hex_[0-9a-f]{6}$').hasMatch(key)) {
      return Color(0xff000000 | int.parse(key.substring(4), radix: 16));
    }
    return _palette[key] ?? _teal;
  }

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
      'groups': [
        ..._state.depositGroups,
        ...groups.where((g) => (g['kind'] ?? 'withdrawal') == 'withdrawal')
      ].map(_id).toList(),
      'entries': [
        for (final entry in [..._state.deposits, ...withdrawals])
          {'id': entry['id'], 'group_id': entry['group_id']},
      ],
    });
  }

  Future<void> _moveGroup(int index, int target) async {
    final ordered = _state.orderedGroups;
    if (target < 0 || target >= ordered.length) return;
    final moving = ordered[index];
    final siblings = _state.childrenOf(moving['parent_group_id'] as String?);
    final siblingIndex = siblings.indexWhere((g) => g['id'] == moving['id']);
    final destination = siblingIndex + (target > index ? 1 : -1);
    if (destination < 0 || destination >= siblings.length) return;
    siblings.insert(destination, siblings.removeAt(siblingIndex));
    final groups = <Json>[];
    void visit(String? parent) {
      for (final group in parent == moving['parent_group_id']
          ? siblings
          : _state.childrenOf(parent)) {
        groups.add(group);
        visit(group['id'] as String);
      }
    }

    visit(null);
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

  Widget _panel(
          {required Widget child,
          Key? key,
          Color color = Colors.white,
          EdgeInsetsGeometry padding = const EdgeInsets.all(20),
          Color? outline}) =>
      Container(
        key: key,
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _ink.withValues(alpha: .07)),
        ),
        foregroundDecoration: outline == null
            ? null
            : BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: outline, width: 3)),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final content = SingleChildScrollView(
          key: _contentKey,
          controller: _contentScroll,
          physics: const AlwaysScrollableScrollPhysics(),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                          child: Text(_error!,
                              style: const TextStyle(color: _danger))),
                      TextButton.icon(
                          onPressed: _saving || _loading ? null : _load,
                          icon: const Icon(Icons.refresh),
                          label: Text(_conflict
                              ? 'Reload plan to reapply'
                              : widget.groupsOnly
                                  ? 'Reload groups'
                                  : 'Reload plan')),
                      if (!_conflict && _retryOperation != null)
                        TextButton.icon(
                            onPressed: _saving || _loading
                                ? null
                                : () =>
                                    _mutate(_retryOperation!, _retryPayload!),
                            icon: const Icon(Icons.replay),
                            label: const Text('Retry change')),
                    ],
                  )),
              const SizedBox(height: 16),
            ],
            if (!_loading && _loaded && widget.groupsOnly) ...[
              const Text(
                  'Groups are shared across all months. Changes here apply everywhere in Budgeteer. '
                  'Funding priority and transaction assignments remain monthly.',
                  style: TextStyle(color: _muted)),
              const SizedBox(height: 20),
              _managedGroups('deposit'),
              const SizedBox(height: 20),
              _managedGroups('withdrawal'),
            ],
            if (!_loading && _loaded && !widget.groupsOnly) ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (_tab == 2)
                  FilledButton.icon(
                      onPressed:
                          _disabled ? null : () => _entryDialog('deposit'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add deposit')),
                if (_tab != 2)
                  FilledButton.icon(
                      onPressed:
                          _disabled ? null : () => _entryDialog('withdrawal'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add withdrawal')),
                if (_state.excludedSourceCount > 0)
                  TextButton.icon(
                      onPressed: _disabled
                          ? null
                          : () => _confirm(
                              'Restore excluded transactions?',
                              'Include removed bank transactions again if they are still '
                                  'eligible this month. Unlinked sources can also be added '
                                  'again alongside their independent planning items.',
                              'sources_restore',
                              {}),
                      icon: const Icon(Icons.restore),
                      label: Text(
                          'Restore excluded transactions (${_state.excludedSourceCount})')),
              ]),
              const SizedBox(height: 12),
              const Text(
                  'Groups are shared across all months. Funding priority and transactions are monthly.',
                  style: TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 12),
              if (_tab != 2) _withdrawals(),
              if (_tab == 2) _deposits(),
            ],
            if (widget.footer != null) ...[
              const SizedBox(height: 28),
              widget.footer!,
            ],
          ]));
      if (widget.groupsOnly) return content;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.toolbar != null) ...[
          widget.toolbar!,
          const SizedBox(height: 12),
        ],
        SegmentedButton<int>(
          style: ButtonStyle(
            foregroundColor: const WidgetStatePropertyAll(Colors.white),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected) ? _teal : _ink),
          ),
          showSelectedIcon: constraints.maxWidth >= 560,
          segments: [
            ButtonSegment(
                value: 0,
                label:
                    const Text('Tower of Money', textAlign: TextAlign.center),
                icon: constraints.maxWidth >= 560
                    ? const Icon(Icons.account_tree_outlined)
                    : null),
            ButtonSegment(
                value: 1,
                label: const Text('Withdrawals', textAlign: TextAlign.center),
                icon: constraints.maxWidth >= 560
                    ? const Icon(Icons.view_list_outlined)
                    : null),
            ButtonSegment(
                value: 2,
                label: const Text('Deposits'),
                icon: constraints.maxWidth >= 560
                    ? const Icon(Icons.savings_outlined)
                    : null),
          ],
          selected: {_tab},
          onSelectionChanged: (value) => setState(() => _tab = value.single),
        ),
        const SizedBox(height: 12),
        Expanded(
            child:
                IndexedStack(index: _tab, sizing: StackFit.expand, children: [
          _loading || !_loaded || _error != null
              ? SingleChildScrollView(
                  child: Column(children: [
                  if (_loading) const CircularProgressIndicator(),
                  if (_error != null)
                    Text(_error!, style: const TextStyle(color: _danger)),
                  if (!_loading)
                    TextButton(
                        onPressed: _load, child: const Text('Reload plan')),
                ]))
              : LayoutBuilder(builder: (context, tower) {
                  if (tower.maxHeight >= 600 && tower.maxWidth >= 650) {
                    return _funding();
                  }
                  return SingleChildScrollView(
                      child: SizedBox(
                    height:
                        tower.maxHeight < (tower.maxWidth >= 650 ? 600 : 920)
                            ? (tower.maxWidth >= 650 ? 600 : 920)
                            : tower.maxHeight,
                    child: _funding(),
                  ));
                }),
          _tab != 2 ? content : const SizedBox.shrink(),
          _tab == 2 ? content : const SizedBox.shrink(),
        ])),
      ]);
    });
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

  Widget _managedGroups(String kind) {
    final deposit = kind == 'deposit';
    final groups = deposit ? _state.depositGroups : _state.orderedGroups;
    return _panel(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text(deposit ? 'Deposit groups' : 'Withdrawal groups',
                style: const TextStyle(
                    color: _ink, fontSize: 20, fontWeight: FontWeight.w700)),
            TextButton.icon(
                onPressed: _disabled ? null : () => _namedDialog(kind: kind),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(
                    deposit ? 'Add deposit group' : 'Add withdrawal group')),
          ]),
      if (groups.isEmpty)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
                deposit
                    ? 'No deposit groups yet.'
                    : 'No withdrawal groups yet.',
                style: const TextStyle(color: _muted))),
      for (final group in groups)
        Padding(
            key: ValueKey('managed-group-${_id(group)}'),
            padding: EdgeInsets.only(
                left: deposit
                    ? 0
                    : (_state.depthOf(_id(group)) * 16.0)
                        .clamp(0, 64)
                        .toDouble()),
            child: Row(children: [
              Icon(Icons.circle, size: 12, color: _color(group)),
              const SizedBox(width: 12),
              Expanded(
                  child: Text('${group['name']}',
                      style: const TextStyle(
                          color: _ink, fontWeight: FontWeight.w600))),
              IconButton(
                  tooltip:
                      'Edit ${deposit ? 'deposit group' : 'group'} ${group['name']}',
                  onPressed: _disabled
                      ? null
                      : () => _namedDialog(row: group, kind: kind),
                  icon: const Icon(Icons.edit_outlined, size: 18)),
              IconButton(
                  tooltip:
                      'Delete ${deposit ? 'deposit group' : 'group'} ${group['name']}',
                  onPressed: _disabled
                      ? null
                      : () => _confirm(
                          deposit ? 'Delete deposit group?' : 'Delete group?',
                          deposit
                              ? 'Its deposits move to Ungrouped in every month. No deposits are removed.'
                              : 'Its direct withdrawals move to Ungrouped in every month. '
                                  'No transactions are removed. Immediate children move to its former parent '
                                  'across all months; descendants and their assignments remain.',
                          'group_delete',
                          {'id': group['id']}),
                  icon: const Icon(Icons.delete_outline, size: 18)),
            ])),
    ]));
  }

  void _scrollToGroup(Object? id) {
    final path = id == null ? [null] : _state.pathOf(id).map(_id).toList();
    if (_tab != 1 || path.any(_collapsedGroups.contains)) {
      setState(() {
        _tab = 1;
        _collapsedGroups.removeAll(path);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToGroup(id);
      });
      return;
    }
    final key = _groupKeys[id];
    if (key != null && _selectedGroup == key) {
      setState(() => _selectedGroup = null);
      return;
    }
    final target = key?.currentContext?.findRenderObject();
    final viewport = _contentKey.currentContext?.findRenderObject();
    if (target is! RenderBox ||
        viewport is! RenderBox ||
        !_contentScroll.hasClients) {
      return;
    }
    setState(() => _selectedGroup = key);
    // Move only the content pane, not the nested reorderable list viewports.
    final offset = _contentScroll.offset +
        target.localToGlobal(Offset.zero, ancestor: viewport).dy;
    _contentScroll.animateTo(
        offset.clamp(_contentScroll.position.minScrollExtent,
            _contentScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut);
  }

  Widget _funding() {
    final allocation = _state.allocation;
    final capacity = allocation.deposits;
    final bar = Semantics(
      label: 'Funding bar. ${money(capacity)} deposited. '
          '${money(allocation.remaining)} remaining. '
          '${money(allocation.deficit)} unfunded.',
      child: _fundingDiagram(allocation),
    );
    return Column(
      key: const ValueKey('tower-of-money-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: bar),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, constraints) {
          final allocation = _state.allocation;
          final width = constraints.maxWidth;
          final items = [
            _total('Pooled deposits', allocation.deposits, _teal),
            _total('Withdrawals', allocation.withdrawals, _ink),
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
                  width: width >= 600 ? (width - 24) / 3 : width, child: item),
          ]);
        }),
      ],
    );
  }

  Widget _fundingDiagram(BudgeteerAllocation allocation) =>
      LayoutBuilder(builder: (context, constraints) {
        const barWidth = 19.0;
        const gap = 8.0;
        const labelHeight = 38.0;
        const overflowColor = Color(0xff7f1d1d);
        final plannedFlows = <({String source, String target, int amount})>[];
        void flow(String source, String target, int amount) {
          if (amount > 0) {
            plannedFlows.add((source: source, target: target, amount: amount));
          }
        }

        void incomeFlow(String target, int amount, int funded) {
          flow('income', target, funded);
          flow('overflow', target, amount - funded);
        }

        final columns = <List<
            ({
              String id,
              String name,
              int amount,
              Color color,
              bool navigable,
              Object? groupId
            })>>[[], [], []];
        void add(int column, String id, String name, int amount, Color color,
            {bool navigable = false, Object? groupId}) {
          if (amount <= 0) return;
          while (columns.length <= column) {
            columns.add([]);
          }
          columns[column].add((
            id: id,
            name: name,
            amount: amount,
            color: color,
            navigable: navigable,
            groupId: groupId
          ));
        }

        for (final deposit in _state.depositInputs) {
          final amount = integer(deposit['amount_minor']);
          add(0, '${deposit['id']}', '${deposit['name']}', amount,
              _color(deposit));
          flow('${deposit['id']}', 'income', amount);
        }
        add(1, 'income', 'Income', allocation.deposits,
            const Color(0xff22c55e));
        add(1, 'overflow', 'Over Income', allocation.deficit, overflowColor);
        void visit(Json group, int column) {
          final id = group['id'] as String;
          final totals = allocation.totals[id]!;
          add(column, 'group:$id', '${group['name']}', totals.subtree,
              _color(group),
              navigable: true, groupId: id);
          final children = _state.childrenOf(id);
          final parent = group['parent_group_id'];
          if (parent == null) {
            incomeFlow('group:$id', totals.subtree, totals.subtreeFunded);
          } else {
            flow('group:$parent', 'group:$id', totals.subtree);
          }
          if (children.isNotEmpty) {
            add(column + 1, 'direct:$id', '${group['name']} / Direct',
                totals.direct, _color(group).withValues(alpha: .65),
                navigable: true, groupId: id);
            flow('group:$id', 'direct:$id', totals.direct);
          }
          for (final child in children) {
            visit(child, column + 1);
          }
        }

        for (final group in _state.childrenOf(null)) {
          visit(group, 2);
        }
        final ungrouped = allocation.totals[null];
        add(2, 'ungrouped', 'Ungrouped', ungrouped?.direct ?? 0, _teal,
            navigable: true);
        incomeFlow(
            'ungrouped', ungrouped?.direct ?? 0, ungrouped?.directFunded ?? 0);
        final total = allocation.deposits + allocation.deficit;
        List<({double top, double labelTop, double height})> columnLayout(
            int column, double scale) {
          final layout = <({double top, double labelTop, double height})>[];
          var top = 0.0;
          var labelBottom = -gap;
          var incomeOffset = 0.0;
          for (final node in columns[column]) {
            if (node.id == 'overflow') top = allocation.deposits * scale;
            final nodeHeight = node.amount * scale;
            final envelope =
                nodeHeight > labelHeight ? nodeHeight : labelHeight;
            final naturalLabelTop = top + (envelope - labelHeight) / 2;
            final labelTop = naturalLabelTop > labelBottom + gap
                ? naturalLabelTop
                : labelBottom + gap;
            labelBottom = labelTop + labelHeight;
            final barTop =
                nodeHeight < labelHeight ? labelBottom - nodeHeight : top;
            if (barTop - top > incomeOffset) incomeOffset = barTop - top;
            layout.add((top: barTop, labelTop: labelTop, height: nodeHeight));
            top += envelope + gap;
          }
          // Income and shortfall form one continuous bar, even with tiny labels.
          if (column == 1) {
            var barTop = incomeOffset;
            for (var i = 0; i < layout.length; i++) {
              final item = layout[i];
              layout[i] = (
                top: barTop,
                labelTop: item.height < labelHeight
                    ? barTop + item.height - labelHeight
                    : item.labelTop,
                height: item.height
              );
              barTop += item.height;
            }
          }
          return layout;
        }

        double heightAt(double scale) {
          var tallest = 0.0;
          for (var column = 0; column < columns.length; column++) {
            for (final item in columnLayout(column, scale)) {
              final bottom = item.top + item.height;
              final labelBottom = item.labelTop + labelHeight;
              if (bottom > tallest) tallest = bottom;
              if (labelBottom > tallest) tallest = labelBottom;
            }
          }
          return tallest;
        }

        var scale = 0.0;
        if (total > 0) {
          if (heightAt(0) >= constraints.maxHeight) {
            // Dense labels need scrolling, but monetary bar ratios stay exact.
            scale = 160 / total;
          } else {
            var upper = constraints.maxHeight / total;
            for (var i = 0; i < 48; i++) {
              final candidate = (scale + upper) / 2;
              if (heightAt(candidate) <= constraints.maxHeight) {
                scale = candidate;
              } else {
                upper = candidate;
              }
            }
          }
        }
        final contentHeight = heightAt(scale);
        final height = contentHeight > constraints.maxHeight
            ? contentHeight
            : constraints.maxHeight;
        final step =
            (constraints.maxWidth - barWidth).clamp(0.0, double.infinity) /
                (columns.length - 1);
        final labelWidth = (step - barWidth - 14).clamp(0.0, double.infinity);
        final nodes = <Widget>[];
        final positions = <String, Offset>{};
        final colors = <String, Color>{};
        final order = <String, int>{};
        for (var column = 0; column < columns.length; column++) {
          final lastColumn = column == columns.length - 1;
          final layout = columnLayout(column, scale);
          for (var i = 0; i < columns[column].length; i++) {
            final node = columns[column][i];
            final top = layout[i].top;
            final nodeHeight = layout[i].height;
            final labelTop = layout[i].labelTop;
            final left = column * step;
            positions[node.id] = Offset(left, top);
            colors[node.id] = node.color;
            order[node.id] = order.length;
            final selected = node.navigable &&
                _selectedGroup != null &&
                _groupKeys[node.groupId] == _selectedGroup;
            final percentage = allocation.deposits > 0
                ? '${(node.amount * 100 / allocation.deposits).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}%'
                : 'N/A';
            final amountKind = node.id == 'overflow'
                ? 'unfunded'
                : node.navigable
                    ? 'planned'
                    : 'deposited';
            final message = '${node.name}: ${money(node.amount)} $amountKind '
                '($percentage of Income)';
            final onTap =
                node.navigable ? () => _scrollToGroup(node.groupId) : null;
            nodes.add(Positioned(
                left: left,
                top: top,
                width: barWidth,
                height: nodeHeight,
                child: Semantics(
                    button: node.navigable,
                    selected: selected,
                    label: '${node.name}, ${money(node.amount)} $amountKind, '
                        '$percentage of Income',
                    child: Tooltip(
                        message: message,
                        child: Material(
                            key: ValueKey('sankey-bar-${node.id}'),
                            color: node.color,
                            child: InkWell(
                                onTap: onTap,
                                child: DecoratedBox(
                                    decoration: BoxDecoration(
                                        border: selected
                                            ? Border.all(color: _ink, width: 3)
                                            : null))))))));
            nodes.add(Positioned(
                left: lastColumn ? left - labelWidth - 6 : left + barWidth + 6,
                top: labelTop,
                width: labelWidth,
                height: labelHeight,
                child: Tooltip(
                    message: message,
                    child: GestureDetector(
                        onTap: onTap,
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: lastColumn
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              Text(node.name,
                                  key: ValueKey('sankey-label-${node.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: node.color,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700)),
                              Text(percentage,
                                  key: ValueKey('sankey-percentage-${node.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: node.color, fontSize: 11)),
                            ])))));
          }
        }
        final links = <(Offset, Offset, double, Color, Color)>[];
        final outputs = <String, int>{};
        final inputs = <String, int>{};
        final flows = plannedFlows
            .where((flow) =>
                positions.containsKey(flow.source) &&
                positions.containsKey(flow.target))
            .toList()
          ..sort((a, b) {
            final targetOrder = order[a.target]!.compareTo(order[b.target]!);
            return targetOrder != 0
                ? targetOrder
                : order[a.source]!.compareTo(order[b.source]!);
          });
        for (final flow in flows) {
          final source = positions[flow.source]!;
          final target = positions[flow.target]!;
          final sourceCents = outputs[flow.source] ?? 0;
          final targetCents = inputs[flow.target] ?? 0;
          links.add((
            Offset(source.dx + barWidth, source.dy + sourceCents * scale),
            Offset(target.dx, target.dy + targetCents * scale),
            flow.amount * scale,
            colors[flow.source]!.withValues(alpha: .35),
            colors[flow.target]!.withValues(alpha: .35)
          ));
          outputs[flow.source] = sourceCents + flow.amount;
          inputs[flow.target] = targetCents + flow.amount;
        }
        return SingleChildScrollView(
            child: SizedBox(
                width: constraints.maxWidth,
                height: height,
                child: CustomPaint(
                    key: const ValueKey('sankey-diagram'),
                    painter: _FundingLinks(links),
                    child: Stack(children: nodes))));
      });

  Widget _withdrawals() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_inGroup(null).isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _groupSection(null, null)),
          for (final group in _state.childrenOf(null))
            Padding(
              key: ValueKey('group-${_id(group)}'),
              padding: const EdgeInsets.only(bottom: 12),
              child: _groupSection(
                  group,
                  _state.orderedGroups
                      .indexWhere((row) => row['id'] == group['id'])),
            ),
        ],
      );

  Widget _groupSection(Json? group, int? groupIndex) {
    final entries = _inGroup(group?['id']);
    final children = group == null ? <Json>[] : _state.childrenOf(group['id']);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final collapsed = _collapsedGroups.contains(group?['id']);
    final siblings =
        group == null ? <Json>[] : _state.childrenOf(group['parent_group_id']);
    final siblingIndex =
        siblings.indexWhere((row) => row['id'] == group?['id']);
    final key = _groupKeys.putIfAbsent(group?['id'], () => GlobalKey());
    return _panel(
        key: key,
        padding: EdgeInsets.all(compact ? 8 : 16),
        outline: _selectedGroup == key ? _color(group) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  expanded: !collapsed,
                  child: IconButton(
                    tooltip:
                        '${collapsed ? 'Expand' : 'Collapse'} ${group?['name'] ?? 'Ungrouped'} group',
                    onPressed: () => setState(() {
                      if (collapsed) {
                        _collapsedGroups.remove(group?['id']);
                      } else {
                        _collapsedGroups.add(group?['id']);
                      }
                    }),
                    icon:
                        Icon(collapsed ? Icons.expand_more : Icons.expand_less),
                  ),
                ),
                Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                        color: _color(group), shape: BoxShape.circle)),
                Text('${group?['name'] ?? 'Ungrouped'}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: _ink)),
                Text(
                    group == null
                        ? money(_state.groupTotals(null).direct)
                        : '${money(_state.groupTotals(group['id']).subtree)} total / '
                            '${money(_state.groupTotals(group['id']).direct)} direct',
                    style: const TextStyle(color: _muted, fontSize: 12)),
                if (group != null) ...[
                  IconButton(
                      tooltip: 'Move ${group['name']} group up',
                      onPressed: _disabled || siblingIndex == 0
                          ? null
                          : () => _moveGroup(groupIndex!, groupIndex - 1),
                      icon: const Icon(Icons.arrow_upward, size: 18)),
                  IconButton(
                      tooltip: 'Move ${group['name']} group down',
                      onPressed:
                          _disabled || siblingIndex == siblings.length - 1
                              ? null
                              : () => _moveGroup(groupIndex!, groupIndex + 1),
                      icon: const Icon(Icons.arrow_downward, size: 18)),
                  IconButton(
                      tooltip: 'Edit group ${group['name']}',
                      onPressed:
                          _disabled ? null : () => _namedDialog(row: group),
                      icon: const Icon(Icons.edit_outlined, size: 18)),
                  IconButton(
                      tooltip: 'Delete group ${group['name']}',
                      onPressed: _disabled
                          ? null
                          : () => _confirm(
                              'Delete group?',
                              'Its direct withdrawals move to Ungrouped in every month. '
                                  'No transactions are removed. Immediate children move to its former parent '
                                  'across all months; descendants and their assignments remain.',
                              'group_delete',
                              {'id': group['id']}),
                      icon: const Icon(Icons.delete_outline, size: 18)),
                ],
              ],
            ),
            if (!collapsed && entries.isEmpty && children.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No withdrawals here yet.',
                      style: TextStyle(color: _muted, fontSize: 12))),
            if (!collapsed)
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
            if (!collapsed)
              for (final child in children)
                Padding(
                  key: ValueKey('group-${_id(child)}'),
                  padding: EdgeInsets.only(top: 12, left: compact ? 4 : 8),
                  child: _groupSection(
                      child,
                      _state.orderedGroups
                          .indexWhere((row) => row['id'] == child['id'])),
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
    final details = Semantics(
        selected: selected,
        child: InkWell(
          onTap: () => setState(() => _selected = _id(entry)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${entry['name']}',
                        style: const TextStyle(
                            color: _ink, fontWeight: FontWeight.w700)),
                    Text(money(integer(entry['amount_minor'])),
                        style: const TextStyle(color: _ink, fontSize: 16)),
                  ],
                ),
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
        ));
    final controls = Wrap(
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
                    child:
                        Icon(Icons.drag_indicator, color: _muted, size: 20)))),
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
            for (final group in _state.orderedGroups)
              PopupMenuItem(value: _id(group), child: Text('${group['name']}')),
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
                    'Remove this item from the plan. Its bank source stays '
                        'untouched and will not be added back automatically this month.',
                    'entry_delete',
                    {'id': entry['id']}),
            icon: const Icon(Icons.delete_outline, size: 18)),
      ],
    );
    return Container(
      key: key,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: selected ? const Color(0xffe8f2ec) : _canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? _teal : Colors.transparent, width: 2)),
      child: LayoutBuilder(builder: (context, constraints) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [details, _sourceDetails(entry)],
        );
        if (constraints.maxWidth >= 640) {
          return Row(children: [
            Expanded(child: content),
            const SizedBox(width: 8),
            controls,
          ]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [content, controls],
        );
      }),
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
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed:
                      _disabled ? null : () => _namedDialog(kind: 'deposit'),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add deposit group'))),
          const SizedBox(height: 4),
          const Text(
              'Eligible deposits from all accounts are included by default. '
              'This is a funding plan, not an account balance.',
              style: TextStyle(color: _muted, fontSize: 12)),
          if (_state.deposits.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                    'No included deposits this month. Add a planning deposit '
                    'or restore excluded transactions.',
                    style: TextStyle(color: _muted))),
          for (final group in [null, ..._state.depositGroups])
            if (group != null || _state.directDeposits(null).isNotEmpty)
              Padding(
                  key: ValueKey(
                      'deposit-pool-group-${group?['id'] ?? 'ungrouped'}'),
                  padding: const EdgeInsets.only(top: 12),
                  child: _panel(
                    padding: EdgeInsets.all(
                        MediaQuery.sizeOf(context).width < 600 ? 8 : 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                            spacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Icon(Icons.circle,
                                  color: _color(group), size: 12),
                              Text('${group?['name'] ?? 'Ungrouped'}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              Text(money(_state
                                  .directDeposits(group?['id'])
                                  .fold<int>(
                                      0,
                                      (sum, entry) =>
                                          sum +
                                          integer(entry['amount_minor'])))),
                              if (group != null) ...[
                                IconButton(
                                    tooltip:
                                        'Edit deposit group ${group['name']}',
                                    onPressed: _disabled
                                        ? null
                                        : () => _namedDialog(
                                            row: group, kind: 'deposit'),
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 18)),
                                IconButton(
                                    tooltip:
                                        'Delete deposit group ${group['name']}',
                                    onPressed: _disabled
                                        ? null
                                        : () => _confirm(
                                                'Delete deposit group?',
                                                'Its deposits move to Ungrouped in every month. No deposits are removed.',
                                                'group_delete', {
                                              'id': group['id']
                                            }),
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18)),
                              ],
                            ]),
                        for (final entry in _state.directDeposits(group?['id']))
                          Padding(
                            padding: const EdgeInsets.only(top: 12, left: 12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text('${entry['name']}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      Text(
                                          money(integer(entry['amount_minor'])),
                                          style: TextStyle(
                                              color: _color(group),
                                              fontWeight: FontWeight.w700)),
                                      IconButton(
                                          tooltip: 'Edit ${entry['name']}',
                                          onPressed: _disabled
                                              ? null
                                              : () => _entryDialog('deposit',
                                                  entry: entry),
                                          icon: const Icon(Icons.edit_outlined,
                                              size: 18)),
                                      IconButton(
                                          tooltip: 'Delete ${entry['name']}',
                                          onPressed: _disabled
                                              ? null
                                              : () => _confirm(
                                                      'Remove deposit?',
                                                      'This reduces plan capacity. Its bank source stays '
                                                          'untouched and will not be added back automatically this month.',
                                                      'entry_delete',
                                                      {
                                                        'id': entry['id']
                                                      }),
                                          icon: const Icon(Icons.delete_outline,
                                              size: 18)),
                                    ],
                                  ),
                                  _sourceDetails(entry),
                                ]),
                          ),
                      ],
                    ),
                  )),
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
    var busy = false;
    final month = widget.month;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(builder: (context, update) {
        final sources = widget.transactions
            .where((row) =>
                eligibleBudgeteerSource(row, kind) &&
                '${row['posted_date'] ?? row['transaction_date'] ?? ''}'
                    .startsWith('$month-') &&
                !_state.entries.any((existing) =>
                    existing['id'] != entry?['id'] &&
                    existing['source_transaction_id'] == row['id']))
            .toList();
        final sourceExists = sources.any((row) => row['id'] == sourceId);
        final validGroup = groupId.isEmpty ||
            _state.groups.any((row) =>
                row['id'] == groupId && (row['kind'] ?? 'withdrawal') == kind);
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
                            ...[
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
                                  for (final group in kind == 'deposit'
                                      ? _state.depositGroups
                                      : _state.orderedGroups)
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
                              'group_id': validGroup && groupId.isNotEmpty
                                  ? groupId
                                  : null,
                              if (entry == null ||
                                  sourceId !=
                                      '${entry['source_transaction_id'] ?? ''}')
                                'source_transaction_id':
                                    sourceId.isEmpty ? null : sourceId,
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

  Future<Color?> _pickColor(Color initial) {
    var hsv = HSVColor.fromColor(initial);
    return showDialog<Color>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(builder: (context, update) {
              final hex =
                  hsv.toColor().toARGB32().toRadixString(16).substring(2);
              return AlertDialog(
                title: const Text('Choose group color'),
                content: SizedBox(
                    width: 300,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      LayoutBuilder(builder: (context, constraints) {
                        void select(Offset position) => update(() {
                              hsv = hsv
                                  .withSaturation(
                                      (position.dx / constraints.maxWidth)
                                          .clamp(0.0, 1.0))
                                  .withValue(
                                      (1 - position.dy / 160).clamp(0.0, 1.0));
                            });
                        return Semantics(
                            label: 'Color saturation and brightness area',
                            child: GestureDetector(
                                key: const ValueKey('color-picker-area'),
                                onTapDown: (event) =>
                                    select(event.localPosition),
                                onPanStart: (event) =>
                                    select(event.localPosition),
                                onPanUpdate: (event) =>
                                    select(event.localPosition),
                                child: SizedBox(
                                    height: 160,
                                    child: Stack(children: [
                                      Positioned.fill(
                                          child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                      colors: [
                                            Colors.white,
                                            HSVColor.fromAHSV(1, hsv.hue, 1, 1)
                                                .toColor()
                                          ])))),
                                      const Positioned.fill(
                                          child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                      begin:
                                                          Alignment.topCenter,
                                                      end: Alignment
                                                          .bottomCenter,
                                                      colors: [
                                            Colors.transparent,
                                            Colors.black
                                          ])))),
                                      Positioned(
                                          left: (hsv.saturation *
                                                      constraints.maxWidth -
                                                  7)
                                              .clamp(0.0,
                                                  constraints.maxWidth - 14),
                                          top: ((1 - hsv.value) * 160 - 7)
                                              .clamp(0.0, 146.0),
                                          child: IgnorePointer(
                                              child: Container(
                                                  width: 14,
                                                  height: 14,
                                                  decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      border: Border.all(
                                                          color: Colors.white,
                                                          width: 2),
                                                      boxShadow: const [
                                                        BoxShadow(blurRadius: 2)
                                                      ])))),
                                    ]))));
                      }),
                      const SizedBox(height: 12),
                      Row(children: [
                        Icon(Icons.circle, color: hsv.toColor(), size: 28),
                        const SizedBox(width: 10),
                        Text('#$hex',
                            key: const ValueKey('color-picker-preview')),
                      ]),
                      for (final channel in [
                        'Hue',
                        'Saturation',
                        'Brightness'
                      ]) ...[
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(channel)),
                        Slider(
                            key: ValueKey('color-picker-$channel'),
                            semanticFormatterCallback: (value) => channel ==
                                    'Hue'
                                ? 'Hue ${value.round()} degrees'
                                : '$channel ${(value * 100).round()} percent',
                            max: channel == 'Hue' ? 360 : 1,
                            value: channel == 'Hue'
                                ? hsv.hue
                                : channel == 'Saturation'
                                    ? hsv.saturation
                                    : hsv.value,
                            onChanged: (value) => update(() {
                                  hsv = channel == 'Hue'
                                      ? hsv.withHue(value)
                                      : channel == 'Saturation'
                                          ? hsv.withSaturation(value)
                                          : hsv.withValue(value);
                                })),
                      ],
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(dialogContext, hsv.toColor()),
                      child: const Text('Apply color')),
                ],
              );
            }));
  }

  Future<void> _namedDialog({Json? row, String kind = 'withdrawal'}) async {
    kind = '${row?['kind'] ?? kind}';
    final name = TextEditingController(text: '${row?['name'] ?? ''}');
    final form = GlobalKey<FormState>();
    final color = '${row?['color_key'] ?? 'teal'}';
    final customColor = TextEditingController(
        text: '#${_color({
          'color_key': color
        }).toARGB32().toRadixString(16).substring(2)}');
    String customHex() =>
        customColor.text.trim().replaceFirst(RegExp(r'^#'), '').toLowerCase();
    var busy = false;
    final type = kind == 'deposit' ? 'deposit group' : 'group';
    var parentId = '${row?['parent_group_id'] ?? ''}';
    final month = widget.month;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final exists = row == null || _group(row['id']) != null;
          final descendants = row == null || !exists
              ? <String>{}
              : _state.descendantIds(row['id']);
          final validParent = parentId.isEmpty ||
              (_group(parentId) != null &&
                  parentId != row?['id'] &&
                  !descendants.contains(parentId));
          final needsReview = !exists || !validParent;
          return _ControllerScope(
              controllers: [name, customColor],
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
                              const Text(
                                  'This group is shared across all months. Names, colors, and parent changes apply everywhere.',
                                  style:
                                      TextStyle(color: _muted, fontSize: 12)),
                              const SizedBox(height: 12),
                              TextFormField(
                                  controller: name,
                                  enabled: !busy,
                                  decoration:
                                      InputDecoration(labelText: 'Group name'),
                                  maxLength: 80,
                                  validator: (value) =>
                                      value == null || value.trim().isEmpty
                                          ? 'Enter a name.'
                                          : null),
                              const SizedBox(height: 12),
                              if (kind == 'withdrawal')
                                DropdownButtonFormField<String>(
                                  key:
                                      ValueKey('parent-$validParent-$parentId'),
                                  initialValue: validParent ? parentId : '',
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                      labelText: 'Parent group'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: '',
                                        child: Text('Income (top level)')),
                                    for (final group in _state.orderedGroups)
                                      if (group['id'] != row?['id'] &&
                                          !descendants.contains(group['id']))
                                        DropdownMenuItem(
                                            value: _id(group),
                                            child: Text(
                                                _state
                                                    .pathOf(group['id'])
                                                    .map((g) => g['name'])
                                                    .join(' / '),
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                  ],
                                  onChanged: busy
                                      ? null
                                      : (value) =>
                                          update(() => parentId = value ?? ''),
                                ),
                              const SizedBox(height: 12),
                              TextFormField(
                                  controller: customColor,
                                  enabled: !busy,
                                  decoration: InputDecoration(
                                      labelText: 'Custom color (hex)',
                                      hintText: '#336699',
                                      suffixIcon: IconButton(
                                          tooltip: 'Choose custom color',
                                          onPressed: busy
                                              ? null
                                              : () async {
                                                  final picked = await _pickColor(
                                                      RegExp(r'^[0-9a-f]{6}$')
                                                              .hasMatch(
                                                                  customHex())
                                                          ? _color({
                                                              'color_key':
                                                                  'hex_${customHex()}'
                                                            })
                                                          : _color({
                                                              'color_key': color
                                                            }));
                                                  if (picked == null ||
                                                      !dialogContext.mounted) {
                                                    return;
                                                  }
                                                  update(() => customColor
                                                          .text =
                                                      '#${picked.toARGB32().toRadixString(16).substring(2)}');
                                                },
                                          icon: Icon(Icons.circle,
                                              color: RegExp(r'^[0-9a-f]{6}$')
                                                      .hasMatch(customHex())
                                                  ? _color({
                                                      'color_key':
                                                          'hex_${customHex()}'
                                                    })
                                                  : _color(
                                                      {'color_key': color})))),
                                  onChanged: (_) => update(() {}),
                                  validator: (_) => RegExp(r'^[0-9a-f]{6}$')
                                          .hasMatch(customHex())
                                      ? null
                                      : 'Enter six hex digits, e.g. #336699.'),
                              _dialogError(update, busy),
                              if (needsReview)
                                const Text(
                                    'This group or its parent changed elsewhere. '
                                    'Cancel and reopen the editor to review the current hierarchy.',
                                    style: TextStyle(color: _danger)),
                            ],
                          )),
                    )),
                actions: [
                  TextButton(
                      onPressed:
                          busy ? null : () => Navigator.pop(dialogContext),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: busy || _conflict || _loading || needsReview
                          ? null
                          : () async {
                              if (!form.currentState!.validate() ||
                                  widget.month != month) {
                                return;
                              }
                              update(() => busy = true);
                              final result = await _mutate('group_save', {
                                if (row != null) 'id': row['id'],
                                'kind': kind,
                                'name': name.text.trim(),
                                'color_key': 'hex_${customHex()}',
                                'parent_group_id':
                                    parentId.isEmpty ? null : parentId,
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
              ));
        },
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
        builder: (context, update) {
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                _dialogError(update, busy),
              ],
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
                          final refreshedPayload = <String, dynamic>{
                            ...payload
                          };
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
          );
        },
      ),
    );
  }
}

class _FundingLinks extends CustomPainter {
  final List<(Offset, Offset, double, Color, Color)> links;
  const _FundingLinks(this.links);

  @override
  void paint(Canvas canvas, Size size) {
    for (final (start, end, height, sourceColor, targetColor) in links) {
      final middle = (start.dx + end.dx) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(middle, start.dy, middle, end.dy, end.dx, end.dy)
        ..lineTo(end.dx, end.dy + height)
        ..cubicTo(middle, end.dy + height, middle, start.dy + height, start.dx,
            start.dy + height)
        ..close();
      canvas.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(colors: [sourceColor, targetColor])
                .createShader(Rect.fromLTRB(start.dx, 0, end.dx, 1))
            ..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant _FundingLinks oldDelegate) => true;
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
