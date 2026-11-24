import 'dart:convert';
import '../l10n/app_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:quick_actions/quick_actions.dart';
import '../domain/analytics.dart';
import '../domain/finance.dart';
import '../domain/appearance.dart';
import '../domain/pdf_receipt.dart';
import '../domain/records.dart';
import '../domain/templates.dart';
import '../domain/transaction_filter.dart';
import 'app_theme.dart';
import 'data_tools.dart';
import '../services/app_lock.dart';
import '../services/app_store.dart';
import '../services/launch_actions.dart';
import '../services/notifications.dart';
import 'design.dart';
import 'editors.dart';
import 'notifications_panel.dart';
import 'privacy.dart';
import 'saved_receipt_page.dart';
import 'transactions_page.dart';
import 'v2_common.dart';
import 'v2_pages.dart';

class BalanceApp extends StatelessWidget {
  const BalanceApp({
    super.key,
    required this.store,
    this.lock,
    this.notifications,
  });
  final AppStore store;
  final Notifications? notifications;

  /// App lock and privacy cover; absent in tests that do not need it.
  final AppLock? lock;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => MaterialApp(
      onGenerateTitle: (context) =>
          uiTextFor(Localizations.localeOf(context).languageCode, 'Баланс'),
      debugShowCheckedModeBanner: false,
      locale: store.appLanguage == 'system' ? null : Locale(store.appLanguage),
      supportedLocales: appLocales,
      localeResolutionCallback: resolveAppLocale,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: BalanceThemes.build(
        Brightness.light,
        ColorPreset.fromId(store.themePreset),
      ),
      darkTheme: BalanceThemes.build(
        Brightness.dark,
        ColorPreset.fromId(store.themePreset),
      ),
      themeMode: store.theme == 'dark'
          ? ThemeMode.dark
          : store.theme == 'light'
          ? ThemeMode.light
          : ThemeMode.system,
      builder: (context, child) {
        appLocale = Localizations.localeOf(context).languageCode;
        return PrivacyGate(lock: lock, child: child ?? const SizedBox.shrink());
      },
      home: store.ready
          ? BalanceShell(store: store, lock: lock, notifications: notifications)
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
  );
}

class BalanceShell extends StatefulWidget {
  const BalanceShell({
    super.key,
    required this.store,
    this.lock,
    this.notifications,
  });
  final AppStore store;
  final AppLock? lock;
  final Notifications? notifications;
  @override
  State<BalanceShell> createState() => _BalanceShellState();
}

class _BalanceShellState extends State<BalanceShell> {
  AppStore get store => widget.store;
  int page = 0;

  /// `1`, `3`, `12` months, `year` or `custom`.
  String analyticsMode = '1';
  int reportYear = DateTime.now().year;
  AnalyticsPeriod? customPeriod;
  String? trendCategory;
  TransactionFilter listFilter = const TransactionFilter();
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  DateTime budgetMonth = DateTime(DateTime.now().year, DateTime.now().month);

  /// Pages by index: 0–4 keep their v1 places (and Ctrl/⌘+1…5), 5–8 are
  /// the contract v2 sections, 9 is «Ещё» — the phone hub for 4–8.
  static const titles = [
    'Обзор',
    'Операции',
    'Аналитика',
    'Бюджеты',
    'Настройки',
    'Счета',
    'Регулярные платежи',
    'Цели',
    'Долги',
    'Ещё',
  ];
  static const icons = [
    Icons.space_dashboard_outlined,
    Icons.receipt_long_outlined,
    Icons.insights_outlined,
    Icons.savings_outlined,
    Icons.settings_outlined,
    Icons.account_balance_wallet_outlined,
    Icons.event_repeat,
    Icons.flag_outlined,
    Icons.handshake_outlined,
    Icons.more_horiz,
  ];
  static const shortTitles = [
    'Обзор',
    'Операции',
    'Аналитика',
    'Бюджеты',
    'Настройки',
    'Счета',
    'Регулярные',
    'Цели',
    'Долги',
    'Ещё',
  ];
  static const subtitles = [
    '',
    'Вся история ваших финансов',
    'Понимайте, куда уходят деньги',
    'Планируйте расходы по категориям',
    'Ваши предпочтения и данные',
    'Наличные, карты, вклады и переводы',
    'Подписки, аренда, зарплата',
    'Копите на важное',
    'Кто кому должен',
    'Счета, цели, долги и настройки',
  ];

  /// Bottom bar on phones and the rail on wide screens.
  static const phonePages = [0, 1, 2, 3, 9];
  static const railPages = [0, 1, 2, 3, 5, 6, 7, 8, 4];

  /// Analytics and budgets work on amounts in the base currency (§2–3).
  List<TransactionRecord> get base => store.baseTransactions.items;

  Future<void> addRate(String from, String to) =>
      editRate(context, store, run, from: from, to: to);
  Future<void> run(Future<void> Function() action, {String? success}) async {
    try {
      await action();
      if (success != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(uiError(e)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    LaunchActions.listen(quickAdd);
    widget.notifications?.onTap = openNotification;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final action = await LaunchActions.initialAction();
      if (action != null && mounted) await quickAdd(action);
      final payload = await widget.notifications?.launchPayload();
      if (payload != null && mounted) await openNotification(payload);
    });
    _setupShortcuts();
  }

  /// App icon shortcuts («Расход», «Доход») on Android and iOS.
  Future<void> _setupShortcuts() async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }
    try {
      const actions = QuickActions();
      await actions.initialize((type) {
        if (mounted) quickAdd(type);
      });
      await actions.setShortcutItems([
        ShortcutItem(type: 'expense', localizedTitle: uiText('Расход')),
        ShortcutItem(type: 'income', localizedTitle: uiText('Доход')),
      ]);
    } catch (_) {
      // Shortcuts are optional; the plugin is absent in tests.
    }
  }

  /// A tapped notification: the reminder opens a new expense, a budget alert
  /// the budgets page.
  Future<void> openNotification(String payload) async {
    if (!mounted) return;
    if (payload == 'reminder') {
      await quickAdd('expense');
    } else if (payload == 'budget') {
      Navigator.of(context).popUntil((route) => route.isFirst);
      setState(() {
        page = 3;
        budgetMonth = DateTime(DateTime.now().year, DateTime.now().month);
      });
    }
  }

  /// Entry from a shortcut, the Quick Settings tile or the home widget.
  Future<void> quickAdd(String action) async {
    if (!mounted || (action != 'expense' && action != 'income')) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await editTransaction(
      null,
      TransactionTemplate.blank(TransactionKind.parse(action)),
    );
  }

  Future<void> editTransaction([
    TransactionRecord? value,
    TransactionTemplate? draft,
  ]) async {
    final result = await editDialog<TransactionRecord>(
      context,
      TransactionEditor(
        existing: value,
        draft: draft,
        categories: store.categories,
        store: store,
        attachments: value != null && store.supportsAttachments
            ? AttachmentsSection(store: store, transactionId: value.id)
            : null,
      ),
    );
    if (result != null) await run(() => store.saveTransaction(result));
  }

  Widget quickEntry() {
    final saved = store.templates;
    final known = {for (final t in saved) t.signature};
    final frequent = TransactionTemplate.frequent(
      store.transactions,
      DateTime.now(),
    ).where((t) => !known.contains(t.signature));
    if (saved.isEmpty && frequent.isEmpty) return const SizedBox.shrink();
    Widget chip(TransactionTemplate t, {required bool isSaved}) {
      final amount = t.amountMinor > 0
          ? ' · ${money(t.amountMinor, store.baseCurrency)}'
          : '';
      // No chip tooltip: its long-press recognizer would swallow deletion.
      return Semantics(
        hint: isSaved
            ? uiText('Шаблон. Удерживайте, чтобы удалить')
            : uiText('Часто повторяется'),
        child: GestureDetector(
          onLongPress: isSaved ? () => removeTemplate(t) : null,
          onSecondaryTap: isSaved ? () => removeTemplate(t) : null,
          child: ActionChip(
            avatar: CategoryAvatar(
              icon: t.categoryIcon,
              emoji: t.categoryEmoji,
              color: t.categoryColorName,
              size: 24,
            ),
            label: Text(
              '${t.note.isEmpty ? categoryTitle(t.categoryName) : t.note}$amount',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => editTransaction(null, t),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        sectionTitle(uiText('Быстрый ввод')),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in saved) chip(t, isSaved: true),
            for (final t in frequent) chip(t, isSaved: false),
          ],
        ),
      ],
    );
  }

  Future<void> removeTemplate(TransactionTemplate t) async {
    if (await confirmDelete(
      context,
      uiText('Удалить шаблон «{0}»?', [t.title]),
      message: uiText('Операции не изменятся, удалится только шаблон.'),
    )) {
      await run(() => store.deleteTemplate(t.id));
    }
  }

  Future<void> editCategory([CategoryRecord? value]) async {
    final result = await editDialog<CategoryRecord>(
      context,
      CategoryEditor(existing: value, categories: store.categories),
    );
    if (result != null) await run(() => store.saveCategory(result));
  }

  Future<void> editBudget([BudgetRecord? value]) async {
    final choices = store.categoriesForKind('expense');
    if (value != null && !choices.any((c) => c.name == value.categoryName)) {
      choices.add(
        CategoryRecord(
          id: 'archive',
          colorName: 'indigo',
          name: value.categoryName,
          icon: value.categoryIcon,
          emoji: value.categoryEmoji,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
    final result = await editDialog<BudgetRecord>(
      context,
      BudgetEditor(existing: value, categories: choices, month: budgetMonth),
    );
    if (result != null) await run(() => store.saveBudget(result));
  }

  Future<void> adjust() async {
    final amount = TextEditingController(text: amountInput(store.balanceMinor));
    final note = TextEditingController();
    final form = GlobalKey<FormState>();
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(uiText('Скорректировать баланс')),
        content: SizedBox(
          width: 400,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  uiText(
                    'Укажите фактический остаток. Разница сохранится отдельной операцией и не повлияет на аналитику.',
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: uiText('Фактический баланс, {0}', [
                      store.baseCurrency,
                    ]),
                  ),
                  validator: (s) => parseAmount(s ?? '', signed: true) == null
                      ? uiText('Введите сумму')
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: note,
                  decoration: InputDecoration(labelText: uiText('Заметка')),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, parseAmount(amount.text, signed: true));
              }
            },
            child: Text(uiText('Сохранить')),
          ),
        ],
      ),
    );
    if (target != null) {
      await run(() => store.adjustBalance(target, note: note.text.trim()));
    }
    // Dialog route may still be animating; controllers are no longer attached after frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    amount.dispose();
    note.dispose();
  }

  /// ⌘ on Apple platforms, Ctrl elsewhere.
  bool get _apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  String get shortcutModifier => _apple ? '⌘' : 'Ctrl+';

  SingleActivator _key(LogicalKeyboardKey key) =>
      SingleActivator(key, control: !_apple, meta: _apple);

  /// Dialogs are separate routes, so these do not fire over an open editor;
  /// under the app lock the PIN pad holds focus and nothing here runs.
  Map<ShortcutActivator, VoidCallback> shortcuts() {
    void guarded(VoidCallback action) {
      if (!(widget.lock?.locked ?? false)) action();
    }

    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
    ];
    return {
      _key(LogicalKeyboardKey.keyN): () => guarded(editTransaction),
      _key(LogicalKeyboardKey.keyF): () => guarded(() {
        setState(() => page = 1);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => searchFocus.requestFocus(),
        );
      }),
      for (var i = 0; i < digits.length; i++)
        _key(digits[i]): () => guarded(() => setState(() => page = i)),
      _key(LogicalKeyboardKey.keyL): () =>
          guarded(() => widget.lock?.lockNow()),
    };
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return CallbackShortcuts(
      bindings: shortcuts(),
      child: Focus(autofocus: true, child: _scaffold(context)),
    );
  }

  Widget _scaffold(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.account_balance_wallet_outlined,
                color: Theme.of(context).colorScheme.onPrimary,
                size: 21,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              uiText('Баланс'),
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          if (store.syncing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: store.session == null
                  ? uiText('Настроить синхронизацию')
                  : uiText('Синхронизировать'),
              onPressed: store.session == null
                  ? () => setState(() => page = 4)
                  : () => run(store.sync),
              icon: Icon(
                store.session == null ? Icons.cloud_off_outlined : Icons.sync,
              ),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            LayoutBuilder(
              builder: (context, constraints) {
                final rail = NavigationRail(
                  selectedIndex: railPages.contains(page)
                      ? railPages.indexOf(page)
                      : null,
                  onDestinationSelected: (i) =>
                      setState(() => page = railPages[i]),
                  labelType: NavigationRailLabelType.all,
                  minWidth: 100,
                  leading: Padding(
                    padding: const EdgeInsets.only(bottom: 20, top: 16),
                    child: FloatingActionButton(
                      tooltip: uiText('Добавить операцию ({0}N)', [
                        shortcutModifier,
                      ]),
                      onPressed: editTransaction,
                      child: const Icon(Icons.add),
                    ),
                  ),
                  destinations: [
                    for (final i in railPages)
                      NavigationRailDestination(
                        icon: Icon(icons[i]),
                        label: Text(uiText(shortTitles[i])),
                      ),
                  ],
                );
                // Nine sections need about 760 px; a shorter window scrolls
                // the rail instead of clipping it.
                if (constraints.maxHeight >= 780) return rail;
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(child: rail),
                  ),
                );
              },
            ),
          if (wide) const VerticalDivider(width: 1),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    wide ? 36 : 16,
                    16,
                    wide ? 36 : 16,
                    100,
                  ),
                  children: [
                    Row(
                      children: [
                        if (!wide && page >= 4 && page <= 8)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: IconButton(
                              tooltip: uiText('Назад'),
                              onPressed: () => setState(() => page = 9),
                              icon: const Icon(Icons.arrow_back),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                uiText(titles[page]),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                page == 0
                                    ? localDateFormat(
                                        'LLLL y',
                                      ).format(DateTime.now())
                                    : page == 4 && store.activeLedger != null
                                    ? uiText('Пространство «{0}»', [
                                        store.activeLedger!.name,
                                      ])
                                    : uiText(subtitles[page]),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (wide && page == 0)
                          FilledButton.icon(
                            onPressed: editTransaction,
                            icon: const Icon(Icons.add),
                            label: Text(uiText('Новая операция')),
                          ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    if (store.error != null) ...[
                      MaterialBanner(
                        content: Text(uiSyncStatus(store.error!)),
                        leading: const Icon(Icons.cloud_off_outlined),
                        actions: [
                          TextButton(
                            onPressed: store.clearError,
                            child: Text(uiText('Закрыть')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    ...switch (page) {
                      0 => overview(),
                      1 => transactions(),
                      2 => analytics(),
                      3 => budgets(),
                      5 => [AccountsSection(store: store, run: run)],
                      6 => [RecurringSection(store: store, run: run)],
                      7 => [GoalsSection(store: store, run: run)],
                      8 => [DebtsSection(store: store, run: run)],
                      9 => [moreHub()],
                      _ => settings(),
                    },
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page < 4 ? page : 4,
              onDestinationSelected: (i) =>
                  setState(() => page = phonePages[i]),
              destinations: [
                for (final i in phonePages)
                  NavigationDestination(
                    icon: i == 9 && store.pendingReminders.isNotEmpty
                        ? Badge(
                            label: Text('${store.pendingReminders.length}'),
                            child: Icon(icons[i]),
                          )
                        : Icon(icons[i]),
                    label: uiText(shortTitles[i]),
                  ),
              ],
            ),
      floatingActionButton: !wide && (page == 0 || page == 1)
          ? FloatingActionButton.extended(
              onPressed: editTransaction,
              icon: const Icon(Icons.add),
              label: Text(uiText('Операция')),
            )
          : null,
    );
  }

  Widget moreHub() => MoreHub(
    onOpen: (p) => setState(() => page = p),
    entries: [
      MoreEntry(
        5,
        uiText(titles[5]),
        icons[5],
        store.accounts.isEmpty
            ? uiText('Наличные, карты, вклады и переводы')
            : uiText('Счетов: {0}', [store.activeAccounts.length]),
      ),
      MoreEntry(
        6,
        uiText(titles[6]),
        icons[6],
        store.pendingReminders.isNotEmpty
            ? uiText('Ожидают подтверждения: {0}', [
                store.pendingReminders.length,
              ])
            : store.recurring.isEmpty
            ? uiText('Подписки, аренда, зарплата')
            : uiText('Платежей: {0}', [store.recurring.length]),
      ),
      MoreEntry(
        7,
        uiText(titles[7]),
        icons[7],
        store.goals.isEmpty
            ? uiText('Копите на важное')
            : uiText('Целей: {0}', [
                store.goals.where((g) => !g.isArchived).length,
              ]),
      ),
      MoreEntry(
        8,
        uiText(titles[8]),
        icons[8],
        store.debts.isEmpty
            ? uiText('Кто кому должен')
            : uiText('Открытых: {0}', [
                store.debts.where((d) => !d.isClosed).length,
              ]),
      ),
      MoreEntry(4, uiText(titles[4]), icons[4], uiText(subtitles[4])),
    ],
  );

  Widget sectionTitle(String title, {Widget? action}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        ?action,
      ],
    ),
  );
  Widget metricRow(List<Widget> metrics) => LayoutBuilder(
    builder: (context, c) => c.maxWidth < 550
        ? Column(
            children: [
              for (final m in metrics)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SizedBox(width: double.infinity, child: m),
                ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < metrics.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Expanded(child: metrics[i]),
              ],
            ],
          ),
  );
  List<Widget> overview() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month);
    final end = DateTime(now.year, now.month + 1);
    final summary = FinanceMath.summary(base, start, end);
    return [
      MissingRatesNotice(pairs: store.missingRates, onAddRate: addRate),
      Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(uiText('Общий баланс'))),
                TextButton.icon(
                  onPressed: adjust,
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(uiText('Изменить')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                signedMoney(store.balanceMinor, store.baseCurrency),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              store.session == null
                  ? uiText('Данные хранятся на этом устройстве')
                  : '${store.email} · ${uiSyncStatus(store.syncMessage ?? 'Готово к синхронизации')}',
            ),
          ],
        ),
      ),
      quickEntry(),
      const SizedBox(height: 20),
      PendingRecurringPanel(store: store, run: run, limit: 3),
      if (store.activeAccounts.isNotEmpty) ...[
        accountsStrip(),
        const SizedBox(height: 20),
      ],
      metricRow([
        Metric(
          label: uiText('Доходы за месяц'),
          value: money(summary.incomeMinor, store.baseCurrency),
          icon: Icons.south_west,
          color: Colors.teal,
        ),
        Metric(
          label: uiText('Расходы за месяц'),
          value: money(summary.expensesMinor, store.baseCurrency),
          icon: Icons.north_east,
          color: Colors.deepOrange,
        ),
      ]),
      const SizedBox(height: 28),
      sectionTitle(uiText('Расходы по категориям')),
      spending(start, end, limit: 5),
      const SizedBox(height: 28),
      sectionTitle(
        uiText('Последние операции'),
        action: TextButton(
          onPressed: () => setState(() => page = 1),
          child: Text(uiText('Все операции')),
        ),
      ),
      if (store.transactions.isEmpty)
        EmptyView(
          title: uiText('Начните с первой операции'),
          subtitle: uiText(
            'Запишите доход или расход, чтобы увидеть свой баланс.',
          ),
          action: FilledButton.icon(
            onPressed: editTransaction,
            icon: const Icon(Icons.add),
            label: Text(uiText('Добавить')),
          ),
        )
      else
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: store.transactions.take(5).map(transactionTile).toList(),
          ),
        ),
    ];
  }

  /// Active accounts with their balances; opens «Счета».
  Widget accountsStrip() => Panel(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: Text(
            uiText('Счета'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          trailing: TextButton(
            onPressed: () => setState(() => page = 5),
            child: Text(uiText('Все счета')),
          ),
        ),
        for (final a in store.activeAccounts.take(4))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: CategoryAvatar(icon: a.icon, color: a.colorName, size: 32),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(
              signedMoney(
                store.accountBalances[a.id] ?? 0,
                store.accountCurrency(a.id),
              ),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onTap: () => setState(() => page = 5),
          ),
      ],
    ),
  );

  Widget transferTile(TransferRecord t) {
    final fromCurrency = store.accountCurrency(t.fromAccountId);
    final toCurrency = store.accountCurrency(t.toAccountId);
    final cross = fromCurrency != toCurrency;
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      leading: const CategoryAvatar(icon: 'swap', color: 'slate'),
      title: Text(uiText('Перевод')),
      subtitle: Text.rich(
        TextSpan(
          style: muted,
          children: [
            TextSpan(text: accountName(store, t.fromAccountId)),
            arrowSpan(context),
            TextSpan(
              text:
                  '${accountName(store, t.toAccountId)} · '
                  '${localDateFormat('d MMM, HH:mm').format(t.date.toLocal())}'
                  '${t.note.isEmpty ? '' : ' · ${t.note}'}',
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: money(t.amountMinor, fromCurrency)),
                  if (cross) ...[
                    arrowSpan(context),
                    TextSpan(text: money(t.toAmountMinor, toCurrency)),
                  ],
                ],
              ),
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: uiText('Действия с переводом'),
            onSelected: (v) async {
              if (v == 'edit') {
                await editTransfer(context, store, run, existing: t);
              } else if (await confirmDelete(
                context,
                uiText('Удалить перевод?'),
              )) {
                await run(() => store.deleteTransfer(t.id));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(uiText('Изменить'))),
              PopupMenuItem(value: 'delete', child: Text(uiText('Удалить'))),
            ],
          ),
        ],
      ),
      onTap: () => editTransfer(context, store, run, existing: t),
    );
  }

  Widget transactionTile(TransactionRecord t) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
    leading: CategoryAvatar(
      icon: t.isBalanceAdjustment ? 'tune' : t.categoryIcon,
      emoji: t.categoryEmoji,
      color: t.categoryColorName,
    ),
    title: Text(
      t.isBalanceAdjustment
          ? uiText('Корректировка баланса')
          : categoryTitle(t.categoryName),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      [
        localDateFormat('d MMM, HH:mm').format(t.date.toLocal()),
        if (t.accountId != null) accountName(store, t.accountId),
        if (t.note.isNotEmpty) t.note,
        if (t.tags.isNotEmpty) t.tags.map((tag) => '#$tag').join(' '),
        if (store.attachmentsFor(t.id).isNotEmpty)
          uiText('вложений: {0}', [store.attachmentsFor(t.id).length]),
      ].join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${t.kindRawValue == 'income' ? '+' : '−'}${money(t.amountMinor, store.transactionCurrency(t))}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: t.kindRawValue == 'income' ? Colors.teal : null,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: uiText('Действия с операцией'),
          onSelected: (v) async {
            if (v == 'receipt') {
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => SavedReceiptPage(
                    positions: PdfReceipt.positionsFromNote(t.note),
                  ),
                ),
              );
            } else if (v == 'edit') {
              await editTransaction(t);
            } else if (v == 'repeat') {
              await editTransaction(
                null,
                TransactionTemplate.fromTransaction('repeat', t),
              );
            } else if (v == 'template') {
              await run(
                () => store.saveTemplate(
                  TransactionTemplate.fromTransaction(AppStore.newId(), t),
                ),
                success: uiText('Шаблон сохранён в «Быстрый ввод»'),
              );
            } else if (await confirmDelete(
              context,
              uiText('Удалить операцию?'),
            )) {
              await run(() => store.deleteTransaction(t.id));
            }
          },
          itemBuilder: (_) => [
            if (PdfReceipt.positionsFromNote(t.note).isNotEmpty)
              PopupMenuItem(
                value: 'receipt',
                child: Text(uiText('Позиции чека')),
              ),
            PopupMenuItem(value: 'edit', child: Text(uiText('Изменить'))),
            // A balance adjustment is not spending to repeat or reuse.
            if (!t.isBalanceAdjustment) ...[
              PopupMenuItem(value: 'repeat', child: Text(uiText('Повторить'))),
              PopupMenuItem(
                value: 'template',
                child: Text(uiText('Сохранить как шаблон')),
              ),
            ],
            PopupMenuItem(value: 'delete', child: Text(uiText('Удалить'))),
          ],
        ),
      ],
    ),
    onTap: () => editTransaction(t),
  );
  Future<void> editListFilter() async {
    final result = await showModalBottomSheet<TransactionFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TransactionFilterSheet(
        filter: listFilter,
        categories: store.categories,
        currency: store.baseCurrency,
        tags: store.knownTags,
      ),
    );
    if (result != null) setState(() => listFilter = result);
  }

  List<Widget> transactions() {
    final f = listFilter;
    final items = f.apply(store.transactions, categoryAlias: categoryTitle);
    final transfers = f.applyTransfers(
      store.transfers,
      accountNames: (t) =>
          '${accountName(store, t.fromAccountId)} '
          '${accountName(store, t.toAccountId)}',
    );
    // Totals in the base currency; transfers are neither income nor expense.
    final totals = store.baseTotals(items);
    final filtered = f.activeCount > 0 || f.query.trim().isNotEmpty;
    final empty = store.transactions.isEmpty && store.transfers.isEmpty;
    return [
      TextField(
        controller: searchController,
        focusNode: searchFocus,
        decoration: InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: uiText('Поиск по категории, заметке или тегу'),
        ),
        onChanged: (s) => setState(() => listFilter = f.copyWith(query: s)),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final e in {
            'all': uiText('Все'),
            'expense': uiText('Расходы'),
            'income': uiText('Доходы'),
          }.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: f.kind == e.key,
              onSelected: (_) =>
                  setState(() => listFilter = f.copyWith(kind: e.key)),
            ),
          Badge(
            isLabelVisible: f.activeCount > 0,
            label: Text('${f.activeCount}'),
            child: OutlinedButton.icon(
              onPressed: editListFilter,
              icon: const Icon(Icons.filter_list),
              label: Text(uiText('Фильтры')),
            ),
          ),
          PopupMenuButton<TransactionSort>(
            tooltip: uiText('Сортировка'),
            initialValue: f.sort,
            onSelected: (v) => setState(() => listFilter = f.copyWith(sort: v)),
            itemBuilder: (_) => [
              for (final sort in TransactionSort.values)
                PopupMenuItem(value: sort, child: Text(uiText(sort.title))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort, size: 20),
                  const SizedBox(width: 6),
                  Text(uiText(f.sort.title)),
                ],
              ),
            ),
          ),
        ],
      ),
      if (f.activeCount > 0) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (f.hasPeriod)
              InputChip(
                avatar: const Icon(Icons.date_range, size: 18),
                label: Text(periodTitle(f)),
                onPressed: editListFilter,
                onDeleted: () => setState(() => listFilter = f.withoutPeriod()),
              ),
            if (f.hasAmount)
              InputChip(
                avatar: const Icon(Icons.payments_outlined, size: 18),
                label: Text(amountTitle(f, store.baseCurrency)),
                onPressed: editListFilter,
                onDeleted: () => setState(() => listFilter = f.withoutAmount()),
              ),
            if (f.categories.isNotEmpty)
              InputChip(
                avatar: const Icon(Icons.category_outlined, size: 18),
                label: Text(
                  f.categories.length == 1
                      ? f.categories.single
                      : uiText('Категорий: {0}', [f.categories.length]),
                ),
                onPressed: editListFilter,
                onDeleted: () =>
                    setState(() => listFilter = f.copyWith(categories: {})),
              ),
            if (f.tags.isNotEmpty)
              InputChip(
                avatar: const Icon(Icons.sell_outlined, size: 18),
                label: Text(
                  f.tags.length == 1
                      ? '#${f.tags.single}'
                      : uiText('Тегов: {0}', [f.tags.length]),
                ),
                onPressed: editListFilter,
                onDeleted: () =>
                    setState(() => listFilter = f.copyWith(tags: {})),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      if (filtered && (items.isNotEmpty || transfers.isNotEmpty))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            uiText('Найдено: {0} · расходы {1} · доходы {2}', [
              items.length + transfers.length,
              money(totals.expensesMinor, store.baseCurrency),
              money(totals.incomeMinor, store.baseCurrency),
            ]),
          ),
        ),
      if (items.isEmpty && transfers.isEmpty)
        EmptyView(
          title: empty
              ? uiText('Операций пока нет')
              : uiText('Ничего не найдено'),
          subtitle: empty
              ? uiText('Добавьте операцию, чтобы она появилась здесь.')
              : uiText('Измените поиск или фильтры.'),
          action: filtered
              ? TextButton(
                  onPressed: () => setState(() {
                    // The search box must not keep text the list ignores.
                    searchController.clear();
                    listFilter = TransactionFilter(kind: f.kind, sort: f.sort);
                  }),
                  child: Text(uiText('Сбросить фильтры')),
                )
              : null,
        )
      // One lightweight widget per day or slice: the page ListView builds
      // only those on screen, so tens of thousands of operations stay cheap.
      else if (f.sort.byDate)
        for (final day in DayGroup.group(
          items,
          transfers: transfers,
          oldestFirst: f.sort == TransactionSort.oldest,
        ))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DayPanel(
              group: day,
              tile: transactionTile,
              transferTile: transferTile,
              totals: store.baseTotals(day.items),
              currency: store.baseCurrency,
              oldestFirst: f.sort == TransactionSort.oldest,
            ),
          )
      else
        for (var i = 0; i < items.length; i += 50)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: PlainPanel(
              items: items.sublist(
                i,
                i + 50 < items.length ? i + 50 : items.length,
              ),
              tile: transactionTile,
            ),
          ),
    ];
  }

  Widget spending(
    DateTime start,
    DateTime end, {
    int? limit,
    void Function(String name)? onCategory,
  }) {
    var groups = FinanceMath.spending(base, start, end);
    if (limit != null) groups = groups.take(limit).toList();
    final total = FinanceMath.summary(base, start, end).expensesMinor;
    if (groups.isEmpty) {
      return EmptyView(
        title: uiText('Расходов за период нет'),
        subtitle: uiText('Здесь появится структура ваших расходов.'),
        icon: Icons.donut_large,
      );
    }
    return Panel(
      child: Column(
        children: [
          for (final g in groups)
            InkWell(
              onTap: onCategory == null ? null : () => onCategory(g.name),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    CategoryAvatar(
                      icon: g.icon,
                      emoji: g.emoji,
                      color: g.colorName,
                      size: 36,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  categoryTitle(g.name),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                money(g.amountMinor, store.baseCurrency),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: total == 0 ? 0 : g.amountMinor / total,
                            borderRadius: BorderRadius.circular(8),
                            minHeight: 5,
                            color: categoryColors[g.colorName],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            uiText('{0}% расходов', [
                              total == 0
                                  ? 0
                                  : (g.amountMinor / total * 100).round(),
                            ]),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  AnalyticsPeriod analyticsPeriod(DateTime now) => switch (analyticsMode) {
    'year' => AnalyticsPeriod.year(reportYear),
    'custom' => customPeriod ?? AnalyticsPeriod.months(1, now),
    _ => AnalyticsPeriod.months(int.parse(analyticsMode), now),
  };

  String rangeTitle(DateTime start, DateTime endExclusive) {
    final last = DateTime(
      endExclusive.year,
      endExclusive.month,
      endExclusive.day - 1,
    );
    final format = localDateFormat('d MMM y');
    return DateUtils.isSameDay(start, last)
        ? format.format(start)
        : '${format.format(start)} – ${format.format(last)}';
  }

  Future<void> pickAnalyticsRange() async {
    final now = DateTime.now();
    final current = customPeriod;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5),
      initialDateRange: current == null
          ? null
          : DateTimeRange(
              start: current.start,
              end: DateTime(
                current.endExclusive.year,
                current.endExclusive.month,
                current.endExclusive.day - 1,
              ),
            ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      customPeriod = AnalyticsPeriod.custom(
        picked.start,
        DateTime(picked.end.year, picked.end.month, picked.end.day + 1),
      );
      analyticsMode = 'custom';
    });
  }

  List<Widget> analytics() {
    final now = DateTime.now();
    final period = analyticsPeriod(now);
    final start = period.start;
    final end = period.endExclusive;
    final sum = FinanceMath.summary(base, start, end);
    final grouped = FinanceMath.spending(base, start, end);
    final saving = sum.incomeMinor > 0
        ? sum.balanceMinor / sum.incomeMinor * 100
        : 0.0;
    final days = period.elapsedDays(now).clamp(1, 1000000);
    return [
      MissingRatesNotice(pairs: store.missingRates, onAddRate: addRate),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in {
            '1': uiText('Месяц'),
            '3': uiText('3 месяца'),
            '12': uiText('12 месяцев'),
            'year': uiText('Год'),
          }.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: analyticsMode == e.key,
              onSelected: (_) => setState(() => analyticsMode = e.key),
            ),
          ChoiceChip(
            avatar: const Icon(Icons.date_range, size: 18),
            label: Text(uiText('Период')),
            selected: analyticsMode == 'custom',
            onSelected: (_) => customPeriod == null
                ? pickAnalyticsRange()
                : setState(() => analyticsMode = 'custom'),
          ),
        ],
      ),
      if (analyticsMode == 'year') ...[
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: uiText('Предыдущий год'),
              onPressed: () => setState(() => reportYear--),
              icon: const Icon(Icons.chevron_left),
            ),
            Text('$reportYear', style: Theme.of(context).textTheme.titleMedium),
            IconButton(
              tooltip: uiText('Следующий год'),
              onPressed: reportYear >= now.year
                  ? null
                  : () => setState(() => reportYear++),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
      if (analyticsMode == 'custom') ...[
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: InputChip(
            avatar: const Icon(Icons.edit_calendar_outlined, size: 18),
            label: Text(rangeTitle(start, end)),
            tooltip: uiText('Изменить период'),
            onPressed: pickAnalyticsRange,
          ),
        ),
      ],
      const SizedBox(height: 20),
      metricRow([
        Metric(
          label: uiText('Доходы'),
          value: money(sum.incomeMinor, store.baseCurrency),
          icon: Icons.south_west,
          color: Colors.teal,
        ),
        Metric(
          label: uiText('Расходы'),
          value: money(sum.expensesMinor, store.baseCurrency),
          icon: Icons.north_east,
          color: Colors.deepOrange,
        ),
      ]),
      const SizedBox(height: 16),
      metricRow([
        Metric(
          label: uiText('Сбережения'),
          value: '${saving.toStringAsFixed(1)}%',
          icon: Icons.savings_outlined,
        ),
        Metric(
          label: uiText('Средний расход в день'),
          value: money((sum.expensesMinor / days).round(), store.baseCurrency),
          icon: Icons.calendar_today_outlined,
        ),
      ]),
      const SizedBox(height: 16),
      metricRow([
        Metric(
          label: uiText('Результат периода'),
          value: money(sum.balanceMinor, store.baseCurrency),
          icon: Icons.account_balance_wallet_outlined,
        ),
        Metric(
          label: uiText('Крупнейшая категория'),
          value: grouped.isEmpty ? '—' : categoryTitle(grouped.first.name),
          icon: Icons.category_outlined,
        ),
      ]),
      const SizedBox(height: 28),
      sectionTitle(uiText('Сравнение с прошлым периодом')),
      comparison(PeriodComparison.of(base, period, now)),
      if (analyticsMode == '1') ...[
        const SizedBox(height: 28),
        sectionTitle(uiText('Прогноз до конца месяца')),
        forecast(now),
      ],
      if (analyticsMode == 'year') ...[
        const SizedBox(height: 28),
        sectionTitle(uiText('Итоги года')),
        yearReport(YearReport.of(base, reportYear, now)),
      ],
      const SizedBox(height: 28),
      sectionTitle(uiText('Динамика доходов и расходов')),
      trend(start, end),
      const SizedBox(height: 28),
      sectionTitle(uiText('Структура расходов')),
      if (grouped.isNotEmpty) ...[
        Panel(
          child: SpendingRing(
            segments: grouped
                .map(
                  (g) => (
                    g.amountMinor,
                    categoryColors[g.colorName] ??
                        Theme.of(context).colorScheme.primary,
                  ),
                )
                .toList(),
            total: money(sum.expensesMinor, store.baseCurrency),
          ),
        ),
        const SizedBox(height: 16),
      ],
      spending(
        start,
        end,
        onCategory: (name) => setState(() => trendCategory = name),
      ),
      const SizedBox(height: 28),
      sectionTitle(uiText('Динамика категории')),
      categoryTrend(period, grouped),
    ];
  }

  Widget comparison(PeriodComparison c) {
    final format = localDateFormat('d MMM');
    String range(DateTime s, DateTime e) {
      final last = DateTime(e.year, e.month, e.day - 1);
      return DateUtils.isSameDay(s, last)
          ? format.format(s)
          : '${format.format(s)} – ${format.format(last)}';
    }

    Widget line(int? change, String text, Color color) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(
            change == null || change == 0
                ? Icons.trending_flat
                : change > 0
                ? Icons.trending_up
                : Icons.trending_down,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(c.expensesChange, c.expensesText, Colors.deepOrange),
          line(c.incomeChange, c.incomeText, Colors.teal),
          Text(
            uiText('{0}{1} и {2}', [
              c.partial
                  ? uiText('Пока период идёт, сравниваются одинаковые сроки: ')
                  : '',
              range(c.currentStart, c.currentEnd),
              range(c.previousStart, c.previousEnd),
            ]),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget forecast(DateTime now) {
    final f = MonthForecast.of(base, now);
    final budget = BudgetForecast.total(store.budgets, base, now);
    final day = budget?.exhaustionDay;
    final danger = budget != null && (budget.exceeded || day != null);
    return Column(
      children: [
        metricRow([
          Metric(
            label: uiText('Ожидаемые расходы за месяц'),
            value: money(f.projectedMinor, store.baseCurrency),
            icon: Icons.query_stats,
            color: Colors.deepOrange,
          ),
          Metric(
            label: uiText('Темп трат в день'),
            value: money(f.dailyPaceMinor, store.baseCurrency),
            icon: Icons.speed,
          ),
        ]),
        if (budget != null) ...[
          const SizedBox(height: 16),
          Panel(
            child: Row(
              children: [
                Icon(
                  danger ? Icons.warning_amber_rounded : Icons.check_circle,
                  color: danger
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    uiText('{0}. Потрачено {1} из {2}.', [
                      budget.exceeded
                          ? uiText('Бюджеты месяца уже исчерпаны')
                          : day != null
                          ? uiText(
                              'При текущем темпе бюджет закончится {0}-го',
                              [day],
                            )
                          : uiText(
                              'При текущем темпе бюджета хватит до конца месяца',
                            ),
                      money(budget.usedMinor, store.baseCurrency),
                      money(budget.limitMinor, store.baseCurrency),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget yearReport(YearReport r) {
    String month(MonthlyTotal? m) => m == null
        ? '—'
        : toBeginningOfSentenceCase(localDateFormat('LLLL').format(m.month));
    return Column(
      children: [
        metricRow([
          Metric(
            label: uiText('Расходы в среднем за месяц'),
            value: money(r.averageMonthlyExpensesMinor, store.baseCurrency),
            icon: Icons.north_east,
            color: Colors.deepOrange,
          ),
          Metric(
            label: uiText('Доходы в среднем за месяц'),
            value: money(r.averageMonthlyIncomeMinor, store.baseCurrency),
            icon: Icons.south_west,
            color: Colors.teal,
          ),
        ]),
        const SizedBox(height: 16),
        metricRow([
          Metric(
            label: uiText('Самый затратный месяц'),
            value: month(r.topExpenseMonth),
            icon: Icons.local_fire_department_outlined,
          ),
          Metric(
            label: uiText('Самый доходный месяц'),
            value: month(r.topIncomeMonth),
            icon: Icons.emoji_events_outlined,
          ),
        ]),
      ],
    );
  }

  Widget categoryTrend(
    AnalyticsPeriod period,
    List<CategorySpending> inPeriod,
  ) {
    final through = DateTime(
      period.endExclusive.year,
      period.endExclusive.month,
      period.endExclusive.day - 1,
    );
    final first = DateTime(through.year, through.month - 11);
    final names = [
      for (final g in inPeriod) g.name,
      for (final g in FinanceMath.spending(
        base,
        first,
        DateTime(through.year, through.month + 1),
      ))
        if (!inPeriod.any((p) => p.name == g.name)) g.name,
    ];
    if (names.isEmpty) {
      return EmptyView(
        title: uiText('Расходов пока нет'),
        subtitle: uiText(
          'Здесь появится динамика трат по выбранной категории.',
        ),
        icon: Icons.show_chart,
      );
    }
    final name = names.contains(trendCategory) ? trendCategory! : names.first;
    final series = Analytics.categoryTrend(base, name, through);
    final total = series.fold(0, (s, m) => s + m.amountMinor);
    final active = series.where((m) => m.amountMinor > 0).length;
    var max = 1;
    for (final m in series) {
      if (m.amountMinor > max) max = m.amountMinor;
    }
    final color =
        categoryColors[base
            .firstWhere((t) => t.categoryName == name)
            .categoryColorName] ??
        Theme.of(context).colorScheme.primary;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('trend-$name'),
            initialValue: name,
            isExpanded: true,
            decoration: InputDecoration(labelText: uiText('Категория')),
            items: [
              for (final n in names)
                DropdownMenuItem(
                  value: n,
                  child: Text(n, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => trendCategory = v),
          ),
          const SizedBox(height: 16),
          Text(
            uiText('За 12 месяцев: {0} · в среднем {1} в месяц с тратами', [
              money(total, store.baseCurrency),
              money(
                active == 0 ? 0 : (total / active).round(),
                store.baseCurrency,
              ),
            ]),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 170,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < series.length; i++)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${toBeginningOfSentenceCase(localDateFormat('LLLL y').format(series[i].month))}\n${money(series[i].amountMinor, store.baseCurrency)}',
                      child: Semantics(
                        label:
                            '${localDateFormat('LLLL y').format(series[i].month)}, ${money(series[i].amountMinor, store.baseCurrency)}',
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Container(
                                height: (series[i].amountMinor / max * 130)
                                    .clamp(2, 130)
                                    .toDouble(),
                                decoration: BoxDecoration(
                                  color: series[i].amountMinor == 0
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest
                                      : color,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 24,
                              child: i.isEven
                                  ? Text(
                                      localDateFormat(
                                        'MMM',
                                      ).format(series[i].month),
                                      style: const TextStyle(fontSize: 10),
                                      maxLines: 1,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget trend(DateTime start, DateTime end) {
    final buckets = TrendBucket.of(start, end);
    final last = DateTime(end.year, end.month, end.day - 1);
    final dayFormat = start.month == last.month && start.year == last.year
        ? localDateFormat('d')
        : localDateFormat('d.MM');
    final monthFormat = start.year == last.year
        ? localDateFormat('MMM')
        : DateFormat('MM.yy');
    String label(TrendBucket b) => switch (b.size) {
      BucketSize.day => dayFormat.format(b.start),
      BucketSize.week => localDateFormat('d.MM').format(b.start),
      BucketSize.month => monthFormat.format(b.start),
    };
    String title(TrendBucket b) => switch (b.size) {
      BucketSize.day => localDateFormat('d MMM y').format(b.start),
      BucketSize.week => rangeTitle(b.start, b.endExclusive),
      BucketSize.month => toBeginningOfSentenceCase(
        localDateFormat('LLLL y').format(b.start),
      ),
    };
    final summaries = buckets
        .map((b) => FinanceMath.summary(base, b.start, b.endExclusive))
        .toList();
    var max = 1;
    for (final s in summaries) {
      if (s.incomeMinor > max) max = s.incomeMinor;
      if (s.expensesMinor > max) max = s.expensesMinor;
    }
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 20,
            children: [
              Text(uiText('● Доходы'), style: TextStyle(color: Colors.teal)),
              Text(
                uiText('● Расходы'),
                style: TextStyle(color: Colors.deepOrange),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 210,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < buckets.length; i++)
                  Expanded(
                    child: Tooltip(
                      message: uiText('{0}\nДоходы: {1}\nРасходы: {2}', [
                        title(buckets[i]),
                        money(summaries[i].incomeMinor, store.baseCurrency),
                        money(summaries[i].expensesMinor, store.baseCurrency),
                      ]),
                      child: Semantics(
                        label: uiText('{0}, доходы {1}, расходы {2}', [
                          title(buckets[i]),
                          money(summaries[i].incomeMinor, store.baseCurrency),
                          money(summaries[i].expensesMinor, store.baseCurrency),
                        ]),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Spacer(),
                                  Expanded(
                                    flex: 3,
                                    child: Container(
                                      height:
                                          (summaries[i].incomeMinor / max * 174)
                                              .clamp(2, 174)
                                              .toDouble(),
                                      decoration: BoxDecoration(
                                        color: Colors.teal,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Expanded(
                                    flex: 3,
                                    child: Container(
                                      height:
                                          (summaries[i].expensesMinor /
                                                  max *
                                                  174)
                                              .clamp(2, 174)
                                              .toDouble(),
                                      decoration: BoxDecoration(
                                        color: Colors.deepOrange,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 24,
                              child: i % ((buckets.length / 8).ceil()) == 0
                                  ? Text(
                                      label(buckets[i]),
                                      style: const TextStyle(fontSize: 10),
                                      maxLines: 1,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> budgets() {
    final entries = store.budgets
        .where(
          (b) =>
              b.monthStart.toLocal().year == budgetMonth.year &&
              b.monthStart.toLocal().month == budgetMonth.month,
        )
        .toList();
    return [
      MissingRatesNotice(pairs: store.missingRates, onAddRate: addRate),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: uiText('Предыдущий месяц'),
                onPressed: () => setState(
                  () => budgetMonth = DateTime(
                    budgetMonth.year,
                    budgetMonth.month - 1,
                  ),
                ),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(localDateFormat('LLLL y').format(budgetMonth)),
              IconButton(
                tooltip: uiText('Следующий месяц'),
                onPressed: () => setState(
                  () => budgetMonth = DateTime(
                    budgetMonth.year,
                    budgetMonth.month + 1,
                  ),
                ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: editBudget,
            icon: const Icon(Icons.add),
            label: Text(uiText('Добавить лимит')),
          ),
        ],
      ),
      const SizedBox(height: 24),
      if (entries.isEmpty)
        EmptyView(
          title: uiText('Бюджет ещё не запланирован'),
          subtitle: uiText('Задайте месячные лимиты для категорий расходов.'),
          icon: Icons.savings_outlined,
        ),
      for (final b in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: budgetCard(b),
        ),
    ];
  }

  Widget budgetCard(BudgetRecord b) {
    final used = FinanceMath.budgetUsed(b, base);
    final runsOut = BudgetForecast.of(b, base, DateTime.now())?.exhaustionDay;
    final ratio = b.limitMinor > 0 ? used / b.limitMinor : 0.0;
    final color = b.limitMinor <= 0 || ratio >= 1
        ? Theme.of(context).colorScheme.error
        : ratio >= .8
        ? Colors.orange
        : Theme.of(context).colorScheme.primary;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CategoryAvatar(icon: b.categoryIcon, emoji: b.categoryEmoji),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  categoryTitle(b.categoryName),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: uiText('Изменить лимит'),
                onPressed: () => editBudget(b),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: uiText('Удалить лимит'),
                onPressed: () async {
                  if (await confirmDelete(context, uiText('Удалить лимит?'))) {
                    await run(() => store.deleteBudget(b.id));
                  }
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 6,
            children: [
              Text(
                money(used, store.baseCurrency),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              Text(uiText('из {0}', [money(b.limitMinor, store.baseCurrency)])),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: ratio.clamp(0, 1),
            color: color,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 12),
          Text(
            b.limitMinor <= 0
                ? uiText('Некорректный лимит. Измените бюджет.')
                : used > b.limitMinor
                ? uiText('Превышение: {0}', [
                    money(used - b.limitMinor, store.baseCurrency),
                  ])
                : uiText('Осталось: {0}', [
                    money(b.limitMinor - used, store.baseCurrency),
                  ]),
            style: TextStyle(color: color),
          ),
          if (runsOut != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: Colors.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    uiText('При текущем темпе лимит закончится {0}-го', [
                      runsOut,
                    ]),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> settings() => [
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(uiText('Оформление')),
          DropdownButtonFormField<String>(
            key: ValueKey('app-language-${store.appLanguage}'),
            initialValue: store.appLanguage,
            decoration: InputDecoration(labelText: uiText('Язык приложения')),
            items: [
              DropdownMenuItem(
                value: 'system',
                child: Text(uiText('Как в системе')),
              ),
              const DropdownMenuItem(value: 'ru', child: Text('Русский')),
              const DropdownMenuItem(value: 'en', child: Text('English')),
            ],
            onChanged: (value) {
              if (value != null) run(() => store.setAppLanguage(value));
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('theme-mode-${store.theme}'),
            initialValue: store.theme,
            decoration: InputDecoration(labelText: uiText('Тема')),
            items: [
              DropdownMenuItem(
                value: 'system',
                child: Text(uiText('Системная')),
              ),
              DropdownMenuItem(value: 'light', child: Text(uiText('Светлая'))),
              DropdownMenuItem(value: 'dark', child: Text(uiText('Тёмная'))),
            ],
            onChanged: (v) {
              if (v != null) run(() => store.setTheme(v));
            },
          ),
          const SizedBox(height: 20),
          Text(
            uiText('Цветовой пресет'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ColorPreset.values
                .map(
                  (preset) => ChoiceChip(
                    label: Text(uiText(preset.label)),
                    avatar: CircleAvatar(
                      radius: 9,
                      backgroundColor: preset == ColorPreset.oled
                          ? Colors.black
                          : Color(preset.seedArgb),
                      child: preset == ColorPreset.oled
                          ? const Icon(
                              Icons.nightlight_round,
                              size: 13,
                              color: Colors.white,
                            )
                          : null,
                    ),
                    selected: store.themePreset == preset.id,
                    onSelected: (_) =>
                        run(() => store.setThemePreset(preset.id)),
                  ),
                )
                .toList(),
          ),
          if (store.themePreset == 'oled') ...[
            const SizedBox(height: 12),
            Text(
              uiText(
                'OLED: чистый чёрный фон #000000 в тёмном режиме. При выборе пресета тёмная тема включается автоматически. Можно затем выбрать системный режим.',
              ),
            ),
          ],
        ],
      ),
    ),
    const SizedBox(height: 20),
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(uiText('Валюты и курсы')),
          CurrencySettingsPanel(store: store, run: run),
        ],
      ),
    ),
    const SizedBox(height: 20),
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(uiText('Сервер и синхронизация')),
          Text(
            store.serverUrl.isEmpty
                ? uiText('Сервер не подключён')
                : store.serverUrl,
          ),
          const SizedBox(height: 12),
          Text(
            store.session == null
                ? uiText(
                    'Можно работать локально или подключить свой BalanceServer.',
                  )
                : store.email,
          ),
          if (store.lastSyncAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                uiText('Последняя синхронизация: {0}', [
                  localDateFormat('d.MM.y HH:mm').format(store.lastSyncAt!),
                ]),
              ),
            ),
          if (store.syncMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(uiSyncStatus(store.syncMessage!)),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: serverDialog,
                icon: const Icon(Icons.dns_outlined),
                label: Text(uiText('Адрес сервера')),
              ),
              if (store.session == null) ...[
                FilledButton(
                  onPressed: store.serverUrl.isEmpty
                      ? null
                      : () => authDialog(false),
                  child: Text(uiText('Войти')),
                ),
                TextButton(
                  onPressed: store.serverUrl.isEmpty
                      ? null
                      : () => authDialog(true),
                  child: Text(uiText('Регистрация')),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: store.syncing ? null : () => run(store.sync),
                  icon: const Icon(Icons.sync),
                  label: Text(uiText('Синхронизировать')),
                ),
                OutlinedButton(
                  onPressed: store.syncing
                      ? null
                      : () => run(store.resetAndSync),
                  child: Text(uiText('Полная синхронизация')),
                ),
                TextButton(
                  onPressed: store.syncing ? null : () => run(store.signOut),
                  child: Text(uiText('Выйти')),
                ),
              ],
            ],
          ),
          if (kIsWeb)
            Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                uiText(
                  'Web: используйте HTTPS и разрешите адрес приложения в CORS-настройках сервера.',
                ),
              ),
            ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    if (store.session != null && store.supportsLedgers) ...[
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle(uiText('Общие пространства')),
            LedgersPanel(store: store, run: run),
          ],
        ),
      ),
      const SizedBox(height: 20),
    ],
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(
            uiText('Категории'),
            action: FilledButton.tonalIcon(
              onPressed: editCategory,
              icon: const Icon(Icons.add),
              label: Text(uiText('Добавить')),
            ),
          ),
          if (store.categories.isEmpty)
            Text(uiText('Создайте свои категории или используйте встроенные.')),
          for (final c in store.categories)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CategoryAvatar(
                icon: c.icon,
                emoji: c.emoji,
                color: c.colorName,
              ),
              title: Text(categoryTitle(c.name)),
              subtitle: Text(
                c.kindRawValue == 'income' ? uiText('Доход') : uiText('Расход'),
              ),
              onTap: () => editCategory(c),
              trailing: IconButton(
                tooltip: uiText('Удалить категорию'),
                onPressed: () async {
                  if (await confirmDelete(
                    context,
                    uiText('Удалить «{0}»?', [c.name]),
                    message: uiText(
                      'Операции сохранят категорию. Связанные бюджеты будут удалены.',
                    ),
                  )) {
                    await run(() => store.deleteCategory(c.id));
                  }
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(uiText('Встроенные категории')),
            children: [
              for (final c in [
                ...BuiltInCategories.expense,
                ...BuiltInCategories.income,
              ])
                ListTile(
                  leading: CategoryAvatar(
                    icon: c.icon,
                    emoji: c.emoji,
                    color: c.colorName,
                    size: 32,
                  ),
                  title: Text(categoryTitle(c.name)),
                  subtitle: Text(
                    c.kindRawValue == 'income'
                        ? uiText('Доход')
                        : uiText('Расход'),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS) ...[
      const SizedBox(height: 20),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle(uiText('Горячие клавиши')),
            for (final (keys, action) in [
              ('${shortcutModifier}N', uiText('Новая операция')),
              ('${shortcutModifier}F', uiText('Поиск операций')),
              (
                '${shortcutModifier}1 … ${shortcutModifier}5',
                uiText('Разделы'),
              ),
              if (widget.lock?.enabled ?? false)
                ('${shortcutModifier}L', uiText('Заблокировать')),
              ('Esc', uiText('Закрыть окно или отменить')),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        keys,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(child: Text(action)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
    if (widget.notifications != null) ...[
      const SizedBox(height: 20),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle(uiText('Уведомления')),
            NotificationsPanel(
              notifications: widget.notifications!,
              store: store,
              run: run,
            ),
          ],
        ),
      ),
    ],
    if (widget.lock != null) ...[
      const SizedBox(height: 20),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle(uiText('Приватность')),
            PrivacyPanel(lock: widget.lock!, run: run),
          ],
        ),
      ),
    ],
    const SizedBox(height: 20),
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(uiText('Данные')),
          if (store.quarantine.isNotEmpty) ...[
            QuarantinePanel(
              entries: store.quarantine,
              onSave: saveQuarantine,
              onClear: clearQuarantine,
            ),
            const SizedBox(height: 16),
          ],
          Text(
            uiText(
              'Резервная копия хранит все записи открытого пространства без потерь: операции, категории, бюджеты, счета, переводы, цели, долги и курсы. Восстановление добавляет записи из копии и не затирает более новые изменения.',
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: backup,
                icon: const Icon(Icons.backup_outlined),
                label: Text(uiText('Резервная копия')),
              ),
              OutlinedButton.icon(
                onPressed: restore,
                icon: const Icon(Icons.settings_backup_restore),
                label: Text(uiText('Восстановить из копии')),
              ),
              OutlinedButton.icon(
                onPressed: importStatement,
                icon: const Icon(Icons.account_balance_outlined),
                label: Text(uiText('Импорт выписки банка')),
              ),
              OutlinedButton.icon(
                onPressed: export,
                icon: const Icon(Icons.download_outlined),
                label: Text(uiText('Экспорт истории CSV')),
              ),
              TextButton(
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: uiText('Баланс'),
                  applicationVersion: '4.4.0',
                  applicationIcon: const Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 40,
                  ),
                  children: [
                    Text(
                      uiText(
                        'Личный бюджет · Flutter · Material 3\nСинхронизация с BalanceServer',
                      ),
                    ),
                  ],
                ),
                child: Text(uiText('О приложении')),
              ),
            ],
          ),
        ],
      ),
    ),
  ];
  Future<void> serverDialog() async {
    final controller = TextEditingController(text: store.serverUrl);
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(uiText('Адрес сервера')),
        content: SizedBox(
          width: 460,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  uiText(
                    'При смене сервера потребуется новый вход. Данные аккаунтов хранятся раздельно.',
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: controller,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'https://balance.example.com',
                  ),
                  validator: (s) {
                    final uri = Uri.tryParse((s ?? '').trim());
                    if (uri == null ||
                        !uri.hasAuthority ||
                        !['https', 'http'].contains(uri.scheme)) {
                      return uiText('Введите полный адрес сервера');
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, controller.text);
              }
            },
            child: Text(uiText('Сохранить')),
          ),
        ],
      ),
    );
    if (result != null) {
      await run(
        () => store.setServerUrl(result),
        success: uiText('Адрес сервера сохранён'),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Future<void> authDialog(bool register) async {
    final email = TextEditingController();
    final password = TextEditingController();
    final form = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          register ? uiText('Создать аккаунт') : uiText('Войти в аккаунт'),
        ),
        content: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: InputDecoration(
                    labelText: uiText('Электронная почта'),
                  ),
                  validator: (s) =>
                      (s ?? '').contains('@') ? null : uiText('Введите email'),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: password,
                  obscureText: true,
                  autofillHints: [
                    register
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  decoration: InputDecoration(labelText: uiText('Пароль')),
                  validator: (s) => (s ?? '').isEmpty
                      ? uiText('Введите пароль')
                      : register && s!.length < 8
                      ? uiText('Не менее 8 символов')
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  uiText(
                    'При первом подключении нового аккаунта локальные записи переносятся в него. Аккаунты хранятся раздельно.',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: Text(
              register ? uiText('Зарегистрироваться') : uiText('Войти'),
            ),
          ),
        ],
      ),
    );
    if (result == true) {
      await run(
        () => register
            ? store.register(email.text.trim(), password.text)
            : store.signIn(email.text.trim(), password.text),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    email.dispose();
    password.dispose();
  }

  Future<void> export() => run(
    () => saveFile(
      context,
      Uint8List.fromList(
        utf8.encode(FinanceMath.exportCsv(store.transactions)),
      ),
      name: 'balance-transactions.csv',
      mimeType: 'text/csv',
      label: 'CSV',
      extension: 'csv',
    ),
  );

  Future<void> backup() => run(() async {
    final data = await store.exportBackup();
    if (!mounted) return;
    final day = DateFormat('yyyy-MM-dd').format(DateTime.now());
    await saveFile(
      context,
      Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent(' ').convert(data)),
      ),
      name: 'balance-backup-$day.json',
      mimeType: 'application/json',
      label: 'JSON',
      extension: 'json',
    );
  });

  Future<void> restore() async {
    final file = await pickFile(uiText('Резервная копия'), ['json']);
    if (file == null || !mounted) return;
    await run(() async {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(await file.readAsBytes()));
      } on FormatException {
        throw FormatException(uiText('Файл повреждён или это не JSON'));
      }
      final plan = await store.previewBackup(decoded);
      if (plan.items.isEmpty) {
        throw FormatException(
          plan.invalid > 0
              ? uiText('В копии нет читаемых записей')
              : uiText(
                  'Восстанавливать нечего: копия пуста или содержит только удаления',
                ),
        );
      }
      if (!mounted) return;
      final keys = await showBackupPreview(
        context,
        plan: plan,
        fileName: file.name,
        currency: store.baseCurrency,
      );
      if (keys == null) return;
      final result = await store.restoreBackup(decoded, only: keys);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.describe())));
      }
    });
  }

  Future<void> importStatement() async {
    final file = await pickFile(
      uiText('Выписка'),
      ['csv', 'txt', 'ofx', 'qfx'],
      androidMimeTypes: const [
        'application/x-ofx',
        'application/vnd.intu.qfx',
        'application/octet-stream',
      ],
    );
    if (file == null || !mounted) return;
    await run(() async {
      final records = await runStatementImport(context, store, file);
      if (records == null) return;
      final added = await store.importTransactions(records);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(uiText('Импортировано операций: {0}', [added])),
          ),
        );
      }
    });
  }

  Future<void> saveQuarantine() => run(
    () => saveFile(
      context,
      Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent(' ').convert(store.quarantineReport()),
        ),
      ),
      name: 'balance-damaged-records.json',
      mimeType: 'application/json',
      label: 'JSON',
      extension: 'json',
    ),
  );

  Future<void> clearQuarantine() async {
    if (await confirmDelete(
      context,
      uiText('Очистить отложенные записи?'),
      message: uiText(
        'Копии повреждённых записей будут удалены с устройства. Сначала сохраните отчёт, если они нужны.',
      ),
      action: uiText('Очистить'),
    )) {
      await run(store.clearQuarantine);
    }
  }
}
