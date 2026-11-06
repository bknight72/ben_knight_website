import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase/supabase.dart';
import 'domain.dart';
import 'platform.dart' as platform;
import 'repository.dart';
import 'config.dart';

const ink = Color(0xff102e2c);
const teal = Color(0xff17695c);
const canvas = Color(0xfff4f6f3);
const muted = Color(0xff637570);

class BudgetApp extends StatelessWidget {
  final AppConfig config;
  final bool configurationError;
  const BudgetApp(
      {super.key,
      this.config = const AppConfig(),
      this.configurationError = false});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Ledger | Private Budgeting',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme:
              ColorScheme.fromSeed(seedColor: teal, surface: Colors.white),
          scaffoldBackgroundColor: canvas,
          fontFamily: 'Arial',
          textTheme: const TextTheme(
            headlineLarge: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: ink,
                letterSpacing: -1.3),
            headlineSmall: TextStyle(
                fontSize: 23, fontWeight: FontWeight.w700, color: ink),
            titleMedium: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: ink),
            bodyMedium: TextStyle(fontSize: 14, color: ink, height: 1.5),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: canvas,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
          ),
          filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
            backgroundColor: teal,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 19),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          )),
          cardTheme: const CardThemeData(
              elevation: 0, color: Colors.white, margin: EdgeInsets.zero),
        ),
        home: configurationError
            ? const EntryFrame(
                child: Text(
                    'Public configuration could not be loaded or validated. No financial service was initialized.'))
            : supabaseUrl.isEmpty || supabaseKey.isEmpty
                ? const ConfigurationScreen()
                : AuthGate(config: config),
      );
}

class Brand extends StatelessWidget {
  final bool light;
  const Brand({super.key, this.light = false});
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.account_balance_wallet_outlined,
            color: light ? const Color(0xffb7e0b8) : teal, size: 29),
        const SizedBox(width: 12),
        Text('ledger',
            style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
                color: light ? Colors.white : ink)),
      ]);
}

class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({super.key});
  @override
  Widget build(BuildContext context) => const EntryFrame(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 38, color: teal),
          SizedBox(height: 22),
          Text('A private place for your money.',
              style: TextStyle(
                  fontSize: 30, fontWeight: FontWeight.bold, color: ink)),
          SizedBox(height: 18),
          Text(
              'This ledger is not configured yet. No account or financial data is loaded.'),
          SizedBox(height: 18),
          Text(
              'Build with SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to connect your provisioned owner account. Public signup is not available. Stripe remains disabled until explicitly approved and configured.'),
          SizedBox(height: 22),
          Text('SESSION-ONLY ACCESS  /  NO OFFLINE FINANCIAL STORAGE',
              style: TextStyle(fontSize: 10, letterSpacing: 1.4, color: muted)),
        ],
      ));
}

class EntryFrame extends StatelessWidget {
  final Widget child;
  const EntryFrame({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Scaffold(
      body: LayoutBuilder(
          builder: (context, size) => Row(children: [
                if (size.maxWidth >= 900 && size.maxHeight >= 700)
                  Expanded(
                      child: Container(
                          color: ink,
                          padding: const EdgeInsets.all(64),
                          child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Brand(light: true),
                                Spacer(),
                                Text('Less noise.\nMore clarity.',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 62,
                                        height: 1.08,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -2)),
                                SizedBox(height: 24),
                                Text(
                                    'Your accounts, your decisions.\nA deliberate view of everyday money.',
                                    style: TextStyle(
                                        color: Color(0xffacc6bd),
                                        fontSize: 18,
                                        height: 1.7)),
                                Spacer(),
                                Text('PRIVATE BY DESIGN',
                                    style: TextStyle(
                                        color: Color(0xffacc6bd),
                                        letterSpacing: 3,
                                        fontSize: 11)),
                              ]))),
                Expanded(
                    child: Center(
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(28),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 430),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (size.maxWidth < 900 ||
                                        size.maxHeight < 700) ...[
                                      const Brand(),
                                      const SizedBox(height: 48)
                                    ],
                                    child
                                  ]),
                            )))),
              ])));
}

class AuthGate extends StatefulWidget {
  final AppConfig config;
  final SupabaseClient? client;
  final Uri? callbackUri;
  const AuthGate(
      {super.key,
      this.client,
      this.callbackUri,
      this.config = const AppConfig()});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final SupabaseClient client;
  StreamSubscription<AuthState>? subscription;
  Timer? expiryTimer;
  bool authorized = false;
  bool recovery = false;
  bool busy = false;
  bool resetMode = false;
  String? error;
  String? notice;
  String? factorId;
  String? qr;
  String? secret;
  final email = TextEditingController();
  final password = TextEditingController();
  final code = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The plain Dart client has no browser session store. Tokens live in memory only.
    client = widget.client ??
        SupabaseClient(supabaseUrl, supabaseKey,
            authOptions:
                const AuthClientOptions(authFlowType: AuthFlowType.implicit));
    subscription = client.auth.onAuthStateChange.listen((state) {
      if (!mounted) return;
      if (state.event == AuthChangeEvent.passwordRecovery) {
        setState(() {
          recovery = true;
          authorized = false;
        });
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      expiryTimer?.cancel();
      if (state.session == null) {
        clearSessionUi();
      } else {
        final expiresAt = state.session!.expiresAt;
        if (expiresAt != null) {
          expiryTimer = Timer(
              Duration(
                  milliseconds:
                      (expiresAt * 1000 - DateTime.now().millisecondsSinceEpoch)
                          .clamp(0, 2147483647)
                          .toInt()), () {
            if (mounted) {
              clearSessionUi();
              unawaited(client.auth
                  .signOut(scope: SignOutScope.local)
                  .catchError((Object _) {}));
            }
          });
        }
      }
      if (state.session != null &&
          client.auth.mfa.getAuthenticatorAssuranceLevel().currentLevel?.name !=
              'aal2' &&
          authorized) {
        setState(() => authorized = false);
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    final initialUri = widget.callbackUri ?? Uri.base;
    if (initialUri.fragment.contains('access_token=') ||
        initialUri.fragment.contains('error=')) {
      run(() async {
        final callback = initialUri;
        recovery = callback.fragment.contains('type=recovery');
        platform.clearAuthUrl();
        await client.auth.getSessionFromUrl(callback);
        if (!recovery) await checkMfa();
      });
    }
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    subscription?.cancel();
    email.dispose();
    password.dispose();
    code.dispose();
    client.dispose();
    super.dispose();
  }

  void clearSessionUi() {
    setState(() {
      authorized = false;
      factorId = null;
      qr = null;
      secret = null;
      recovery = false;
    });
    password.clear();
    code.clear();
    // Dialogs are routes above the financial subtree and must also be removed.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await action();
    } on AuthException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> checkMfa() async {
    final assurance = client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (assurance.currentLevel?.name == 'aal2') {
      if (await client.rpc('is_budget_owner') != true) {
        await client.auth.signOut(scope: SignOutScope.local);
        throw const FormatException(
            'This identity is not the provisioned ledger owner.');
      }
      if (mounted) setState(() => authorized = true);
      return;
    }
    final factors = await client.auth.mfa.listFactors();
    final verified = factors.totp.where((f) => f.status.name == 'verified');
    if (verified.isNotEmpty) {
      factorId = verified.first.id;
    } else {
      for (final factor in factors.all.where((f) =>
          f.factorType == FactorType.totp && f.status.name != 'verified')) {
        await client.auth.mfa.unenroll(factor.id);
      }
      final enrollment = await client.auth.mfa.enroll(
          factorType: FactorType.totp, friendlyName: 'Ledger authenticator');
      factorId = enrollment.id;
      final image = enrollment.totp?.qrCode;
      qr = image;
      if (image != null && image.startsWith('data:')) {
        final comma = image.indexOf(',');
        if (comma < 0) {
          throw const FormatException('Invalid authenticator QR response.');
        }
        qr = image.substring(0, comma).contains(';base64')
            ? utf8.decode(base64Decode(image.substring(comma + 1)))
            : Uri.decodeComponent(image.substring(comma + 1));
      }
      secret = enrollment.totp?.secret;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (authorized && client.auth.currentSession != null) {
      return LedgerShell(
          key: ValueKey(client.auth.currentUser?.id),
          config: widget.config,
          repository: LedgerRepository(client),
          onLogout: () async {
            // Remove the financial subtree immediately, even if the remote logout fails.
            setState(() => authorized = false);
            Navigator.of(context).popUntil((route) => route.isFirst);
            await run(() async {
              await client.auth.signOut(scope: SignOutScope.local);
            });
          });
    }
    final mfa = client.auth.currentSession != null && !recovery;
    return EntryFrame(
        child: AutofillGroup(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
          Text(
              recovery
                  ? 'Set a new password'
                  : mfa
                      ? (qr == null
                          ? 'One more layer of security.'
                          : 'Secure your ledger.')
                      : resetMode
                          ? 'Reset your password'
                          : 'Welcome to your ledger.',
              style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 14),
          Text(
              recovery
                  ? 'Choose a strong password. Financial access still requires your authenticator.'
                  : mfa
                      ? 'Use a six-digit code from your authenticator. Financial data is protected by mandatory MFA.'
                      : resetMode
                          ? 'We will email a recovery link if this is the provisioned owner address.'
                          : 'Sign in to your private workspace. This app is reserved for its provisioned owner.',
              style: const TextStyle(color: muted)),
          const SizedBox(height: 28),
          if (!mfa && !recovery)
            TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Email address')),
          if ((!mfa && !resetMode) || recovery) ...[
            const SizedBox(height: 16),
            TextField(
                controller: password,
                obscureText: true,
                autofillHints: [
                  recovery ? AutofillHints.newPassword : AutofillHints.password
                ],
                decoration: InputDecoration(
                    labelText: recovery
                        ? 'New password (12+ characters)'
                        : 'Password')),
          ],
          if (mfa) ...[
            if (qr != null) ...[
              Center(
                  child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(16),
                      child: SvgPicture.string(qr!, width: 190, height: 190))),
              const SizedBox(height: 12),
              const Text(
                  'Scan with your authenticator, or enter this setup key:'),
              SelectableText(secret ?? '',
                  style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 18),
            ],
            TextField(
                controller: code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration:
                    const InputDecoration(labelText: 'Authenticator code')),
            const Text(
                'Lost your authenticator? Contact your Supabase project administrator for identity-verified factor recovery.',
                style: TextStyle(fontSize: 12, color: muted)),
          ],
          if (error != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(error!,
                    style: const TextStyle(color: Color(0xffaa3333)))),
          if (notice != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(notice!, style: const TextStyle(color: teal))),
          const SizedBox(height: 24),
          FilledButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                        if (recovery) {
                          if (password.text.length < 12) {
                            throw const FormatException(
                                'Use at least 12 characters.');
                          }
                          await client.auth.updateUser(
                              UserAttributes(password: password.text));
                          password.clear();
                          recovery = false;
                          await checkMfa();
                        } else if (mfa) {
                          if (factorId == null) {
                            await checkMfa();
                            return;
                          }
                          if (!RegExp(r'^\d{6}$').hasMatch(code.text)) {
                            throw const FormatException(
                                'Enter a six-digit code.');
                          }
                          await client.auth.mfa.challengeAndVerify(
                              factorId: factorId!, code: code.text);
                          code.clear();
                          secret = null;
                          qr = null;
                          await checkMfa();
                        } else if (resetMode) {
                          await client.auth.resetPasswordForEmail(
                              email.text.trim(),
                              redirectTo: Uri.base
                                  .replace(fragment: '', query: '')
                                  .toString());
                          notice =
                              'Check your email for a password reset link.';
                        } else {
                          await client.auth.signInWithPassword(
                              email: email.text.trim(),
                              password: password.text);
                          password.clear();
                          await checkMfa();
                        }
                      }),
              child: Text(busy
                  ? 'Working...'
                  : recovery
                      ? 'Update password'
                      : mfa
                          ? 'Verify and continue'
                          : resetMode
                              ? 'Send recovery email'
                              : 'Sign in')),
          const SizedBox(height: 14),
          TextButton(
              onPressed: busy
                  ? null
                  : () {
                      if (mfa || recovery) {
                        run(() async {
                          await client.auth.signOut(scope: SignOutScope.local);
                          recovery = false;
                        });
                      } else {
                        setState(() {
                          resetMode = !resetMode;
                          error = null;
                          notice = null;
                        });
                      }
                    },
              child: Text(mfa || recovery
                  ? 'Back to sign in'
                  : resetMode
                      ? 'Back to sign in'
                      : 'Forgot password?')),
          const SizedBox(height: 22),
          const Text(
              'Your session stays in memory. Closing or reloading this page requires signing in again.',
              style: TextStyle(fontSize: 12, color: muted)),
        ])));
  }
}

class LedgerShell extends StatefulWidget {
  final AppConfig config;
  final LedgerRepository repository;
  final Future<void> Function() onLogout;
  const LedgerShell(
      {super.key,
      required this.repository,
      required this.onLogout,
      this.config = const AppConfig()});
  @override
  State<LedgerShell> createState() => _LedgerShellState();
}

class _LedgerShellState extends State<LedgerShell> {
  int page = 0;
  bool loading = true;
  bool working = false;
  String? error;
  String search = '';
  String? accountFilter;
  String categoryFilter = 'all';
  bool monthOnly = false;
  int visibleTransactions = 100;
  String statusFilter = 'all';
  late String month;
  List<Json> accounts = [],
      transactions = [],
      categories = [],
      budgets = [],
      batches = [];
  String timezone = 'America/Denver';
  Json? refreshUsage;
  String? usageError;
  static const pages = [
    'Overview',
    'Accounts',
    'Transactions',
    'Budgets',
    'Import & export'
  ];
  static const icons = [
    Icons.grid_view_outlined,
    Icons.account_balance_outlined,
    Icons.swap_vert,
    Icons.pie_chart_outline,
    Icons.file_upload_outlined
  ];
  LedgerRepository get repo => widget.repository;
  bool get bankLinkingEnabled =>
      widget.config.stripeAllowed && stripeEnabled && stripeKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    timezone = widget.config.reportingTimezone;
    month = reportingMonth(DateTime.now());
    load();
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results = await Future.wait([
        repo.rows('accounts'),
        repo.rows('balance_snapshots'),
        repo.rows('transactions'),
        repo.rows('transaction_annotations'),
        repo.rows('categories'),
        repo.rows('monthly_budgets'),
        repo.rows('import_batches'),
        repo.rows('profiles'),
      ]);
      if (!mounted) return;
      final snapshots = results[1]
        ..sort(
            (a, b) => '${b['observed_at']}'.compareTo('${a['observed_at']}'));
      Json? usage;
      String? usageFailure;
      try {
        usage = await repo.api('usage', get: true);
      } catch (_) {
        usageFailure =
            'Refresh usage is unavailable. Paid refresh controls are disabled until usage can be checked.';
      }
      if (!mounted) return;
      final annotations = {for (final a in results[3]) a['transaction_id']: a};
      setState(() {
        categories = results[4];
        budgets = results[5];
        batches = results[6];
        timezone =
            '${results[7].firstOrNull?['reporting_timezone'] ?? widget.config.reportingTimezone}';
        refreshUsage = usage;
        usageError = usageFailure;
        accounts = results[0].map((a) {
          final latest =
              snapshots.where((s) => s['account_id'] == a['id']).firstOrNull;
          return {
            ...a,
            'type': a['kind'],
            'balance_minor': latest?['current_minor'],
            'balance_at': latest?['observed_at']
          };
        }).toList();
        transactions = results[2].map((t) {
          final annotation = annotations[t['id']];
          final category = categories
              .where((c) => c['id'] == annotation?['category_id'])
              .firstOrNull;
          return {
            ...t,
            if (annotation != null) ...annotation,
            'id': t['id'],
            'category_kind': category?['kind']
          };
        }).toList()
          ..sort((a, b) => '${b['posted_date'] ?? b['transaction_date']}'
              .compareTo('${a['posted_date'] ?? a['transaction_date']}'));
      });
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> perform(Future<void> Function() action,
      {String success = 'Changes saved.'}) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        final wide = size.maxWidth >= 1000;
        final navigation = SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              const Padding(
                  padding: EdgeInsets.fromLTRB(28, 38, 28, 42),
                  child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: Brand(light: true))),
              const Padding(
                  padding: EdgeInsets.only(left: 30, bottom: 12),
                  child: Text('WORKSPACE',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 2,
                          color: Color(0xff8daba2)))),
              for (var i = 0; i < pages.length; i++)
                Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      selected: page == i,
                      selectedTileColor: const Color(0xff254740),
                      leading: Icon(icons[i],
                          color: page == i
                              ? const Color(0xffc3e9b1)
                              : const Color(0xff9eb8af)),
                      title: Text(pages[i],
                          style: TextStyle(
                              color: page == i
                                  ? Colors.white
                                  : const Color(0xffb4c9c1),
                              fontSize: 14)),
                      onTap: () {
                        setState(() => page = i);
                        if (!wide) Navigator.pop(context);
                      },
                    )),
              const SizedBox(height: 36),
              Container(
                  margin: const EdgeInsets.all(22),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xff35534a)),
                      borderRadius: BorderRadius.circular(12)),
                  child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.shield_outlined, color: Color(0xffb7e0b8)),
                        SizedBox(height: 10),
                        Text('Just your eyes.',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        SizedBox(height: 6),
                        Text('MFA protected. No offline financial storage.',
                            style: TextStyle(
                                color: Color(0xff9eb8af), fontSize: 12)),
                      ])),
              ListTile(
                  leading: const Icon(Icons.logout, color: Colors.white70),
                  title: const Text('Sign out',
                      style: TextStyle(color: Colors.white70)),
                  onTap: widget.onLogout),
              const SizedBox(height: 20),
            ]));
        return Scaffold(
          drawer: wide ? null : Drawer(backgroundColor: ink, child: navigation),
          appBar: wide
              ? null
              : AppBar(title: const Brand(), backgroundColor: canvas, actions: [
                  IconButton(
                      tooltip: 'Sign out',
                      onPressed: widget.onLogout,
                      icon: const Icon(Icons.logout))
                ]),
          body: Row(children: [
            if (wide)
              SizedBox(
                  width: 242, child: Material(color: ink, child: navigation)),
            Expanded(
                child: Column(children: [
              if (wide)
                Container(
                    height: 77,
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(
                            bottom: BorderSide(color: Color(0xffe2e8df)))),
                    child: Row(children: [
                      Text('YOUR PRIVATE WORKSPACE',
                          style: TextStyle(
                              fontSize: 10, letterSpacing: 2, color: muted)),
                      const Spacer(),
                      const Icon(Icons.verified_user_outlined,
                          size: 16, color: teal),
                      const SizedBox(width: 8),
                      const Text('Owner / MFA verified',
                          style: TextStyle(fontSize: 12, color: muted)),
                    ])),
              Expanded(
                  child: RefreshIndicator(
                      onRefresh: load,
                      child: ListView(
                          padding: EdgeInsets.all(wide ? 36 : 20),
                          children: [
                            Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 24,
                                runSpacing: 16,
                                children: [
                                  Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(pages[page],
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineLarge),
                                        const SizedBox(height: 7),
                                        Text(
                                            [
                                              'The big picture, with the details that matter.',
                                              'A clear view of what you hold and owe.',
                                              'Every movement, in context.',
                                              'Give your spending a little direction.',
                                              'Bring your history. Keep control of your data.'
                                            ][page],
                                            style:
                                                const TextStyle(color: muted))
                                      ]),
                                  Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                            onPressed: settings,
                                            tooltip: 'Reporting settings',
                                            icon: const Icon(Icons.tune)),
                                        IconButton(
                                            onPressed: loading ? null : load,
                                            tooltip: 'Refresh data',
                                            icon: const Icon(Icons.refresh)),
                                        if (page == 0 || page == 2 || page == 3)
                                          monthPicker()
                                      ]),
                                ]),
                            const SizedBox(height: 28),
                            if (working) const LinearProgressIndicator(),
                            if (error != null)
                              panel(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    const Text('Data is unavailable',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 8),
                                    Text(error!),
                                    TextButton(
                                        onPressed: load,
                                        child: const Text('Try again'))
                                  ])),
                            if (loading)
                              const Padding(
                                  padding: EdgeInsets.all(60),
                                  child: Center(
                                      child: CircularProgressIndicator()))
                            else if (error == null)
                              switch (page) {
                                0 =>
                                  overview(size.maxWidth - (wide ? 314 : 40)),
                                1 => accountsPage(),
                                2 => transactionsPage(),
                                3 => budgetsPage(),
                                _ => importsPage()
                              },
                            const SizedBox(height: 28),
                            Text(
                                'USD only  /  $timezone  /  Posted activity  /  No rollover\nBank transaction dates use provider calendar dates; balances reflect their observation date.',
                                style: const TextStyle(
                                    fontSize: 11, color: muted)),
                          ]))),
            ])),
          ]),
        );
      });

  Widget monthPicker() => OutlinedButton.icon(
      onPressed: () async {
        final date = await showDatePicker(
            context: context,
            initialDate: DateTime.parse('$month-01'),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
            helpText: 'Choose any day in the reporting month');
        if (date != null && mounted) {
          setState(() =>
              month = '${date.year}-${date.month.toString().padLeft(2, '0')}');
        }
      },
      icon: const Icon(Icons.calendar_today_outlined, size: 16),
      label: Text(month));

  Widget panel({required Widget child}) =>
      Card(child: Padding(padding: const EdgeInsets.all(24), child: child));
  Widget empty(String title, String detail, {Widget? action}) => panel(
          child: Column(children: [
        const SizedBox(height: 18),
        const Icon(Icons.inbox_outlined, size: 38, color: muted),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(detail,
            textAlign: TextAlign.center, style: const TextStyle(color: muted)),
        if (action != null) ...[const SizedBox(height: 20), action],
        const SizedBox(height: 18),
      ]));

  Widget overview(double width) {
    final summary = LedgerSummary.calculate(transactions, month);
    final position = netPosition(accounts);
    final metrics = [
      (
        'TRACKED NET POSITION',
        position == null ? 'Not available' : money(position),
        'Cash minus card debt; not full net worth',
        Icons.account_balance_wallet_outlined
      ),
      (
        'MONTHLY INCOME',
        money(summary.income),
        'Posted inflows, excluding transfers',
        Icons.south_west
      ),
      (
        'MONTHLY SPENDING',
        money(summary.spending),
        'Purchases less categorized refunds',
        Icons.north_east
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 16, runSpacing: 16, children: [
        for (var i = 0; i < metrics.length; i++)
          SizedBox(
              width: width >= 760 ? (width - 32) / 3 : width,
              child: Container(
                padding: const EdgeInsets.all(23),
                decoration: BoxDecoration(
                    color: i == 0 ? teal : Colors.white,
                    borderRadius: BorderRadius.circular(14)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(metrics[i].$1,
                            style: TextStyle(
                                color: i == 0 ? Colors.white70 : muted,
                                fontSize: 10,
                                letterSpacing: 1.1)),
                        const Spacer(),
                        Icon(metrics[i].$4,
                            color: i == 0 ? Colors.white70 : teal, size: 20)
                      ]),
                      const SizedBox(height: 24),
                      Text(metrics[i].$2,
                          style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -1,
                              color: i == 0 ? Colors.white : ink)),
                      const SizedBox(height: 12),
                      Text(metrics[i].$3,
                          style: TextStyle(
                              fontSize: 11,
                              color: i == 0 ? Colors.white70 : muted)),
                    ]),
              ))
      ]),
      const SizedBox(height: 20),
      if (accounts.isEmpty)
        empty('Your ledger starts here',
            'Add a manual account, record a dated balance, then import your transactions. No sample balances are shown.',
            action: FilledButton.icon(
                onPressed: addAccount,
                icon: const Icon(Icons.add),
                label: const Text('Add your first account')))
      else ...[
        panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          sectionTitle('Spending by category', 'Posted activity for $month'),
          const SizedBox(height: 22),
          if (summary.categories.isEmpty)
            const Text('No categorized spending in this month.',
                style: TextStyle(color: muted)),
          for (final entry
              in summary.categories.entries.where((e) => e.value > 0))
            Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Column(children: [
                  Row(children: [
                    Text(categoryName(entry.key)),
                    const Spacer(),
                    Text(money(entry.value),
                        style: const TextStyle(fontWeight: FontWeight.w600))
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                          minHeight: 8,
                          value: summary.spending <= 0
                              ? 0
                              : (entry.value / summary.spending).clamp(0, 1),
                          backgroundColor: canvas,
                          color: teal)),
                ])),
        ])),
        const SizedBox(height: 20),
        panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          sectionTitle('Account coverage',
              'Missing or stale snapshots are not assumed to be zero.'),
          const SizedBox(height: 12),
          for (final a in accounts) accountRow(a)
        ])),
      ],
      const SizedBox(height: 20),
      panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sectionTitle(
            'Recent activity', 'Latest loaded posted and pending entries'),
        const SizedBox(height: 16),
        if (transactions.isEmpty)
          const Text('No transactions yet.', style: TextStyle(color: muted)),
        for (final t in transactions.take(5)) transactionRow(t)
      ])),
    ]);
  }

  Widget sectionTitle(String title, String subtitle) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 5),
        Text(subtitle, style: const TextStyle(color: muted, fontSize: 12))
      ]);
  String categoryName(Object? id) =>
      '${categories.where((c) => c['id'] == id).firstOrNull?['name'] ?? 'Uncategorized'}';
  String accountName(Object? id) =>
      '${accounts.where((a) => a['id'] == id).firstOrNull?['name'] ?? 'Account'}';

  Widget accountRow(Json a) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(children: [
        Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: canvas, borderRadius: BorderRadius.circular(12)),
            child: Icon(
                a['type'] == 'credit'
                    ? Icons.credit_card
                    : Icons.account_balance_outlined,
                color: teal)),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${a['name']}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
              '${a['institution'] ?? 'Manual'}${a['last_four'] == null ? '' : ' / •••• ${a['last_four']}'}',
              style: const TextStyle(color: muted, fontSize: 12)),
          Text(
              '${a['connection_state'] ?? a['source']} / ${a['balance_at'] == null ? 'No balance snapshot' : 'Balance as of ${a['balance_at']}'}',
              style: const TextStyle(color: muted, fontSize: 10))
        ])),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
              a['balance_minor'] == null
                  ? 'Unknown'
                  : money(integer(a['balance_minor'])),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (a['balance_minor'] != null &&
              staleBalance(a['balance_at'], DateTime.now()))
            const Text('Stale: over 7 days',
                style: TextStyle(fontSize: 10, color: Colors.deepOrange))
        ]),
      ]));

  Widget accountsPage() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          FilledButton.icon(
              onPressed: working ? null : addAccount,
              icon: const Icon(Icons.add),
              label: const Text('Add manual account')),
          OutlinedButton.icon(
              onPressed: working || !bankLinkingEnabled ? null : connectBank,
              icon: const Icon(Icons.link),
              label: const Text('Connect bank'))
        ]),
        const SizedBox(height: 16),
        if (!bankLinkingEnabled)
          const Text(
              'Bank linking is disabled. CSV imports and manual snapshots are available. Live linking requires owner approval and verified institution coverage.',
              style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 20),
        panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          sectionTitle('Balance refresh allowance',
              'Conservative app reservations, including uncertain provider failures. UTC month.'),
          const SizedBox(height: 12),
          if (refreshUsage != null)
            Text(
                '${refreshUsage!['month']}: ${refreshUsage!['reservedAttempts']} / ${refreshUsage!['limit']} attempts reserved. ${refreshUsage!['remainingAttempts']} remaining.'),
          if (usageError != null)
            Text(usageError!, style: const TextStyle(color: Colors.deepOrange)),
        ])),
        const SizedBox(height: 20),
        if (accounts.isEmpty)
          empty('No accounts yet',
              'Add cash or credit accounts to begin. Credit snapshots represent positive outstanding debt.'),
        for (final a in accounts)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: panel(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    accountRow(a),
                    if (a['sync_error'] != null)
                      Text('Sync issue: ${a['sync_error']}',
                          style: const TextStyle(color: Colors.deepOrange)),
                    Text(
                        'Last successful sync: ${a['last_synced_at'] ?? 'Not synced'}',
                        style: const TextStyle(color: muted, fontSize: 12)),
                    const SizedBox(height: 14),
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      if (a['source'] == 'manual')
                        OutlinedButton.icon(
                            onPressed: () => snapshot(a),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Record balance')),
                      if (a['source'] == 'stripe') ...[
                        Text(
                            'Next app-eligible refresh: ${nextRefresh(a['id']) ?? 'Now (subject to provider availability)'}',
                            style: const TextStyle(color: muted, fontSize: 12)),
                        OutlinedButton(
                            onPressed: working ||
                                    refreshUsage == null ||
                                    integer(refreshUsage![
                                            'remainingAttempts']) <=
                                        0
                                ? null
                                : () async {
                                    if (await confirm('Refresh balance?',
                                        'A successful Stripe balance call is currently advertised at approximately \$0.10. The server enforces a 50-attempt monthly app cap and account cooldown. The cap does not cover charges outside this app.')) {
                                      perform(() async {
                                        await repo.api(
                                            'accounts/${a['id']}/balance-refresh',
                                            body: {'confirmCost': true});
                                      },
                                          success:
                                              'Refresh requested. The balance will update after provider completion.');
                                    }
                                  },
                            child: const Text('Request paid refresh')),
                        TextButton(
                            onPressed: () async {
                              if (await confirm('Disconnect this bank?',
                                  'Stops provider subscriptions and access. Your existing history is retained.')) {
                                perform(() async {
                                  await repo
                                      .api('accounts/${a['id']}/disconnect');
                                });
                              }
                            },
                            child: const Text('Disconnect')),
                      ],
                      TextButton(
                          onPressed: working
                              ? null
                              : () async {
                                  if (await confirm(
                                      'Permanently delete this account?',
                                      'This removes the account, snapshots, transactions, annotations, and import history. Connected accounts are removed only after provider cleanup succeeds. This cannot be undone.')) {
                                    await perform(() async {
                                      await repo.api(
                                          'accounts/${a['id']}/delete',
                                          body: {'confirmDelete': true});
                                    },
                                        success:
                                            'Deletion requested. Connected-account cleanup may take time.');
                                  }
                                },
                          child: const Text('Delete account',
                              style: TextStyle(color: Color(0xffaa3333)))),
                    ]),
                  ]))),
      ]);

  Object? nextRefresh(Object? accountId) {
    final rows = refreshUsage?['accounts'];
    if (rows is! List) return null;
    return rows
        .whereType<Map>()
        .where((row) => row['accountId'] == accountId)
        .firstOrNull?['nextEligibleRefreshAt'];
  }

  Widget transactionRow(Json t) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
          backgroundColor: canvas,
          child: Icon(
              integer(t['amount_minor']) < 0
                  ? Icons.north_east
                  : Icons.south_west,
              color: teal,
              size: 18)),
      title: Text('${t['description']}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(
          '${t['posted_date'] ?? t['transaction_date']} / ${accountName(t['account_id'])}\n${categoryName(t['category_id'])} / ${t['status']}${t['is_transfer'] == true ? ' / Transfer' : ''}${t['is_card_payment'] == true ? ' / Card payment' : ''}',
          style: const TextStyle(fontSize: 11, color: muted)),
      isThreeLine: true,
      trailing: Text(money(integer(t['amount_minor'])),
          style: TextStyle(
              fontWeight: FontWeight.w600,
              color: integer(t['amount_minor']) > 0 ? teal : ink)),
      onTap: () => annotate(t));

  Widget transactionsPage() {
    final filtered = transactions
        .where((t) =>
            '${t['description']} ${t['note'] ?? ''}'
                .toLowerCase()
                .contains(search.toLowerCase()) &&
            (accountFilter == null || t['account_id'] == accountFilter) &&
            (statusFilter == 'all' || t['status'] == statusFilter) &&
            (categoryFilter == 'all' ||
                (categoryFilter == 'uncategorized'
                    ? t['category_id'] == null
                    : t['category_id'] == categoryFilter)) &&
            (!monthOnly ||
                '${t['posted_date'] ?? t['transaction_date']}'
                    .startsWith(month)))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      panel(
          child: Column(children: [
        TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search descriptions and notes'),
            onChanged: (v) => setState(() => search = v)),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 12, children: [
          SizedBox(
              width: 230,
              child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: accountFilter,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: [
                    const DropdownMenuItem<String>(
                        value: null, child: Text('All accounts')),
                    for (final a in accounts)
                      DropdownMenuItem(
                          value: '${a['id']}', child: Text('${a['name']}'))
                  ],
                  onChanged: (v) => setState(() => accountFilter = v))),
          SizedBox(
              width: 200,
              child: DropdownButtonFormField<String>(
                  initialValue: statusFilter,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [
                    for (final s in ['all', 'posted', 'pending', 'void'])
                      DropdownMenuItem(value: s, child: Text(s))
                  ],
                  onChanged: (v) => setState(() => statusFilter = v ?? 'all'))),
          SizedBox(
              width: 230,
              child: DropdownButtonFormField<String>(
                  initialValue: categoryFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    const DropdownMenuItem(
                        value: 'all', child: Text('All categories')),
                    const DropdownMenuItem(
                        value: 'uncategorized', child: Text('Uncategorized')),
                    for (final c in categories)
                      DropdownMenuItem(
                          value: '${c['id']}', child: Text('${c['name']}'))
                  ],
                  onChanged: (v) =>
                      setState(() => categoryFilter = v ?? 'all'))),
        ]),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Only $month'),
            value: monthOnly,
            onChanged: (v) => setState(() => monthOnly = v))
      ])),
      const SizedBox(height: 20),
      panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sectionTitle('${filtered.length} transactions',
            'Tap an entry to edit category, transfer flags, or a note. Pending and void activity do not count toward budgets.'),
        const SizedBox(height: 16),
        if (filtered.isEmpty)
          const Text('No matching transactions.',
              style: TextStyle(color: muted)),
        for (final t in filtered.take(visibleTransactions)) transactionRow(t),
        if (filtered.length > visibleTransactions)
          TextButton(
              onPressed: () => setState(() => visibleTransactions += 100),
              child: Text(
                  'Show 100 more (${filtered.length - visibleTransactions} remaining)'))
      ])),
    ]);
  }

  Widget budgetsPage() {
    final actual = LedgerSummary.calculate(transactions, month).categories;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        FilledButton.icon(
            onPressed: categories.isEmpty ? null : editBudget,
            icon: const Icon(Icons.add),
            label: const Text('Set category budget')),
        OutlinedButton.icon(
            onPressed: addCategory,
            icon: const Icon(Icons.label_outline),
            label: const Text('Add category'))
      ]),
      const SizedBox(height: 20),
      if (categories.isEmpty)
        empty('Start with your categories',
            'Add a category, then assign a monthly spending limit. Budgets do not roll over.'),
      for (final c in categories)
        Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: panel(child: Builder(builder: (context) {
              final budget = budgets
                  .where((b) =>
                      b['category_id'] == c['id'] &&
                      '${b['month']}'.startsWith(month))
                  .firstOrNull;
              final limit = integer(budget?['amount_minor']);
              final spent = actual[c['id']] ?? 0;
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                          child: Text('${c['name']}',
                              style: Theme.of(context).textTheme.titleMedium)),
                      TextButton(
                          onPressed: () => renameCategory(c),
                          child: const Text('Rename'))
                    ]),
                    const SizedBox(height: 8),
                    Text(
                        '${money(spent)} spent / ${budget == null ? 'No budget set' : '${money(limit)} budget'}',
                        style: const TextStyle(color: muted)),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                        minHeight: 8,
                        value: limit <= 0 ? 0 : (spent / limit).clamp(0, 1),
                        backgroundColor: canvas,
                        color: spent > limit && budget != null
                            ? Colors.deepOrange
                            : teal),
                    if (budget != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text('${money(limit - spent)} remaining',
                              style: TextStyle(
                                  color:
                                      spent > limit ? Colors.deepOrange : teal,
                                  fontSize: 12)))
                  ]);
            }))),
    ]);
  }

  Widget importsPage() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          sectionTitle('Bring your transaction history',
              'CSV files stay in memory during preview. Maximum 5 MB / 10,000 rows. USD only.'),
          const SizedBox(height: 18),
          const Text(
              'Choose an account and explicitly map your bank\'s date, description, and amount columns. Preview validates rows and duplicate candidates before anything is committed.'),
          const SizedBox(height: 20),
          FilledButton.icon(
              onPressed: accounts.isEmpty ? null : importCsv,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose CSV file'))
        ])),
        const SizedBox(height: 20),
        panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          sectionTitle('Import history',
              'Undo is server-validated and preserves reconciled transactions and unrelated edits.'),
          const SizedBox(height: 14),
          if (batches.isEmpty)
            const Text('No imports yet.', style: TextStyle(color: muted)),
          for (final b in batches)
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    '${accountName(b['account_id'])} / ${b['created_at'] ?? ''}'),
                subtitle: Text(
                    '${b['inserted'] ?? 0} rows / ${b['undone_at'] == null ? 'Imported' : 'Undone (edited rows retained)'}'),
                trailing: TextButton(
                    onPressed: working || b['undone_at'] != null
                        ? null
                        : () async {
                            if (await confirm('Undo this import?',
                                'Only eligible transactions belonging to this batch will be removed. Reconciled data and unrelated later edits are preserved.')) {
                              perform(() async {
                                await repo.api('imports/${b['id']}/undo');
                              });
                            }
                          },
                    child: const Text('Undo')))
        ])),
        const SizedBox(height: 20),
        panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          sectionTitle('Your data, portable',
              'Export accounts, snapshots, transactions, annotations, categories, and budgets.'),
          const SizedBox(height: 14),
          const Text(
              'Exports contain sensitive financial information. Store them privately, outside Git and public cloud folders. A portable export is not a full database backup.'),
          const SizedBox(height: 18),
          OutlinedButton.icon(
              onPressed: () async {
                if (await confirm('Download sensitive data?',
                    'This creates a financial export on your device. The app cannot control how your browser stores the downloaded file.')) {
                  perform(() async {
                    final result = await repo.api('export', get: true);
                    await platform.download(
                        'ledger-export-${DateTime.now().toIso8601String().substring(0, 10)}.json',
                        const JsonEncoder.withIndent('  ').convert(result));
                  }, success: 'Export downloaded. Keep it private.');
                }
              },
              icon: const Icon(Icons.download_outlined),
              label: const Text('Export JSON'))
        ])),
      ]);

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(message), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Confirm'))
              ])) ??
      false;

  Future<void> form(
      String title, List<Widget> fields, Future<void> Function() save) async {
    var saving = false;
    var closed = false;
    String? message;
    final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: Text(title),
                  content: SizedBox(
                      width: 440,
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            ...fields
                                .expand((f) => [f, const SizedBox(height: 16)]),
                            if (message != null)
                              Text(message!,
                                  style: const TextStyle(color: Colors.red))
                          ]))),
                  actions: [
                    TextButton(
                        onPressed:
                            saving ? null : () => Navigator.pop(dialogContext),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                update(() {
                                  saving = true;
                                  message = null;
                                });
                                try {
                                  await save();
                                  closed = true;
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                  if (mounted) await load();
                                } catch (e) {
                                  if (context.mounted && !closed) {
                                    update(() => message = safeMessage(e));
                                  }
                                } finally {
                                  if (context.mounted && !closed) {
                                    update(() => saving = false);
                                  }
                                }
                              },
                        child: Text(saving ? 'Saving...' : 'Save'))
                  ],
                )));
    await Navigator.of(context).push(route);
    await route.completed;
  }

  Future<void> addAccount() async {
    final name = TextEditingController();
    final institution = TextEditingController();
    final lastFour = TextEditingController();
    var type = 'cash';
    await form('Add a manual account', [
      TextField(
          controller: name,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Account name')),
      TextField(
          controller: institution,
          maxLength: 100,
          decoration:
              const InputDecoration(labelText: 'Institution (optional)')),
      TextField(
          controller: lastFour,
          maxLength: 4,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Last four digits only (optional)')),
      DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: type,
          decoration: const InputDecoration(labelText: 'Balance semantics'),
          items: const [
            DropdownMenuItem(
                value: 'cash', child: Text('Cash / checking / savings')),
            DropdownMenuItem(
                value: 'credit', child: Text('Credit card liability'))
          ],
          onChanged: (v) => type = v!),
      const Text(
          'Do not enter full account numbers. Record the current balance separately after creation.',
          style: TextStyle(color: muted, fontSize: 12)),
    ], () async {
      if (name.text.trim().isEmpty) {
        throw const FormatException('Enter an account name.');
      }
      if (lastFour.text.isNotEmpty &&
          !RegExp(r'^\d{4}$').hasMatch(lastFour.text)) {
        throw const FormatException(
            'Enter exactly four digits or leave blank.');
      }
      await repo.client.from('accounts').insert({
        'owner_id': repo.client.auth.currentUser!.id,
        'name': name.text.trim(),
        'institution': institution.text.trim(),
        'last_four': lastFour.text.isEmpty ? null : lastFour.text,
        'kind': type,
        'source': 'manual',
        'currency': 'USD'
      });
    });
    name.dispose();
    institution.dispose();
    lastFour.dispose();
  }

  Future<void> settings() async {
    final zone = TextEditingController(text: timezone);
    await form('Reporting settings', [
      const Text(
          'Currency: USD. Budgets do not roll over. This version supports America/Denver only. Bank dates are normalized by the backend; changing your device timezone does not rewrite them.'),
      TextField(
          controller: zone,
          readOnly: true,
          decoration: const InputDecoration(labelText: 'Reporting timezone')),
    ], () async {
      if (zone.text.trim() != 'America/Denver') {
        throw const FormatException(
            'This version supports America/Denver only.');
      }
      await repo.client.from('profiles').upsert({
        'owner_id': repo.client.auth.currentUser!.id,
        'currency': 'USD',
        'reporting_timezone': zone.text.trim()
      });
    });
    zone.dispose();
  }

  Future<void> snapshot(Json account) async {
    final amount = TextEditingController();
    final date = TextEditingController(
        text: DateTime.now().toIso8601String().substring(0, 10));
    await form('Record balance', [
      Text(
          '${account['name']}: ${account['type'] == 'credit' ? 'enter positive outstanding debt' : 'enter current cash balance'}. This is not calculated from imported transactions.'),
      TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          decoration:
              const InputDecoration(labelText: 'Current balance (USD)')),
      TextField(
          controller: date,
          decoration:
              const InputDecoration(labelText: 'Observed date (YYYY-MM-DD)'))
    ], () async {
      final value = parseMoney(amount.text);
      if (account['type'] == 'credit' && value < 0) {
        throw const FormatException('Credit debt must be zero or positive.');
      }
      final observed = observationDate(date.text, DateTime.now());
      await repo.client.from('balance_snapshots').insert({
        'owner_id': repo.client.auth.currentUser!.id,
        'account_id': account['id'],
        'current_minor': value,
        'observed_at': observed.toUtc().toIso8601String(),
        'source': 'manual'
      });
    });
    amount.dispose();
    date.dispose();
  }

  Future<void> annotate(Json transaction) async {
    String? category = transaction['category_id'];
    var transfer = transaction['is_transfer'] == true;
    var payment = transaction['is_card_payment'] == true;
    final note =
        TextEditingController(text: transaction['note'] as String? ?? '');
    await form('Annotate transaction', [
      Text(
          '${transaction['description']} / ${money(integer(transaction['amount_minor']))}'),
      DropdownButtonFormField<String>(
          initialValue: category,
          decoration: const InputDecoration(labelText: 'Category'),
          items: [
            const DropdownMenuItem<String>(
                value: null, child: Text('Uncategorized')),
            for (final c in categories)
              DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}'))
          ],
          onChanged: (v) => category = v),
      StatefulBuilder(
          builder: (context, update) => Column(children: [
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Own-account transfer'),
                    value: transfer,
                    onChanged: (v) => update(() => transfer = v)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Card payment'),
                    value: payment,
                    onChanged: (v) => update(() => payment = v))
              ])),
      const Text(
          'Transfers and card payments are excluded from income, spending, and budgets on both sides. Confirm each side yourself; equal amounts alone do not prove a match.',
          style: TextStyle(fontSize: 12, color: muted)),
      TextField(
          controller: note,
          maxLength: 1000,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Private note'))
    ], () async {
      await repo.client.from('transaction_annotations').upsert({
        'owner_id': repo.client.auth.currentUser!.id,
        'transaction_id': transaction['id'],
        'category_id': category,
        'is_transfer': transfer,
        'is_card_payment': payment,
        'note': note.text,
        'updated_at': DateTime.now().toUtc().toIso8601String()
      }, onConflict: 'transaction_id');
    });
    note.dispose();
  }

  Future<void> addCategory() async {
    final name = TextEditingController();
    var kind = 'expense';
    await form('Add category', [
      TextField(
          controller: name,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Category name')),
      DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: kind,
          decoration: const InputDecoration(labelText: 'Kind'),
          items: const [
            DropdownMenuItem(
                value: 'expense',
                child: Text('Expense (refunds offset spending)')),
            DropdownMenuItem(value: 'income', child: Text('Income'))
          ],
          onChanged: (v) => kind = v!)
    ], () async {
      if (name.text.trim().isEmpty) {
        throw const FormatException('Enter a category name.');
      }
      await repo.client.from('categories').insert({
        'owner_id': repo.client.auth.currentUser!.id,
        'name': name.text.trim(),
        'kind': kind
      });
    });
    name.dispose();
  }

  Future<void> renameCategory(Json category) async {
    final name = TextEditingController(text: '${category['name']}');
    await form('Rename category', [
      TextField(
          controller: name,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Name'))
    ], () async {
      if (name.text.trim().isEmpty) {
        throw const FormatException('Enter a name.');
      }
      await repo.client
          .from('categories')
          .update({'name': name.text.trim()}).eq('id', category['id']);
    });
    name.dispose();
  }

  Future<void> editBudget() async {
    String category = '${categories.first['id']}';
    final amount = TextEditingController();
    await form('Set budget for $month', [
      DropdownButtonFormField<String>(
          initialValue: category,
          decoration: const InputDecoration(labelText: 'Category'),
          items: [
            for (final c in categories)
              DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}'))
          ],
          onChanged: (v) => category = v!),
      TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Monthly amount (USD)')),
      const Text(
          'Saving replaces this category\'s budget for the selected month. There is no rollover.')
    ], () async {
      final value = parseMoney(amount.text);
      if (value < 0) {
        throw const FormatException('Budget must be zero or positive.');
      }
      await repo.client.from('monthly_budgets').upsert({
        'owner_id': repo.client.auth.currentUser!.id,
        'category_id': category,
        'month': '$month-01',
        'amount_minor': value
      }, onConflict: 'owner_id,category_id,month');
    });
    amount.dispose();
  }

  Future<void> connectBank() async {
    if (!await confirm('Connect a bank?',
        'This is read-only Financial Connections, not payments. Daily transaction subscriptions may incur ongoing charges. Confirm approval, actual pricing, and exact account coverage before continuing.')) {
      return;
    }
    await perform(() async {
      final session = await repo.api('connections/session');
      await platform.linkStripe(stripeKey, session['clientSecret'] as String);
      await repo.api('connections/complete',
          body: {'sessionId': session['sessionId']});
    }, success: 'Connection verified. Initial transaction sync may take time.');
  }

  Future<void> importCsv() async {
    try {
      final csv = await platform.pickCsv();
      if (csv == null) return;
      final rows = parseCsv(csv);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ImportDialog(
              repository: repo,
              accounts: accounts,
              csv: csv,
              headers: rows.first));
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }
}

class ImportDialog extends StatefulWidget {
  final LedgerRepository repository;
  final List<Json> accounts;
  final String csv;
  final List<String> headers;
  const ImportDialog(
      {super.key,
      required this.repository,
      required this.accounts,
      required this.csv,
      required this.headers});
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  late String account;
  final mapping = <String, dynamic>{
    'dateFormat': 'YYYY-MM-DD',
    'sign': 'inflow-positive'
  };
  bool split = false, busy = false, overlap = false;
  Json? preview;
  String? error;
  @override
  void initState() {
    super.initState();
    account = '${widget.accounts.first['id']}';
  }

  void change(VoidCallback action) {
    if (!busy) {
      setState(() {
        action();
        preview = null;
        overlap = false;
      });
    }
  }

  Json get body => {
        'accountId': account,
        'csv': widget.csv,
        'mapping': Map<String, dynamic>.from(mapping),
        'confirmOverlap': overlap
      };
  Widget column(String key, String label, {bool optional = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<String>(
        key: ValueKey(key),
        isExpanded: true,
        initialValue: mapping[key] as String?,
        decoration: InputDecoration(labelText: label),
        items: [
          if (optional)
            const DropdownMenuItem<String>(
                value: null, child: Text('Not mapped')),
          for (final header in widget.headers.toSet())
            DropdownMenuItem(
                value: header,
                child: Text(header.isEmpty ? '(empty header)' : header))
        ],
        onChanged: (value) => change(() {
          if (value == null) {
            mapping.remove(key);
          } else {
            mapping[key] = value;
          }
        }),
      ));

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Map and preview CSV'),
          content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    const Text(
                        'No format guessing. Map exact header names and confirm the bank\'s sign convention. Dates are bank calendar dates in your reporting timezone.',
                        style: TextStyle(color: muted, fontSize: 12)),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                        initialValue: account,
                        decoration: const InputDecoration(
                            labelText: 'Destination account'),
                        items: [
                          for (final a in widget.accounts)
                            DropdownMenuItem(
                                value: '${a['id']}',
                                child: Text('${a['name']} (${a['source']})'))
                        ],
                        onChanged: (v) => change(() => account = v!)),
                    const SizedBox(height: 14),
                    column('date', 'Transaction date'),
                    column('description', 'Description'),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Separate debit and credit columns'),
                        value: split,
                        onChanged: (v) => change(() {
                              split = v;
                              mapping.remove('amount');
                              mapping.remove('debit');
                              mapping.remove('credit');
                            })),
                    if (split) ...[
                      column('debit', 'Debit column'),
                      column('credit', 'Credit column')
                    ] else
                      column('amount', 'Signed amount column'),
                    column('transactionId', 'Bank transaction ID (optional)',
                        optional: true),
                    column('currency', 'Currency column (optional; USD only)',
                        optional: true),
                    DropdownButtonFormField<String>(
                        initialValue: mapping['dateFormat'] as String,
                        decoration:
                            const InputDecoration(labelText: 'Date format'),
                        items: [
                          for (final f in [
                            'YYYY-MM-DD',
                            'MM/DD/YYYY',
                            'DD/MM/YYYY'
                          ])
                            DropdownMenuItem(value: f, child: Text(f))
                        ],
                        onChanged: (v) =>
                            change(() => mapping['dateFormat'] = v)),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: mapping['sign'] as String,
                        decoration: const InputDecoration(
                            labelText: 'Signed amount convention'),
                        items: const [
                          DropdownMenuItem(
                              value: 'inflow-positive',
                              child: Text(
                                  'Positive = money in / negative = spending')),
                          DropdownMenuItem(
                              value: 'outflow-positive',
                              child: Text(
                                  'Positive = spending / negative = money in'))
                        ],
                        onChanged: split
                            ? null
                            : (v) => change(() => mapping['sign'] = v)),
                    if (error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(error!,
                              style: const TextStyle(color: Colors.red))),
                    if (preview != null) ...[
                      const Divider(height: 32),
                      Text('Server preview',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(
                          '${preview!['rowCount'] ?? 0} source rows / first 10 valid rows shown'),
                      Text(
                          'Duplicate candidates: ${preview!['duplicateCandidates'] is List ? (preview!['duplicateCandidates'] as List).length : preview!['duplicateCandidates'] ?? 0}'),
                      if (preview!['errors'] is List)
                        for (final e in (preview!['errors'] as List).take(20))
                          Text(
                              e is Map
                                  ? 'Row ${e['row']}: ${e['message']}'
                                  : '$e',
                              style: const TextStyle(color: Colors.red)),
                      if (preview!['rows'] is List)
                        for (final row in (preview!['rows'] as List).take(10))
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Text(
                                  row is Map
                                      ? '${row['transaction_date']} / ${row['description']} / ${money(integer(row['amount_minor']))}'
                                      : '$row',
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12))),
                      if (preview!['duplicateCandidates'] is List)
                        for (final row
                            in (preview!['duplicateCandidates'] as List)
                                .take(20))
                          Text(
                              row is Map
                                  ? 'Possible duplicate: ${row['date']} / ${money(integer(row['amountMinor']))}'
                                  : '$row',
                              style:
                                  const TextStyle(fontSize: 12, color: muted)),
                      if (preview!['overlapRequiresConfirmation'] == true)
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: overlap,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => overlap = v!),
                            title: const Text(
                                'I reviewed duplicate candidates. Existing matching rows will be retained. Cross-source overlapping dates are refused until manually reconciled.')),
                      const Text(
                          'Repeated identical purchases may be legitimate. Review duplicate candidates; do not assume matching amounts prove the same transaction.',
                          style: TextStyle(fontSize: 12, color: muted)),
                    ],
                  ]))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel')),
            OutlinedButton(
                onPressed: busy ? null : () => request(false),
                child: const Text('Validate preview')),
            FilledButton(
                onPressed: busy ||
                        preview == null ||
                        (preview!['errors'] is List &&
                            (preview!['errors'] as List).isNotEmpty) ||
                        (preview!['overlapRequiresConfirmation'] == true &&
                            !overlap)
                    ? null
                    : () => request(true),
                child: Text(busy ? 'Working...' : 'Commit import'))
          ]);

  Future<void> request(bool commit) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!mapping.containsKey('date') ||
          !mapping.containsKey('description') ||
          (split
              ? !mapping.containsKey('debit') || !mapping.containsKey('credit')
              : !mapping.containsKey('amount'))) {
        throw const FormatException('Map all required columns first.');
      }
      final result = await widget.repository
          .api('imports/${commit ? 'commit' : 'preview'}', body: body);
      if (!mounted) return;
      if (commit) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Import committed: ${result['inserted'] ?? 0} inserted / ${result['duplicates'] ?? 0} duplicates retained.')));
        Navigator.pop(context);
      } else {
        setState(() => preview = result);
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
