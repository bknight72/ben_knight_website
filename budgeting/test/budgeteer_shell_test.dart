import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:private_budgeting/app.dart';
import 'package:private_budgeting/app_theme.dart';
import 'package:private_budgeting/budgeteer_domain.dart';
import 'package:private_budgeting/domain.dart';
import 'workspace_test.dart' show FixtureRepository;

class PlanningRepository extends FixtureRepository {
  PlanningRepository({this.state = const BudgeteerState(groupsRevision: 7)});

  final BudgeteerState state;
  int reads = 0;
  int inclusions = 0;
  final months = <String>[];
  @override
  Future<BudgeteerState> budgeteerMutate(
      String month, int revision, String operation, Json payload,
      {required int groupsRevision}) async {
    expect(operation, 'sources_include');
    expect(groupsRevision, 7);
    inclusions++;
    return state;
  }

  @override
  Future<BudgeteerState> budgeteerRead(String month) async {
    reads++;
    months.add(month);
    return state;
  }
}

void main() {
  testWidgets('mobile toolbar stays fixed as dense Tower content scrolls',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = PlanningRepository(
        state: BudgeteerState(
      groupsRevision: 7,
      plan: const {'id': 'plan', 'revision': 1},
      groups: [
        for (var i = 0; i < 24; i++)
          {'id': 'group-$i', 'name': 'Group $i', 'sort_position': i},
      ],
      entries: [
        const {
          'id': 'income',
          'name': 'Income',
          'kind': 'deposit',
          'amount_minor': 100000,
        },
        for (var i = 0; i < 24; i++)
          {
            'id': 'bill-$i',
            'name': 'Bill $i',
            'kind': 'withdrawal',
            'group_id': 'group-$i',
            'amount_minor': 100,
          },
      ],
    ));
    addTearDown(repository.client.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: BudgetTheme.data,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!),
        home: LedgerShell(repository: repository, onLogout: () async {})));
    await tester.pumpAndSettle();

    final menu = find.byTooltip('Open navigation menu');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();

    final tabs = find.byType(SegmentedButton<int>);
    final appBar = find.byType(AppBar);
    expect(tabs, findsOneWidget);
    expect(find.descendant(of: appBar, matching: tabs), findsOneWidget);
    final tabsRect = tester.getRect(tabs);
    expect(tabsRect.left, greaterThan(tester.getCenter(menu).dx));
    expect(tabsRect.center.dy, closeTo(tester.getCenter(menu).dy, 1));
    expect(tabsRect.right, lessThanOrEqualTo(320));

    final diagram = find.byKey(const ValueKey('sankey-diagram'));
    final pooled = find.text('Pooled deposits');
    expect(find.ancestor(of: diagram, matching: find.byType(Scrollable)),
        findsOneWidget);
    final chart = tester.getRect(diagram);
    final totals = tester.getRect(pooled);
    expect(chart.height, greaterThan(568));
    await tester.dragFrom(
        Offset(chart.center.dx, chart.top + 160), const Offset(0, -230));
    await tester.pumpAndSettle();
    final distance = chart.top - tester.getTopLeft(diagram).dy;
    expect(distance, greaterThan(0));
    expect(tester.getTopLeft(pooled).dy, closeTo(totals.top - distance, .01));
    expect(tester.getRect(tabs), tabsRect);
    await tester.ensureVisible(find.text('Remaining'));
    await tester.pumpAndSettle();
    expect(find.text('Remaining').hitTestable(), findsOneWidget);

    final group = find.byKey(const ValueKey('sankey-label-group:group-0'));
    await tester.ensureVisible(group);
    await tester.pumpAndSettle();
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<int>>(tabs).selected, {1});
    expect(find.text('Add withdrawal'), findsOneWidget);
    await tester
        .tap(find.descendant(of: appBar, matching: find.text('Deposits')));
    await tester.pumpAndSettle();
    expect(find.text('Add deposit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile menu exposes all drawer items without scrolling',
      (tester) async {
    tester.view.physicalSize = const Size(360, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = PlanningRepository();
    addTearDown(repository.client.dispose);
    var signOuts = 0;
    await tester.pumpWidget(MaterialApp(
        theme: BudgetTheme.data,
        home: LedgerShell(
            repository: repository,
            onLogout: () async {
              signOuts++;
            })));
    await tester.pumpAndSettle();

    final menu = find.byTooltip('Open navigation menu');
    final appBar = find.byType(AppBar);
    expect(tester.widget<AppBar>(appBar).title, isNull);
    expect(find.byIcon(Icons.logout).hitTestable(), findsNothing);
    final menuIcon =
        find.descendant(of: appBar, matching: find.byIcon(Icons.menu));
    expect(IconTheme.of(tester.element(menuIcon)).color, BudgetColors.leaf);

    await tester.tap(menu);
    await tester.pumpAndSettle();
    final drawer = find.byType(Drawer);
    expect(find.text('Just your eyes.'), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-logo')).hitTestable(),
        findsOneWidget);
    expect(find.byTooltip(RegExp('Choose reporting month:')).hitTestable(),
        findsOneWidget);
    for (final page in [
      'Overview',
      'Accounts',
      'Transactions',
      'Group manager',
      'Import & export',
      'Budgeteer',
      'Sign out',
    ]) {
      expect(
          find.descendant(of: drawer, matching: find.text(page)).hitTestable(),
          findsOneWidget);
    }
    expect(find.byIcon(Icons.logout), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    expect(signOuts, 1);
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    expect(find.text('Tower of Money'), findsOneWidget);
    expect(find.byIcon(Icons.logout).hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Budgeteer navigation reloads persisted month state',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = PlanningRepository();
    addTearDown(repository.client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LedgerShell(repository: repository, onLogout: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('Just your eyes.'), findsOneWidget);
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    expect(find.text('Tower of Money'), findsOneWidget);
    expect(find.text('Give every dollar a place.'), findsNothing);
    final funding =
        tester.getRect(find.byKey(const ValueKey('tower-of-money-card')));
    final workspace = tester.getRect(find.byType(RefreshIndicator));
    final tabs = tester.getRect(find.byType(SegmentedButton<int>));
    expect(funding.top, tabs.bottom + 12);
    expect(funding.bottom, workspace.bottom - 18);
    expect(funding.left, workspace.left + 36);
    expect(funding.right, workspace.right - 36);
    expect(find.byTooltip('Reporting settings'), findsNothing);
    expect(find.byTooltip('Refresh data'), findsNothing);
    expect(
        tester.getRect(find.byTooltip(RegExp('Choose reporting month:'))).right,
        lessThan(workspace.left));
    expect(funding.contains(tester.getTopLeft(find.text('Pooled deposits'))),
        isTrue);
    expect(find.text('Add deposit'), findsNothing);
    await tester.drag(find.text('Pooled deposits'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('tower-of-money-card'))),
        funding);
    expect(repository.reads, 1);
    await tester.tap(find.descendant(
        of: find.byType(SegmentedButton<int>),
        matching: find.text('Withdrawals')));
    await tester.pumpAndSettle();
    expect(find.text('Add withdrawal'), findsOneWidget);
    expect(find.text('Add deposit'), findsNothing);
    expect(find.text('Review archived labels'), findsNothing);
    await tester.tap(find.text('Deposits'));
    await tester.pumpAndSettle();
    expect(find.text('Add deposit'), findsOneWidget);
    expect(find.text('Add withdrawal'), findsNothing);
    expect(find.text('Pooled deposits'), findsNothing);
    await tester.tap(find.text('Tower of Money'));
    await tester.pumpAndSettle();
    expect(repository.reads, 1);
    expect(repository.inclusions, 1);
    final sidebar = find
        .ancestor(
            of: find.byTooltip('Collapse sidebar'),
            matching: find.byType(SizedBox))
        .first;
    expect(tester.getSize(sidebar), const Size(242, 1100));
    final sidebarIcons = [
      Icons.grid_view_outlined,
      Icons.account_balance_outlined,
      Icons.swap_vert,
      Icons.folder_copy_outlined,
      Icons.file_upload_outlined,
      Icons.view_agenda_outlined,
      Icons.calendar_today_outlined,
      Icons.logout,
    ];
    final iconPositions = [
      for (final icon in sidebarIcons) tester.getCenter(find.byIcon(icon)).dy,
    ];
    for (final icon in sidebarIcons) {
      expect(tester.getCenter(find.byIcon(icon)).dx, closeTo(36, .1));
    }
    final logo = find.byKey(const ValueKey('sidebar-logo'));
    final logoPosition = tester.getCenter(logo);
    expect(logoPosition.dx, closeTo(36, .1));
    final togglePosition = tester.getCenter(find.byTooltip('Collapse sidebar'));
    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pumpAndSettle();
    final rail = find
        .ancestor(
            of: find.byTooltip('Expand sidebar'),
            matching: find.byType(SizedBox))
        .first;
    expect(tester.getSize(rail), const Size(72, 1100));
    expect(logo.hitTestable(), findsOneWidget);
    expect(tester.getCenter(logo), logoPosition);
    expect(tester.getCenter(find.byTooltip('Expand sidebar')), togglePosition);
    for (var i = 0; i < sidebarIcons.length; i++) {
      expect(
          tester.getCenter(find.byIcon(sidebarIcons[i])).dx, closeTo(36, .1));
      expect(tester.getCenter(find.byIcon(sidebarIcons[i])).dy,
          closeTo(iconPositions[i], .1));
    }
    expect(find.text('Tower of Money'), findsOneWidget);
    expect(repository.reads, 1);
    expect(tester.getTopLeft(find.byType(RefreshIndicator)).dx, 72);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.view_agenda_outlined))
            .isSelected,
        isTrue);
    await tester.tap(find.byTooltip('Overview'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Budgeteer'));
    await tester.pumpAndSettle();
    expect(repository.reads, 2);
    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar), const Size(242, 1100));
    expect(repository.reads, 2);
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    expect(repository.reads, 3);
    expect(repository.inclusions, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('month picker selects year and month without a day calendar',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = PlanningRepository();
    addTearDown(repository.client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LedgerShell(repository: repository, onLogout: () async {})));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Reporting settings'), findsNothing);
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    final initialMonth = tester.widget<Text>(find.descendant(
        of: find.widgetWithIcon(OutlinedButton, Icons.calendar_today_outlined),
        matching: find.byType(Text)));
    final initial = initialMonth.data!;
    await tester.tap(find.byTooltip(RegExp('Choose reporting month:')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('January'), findsOneWidget);
    expect(find.text('December'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    final year = int.parse(initial.substring(0, 4)) + 1;
    await tester.scrollUntilVisible(find.text('$year').last, 100,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('$year').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('February'));
    await tester.pumpAndSettle();
    expect(find.text('$year-02'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(repository.reads, 2);
    await tester.tap(find.byTooltip(RegExp('Choose reporting month:')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('$year-02'), findsOneWidget);
    expect(repository.reads, 2);
    expect(repository.months.last, '$year-02');
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('$year-02'), findsOneWidget);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Only $year-02'), findsOneWidget);
    await tester.tap(find.text('Group manager'));
    await tester.pumpAndSettle();
    expect(find.text('Deposit groups'), findsOneWidget);
    expect(find.text('Withdrawal groups'), findsOneWidget);
    expect(find.text('Add deposit group'), findsOneWidget);
    expect(find.text('Add withdrawal group'), findsOneWidget);
    expect(find.text('Budgets'), findsNothing);
    expect(find.text('Set category budget'), findsNothing);
    expect(repository.reads, 3);
    expect(repository.months.last, '$year-02');
    expect(repository.inclusions, 2);
    await tester.tap(find.byTooltip(RegExp('Choose reporting month:')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('March'));
    await tester.pumpAndSettle();
    expect(find.text('$year-03'), findsOneWidget);
    expect(repository.reads, 4);
    expect(repository.months.last, '$year-03');
    expect(repository.inclusions, 2);
    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pumpAndSettle();
    final monthControl = find.byTooltip(RegExp('Choose reporting month:'));
    expect(tester.getRect(monthControl).right, lessThanOrEqualTo(72));
    await tester.tap(monthControl);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(find.text('$year-03'), findsOneWidget);
    await tester.tap(find.text('Budgeteer'));
    await tester.pumpAndSettle();
    expect(repository.reads, 5);
    expect(repository.inclusions, 3);
    expect(tester.takeException(), isNull);
  });
}
