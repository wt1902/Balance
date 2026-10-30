import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:quick_actions/quick_actions.dart';
import '../domain/finance.dart';
import '../domain/appearance.dart';
import '../domain/templates.dart';
import 'app_theme.dart';
import 'data_tools.dart';
import '../services/app_lock.dart';
import '../services/app_store.dart';
import '../services/launch_actions.dart';
import 'design.dart';
import 'editors.dart';
import 'privacy.dart';

class BalanceApp extends StatelessWidget {
  const BalanceApp({super.key, required this.store, this.lock});
  final AppStore store;

  /// App lock and privacy cover; absent in tests that do not need it.
  final AppLock? lock;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => MaterialApp(
      title: 'Баланс',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
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
      builder: (context, child) =>
          PrivacyGate(lock: lock, child: child ?? const SizedBox.shrink()),
      home: store.ready
          ? BalanceShell(store: store, lock: lock)
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
  );
}

class BalanceShell extends StatefulWidget {
  const BalanceShell({super.key, required this.store, this.lock});
  final AppStore store;
  final AppLock? lock;
  @override
  State<BalanceShell> createState() => _BalanceShellState();
}

class _BalanceShellState extends State<BalanceShell> {
  AppStore get store => widget.store;
  int page = 0;
  int months = 1;
  String query = '', filter = 'all';
  DateTime budgetMonth = DateTime(DateTime.now().year, DateTime.now().month);
  static const titles = [
    'Обзор',
    'Операции',
    'Аналитика',
    'Бюджеты',
    'Настройки',
  ];
  static const icons = [
    Icons.space_dashboard_outlined,
    Icons.receipt_long_outlined,
    Icons.insights_outlined,
    Icons.savings_outlined,
    Icons.settings_outlined,
  ];
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
            content: Text(
              e.toString().replaceFirst('Invalid argument(s): ', ''),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    LaunchActions.listen(quickAdd);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final action = await LaunchActions.initialAction();
      if (action != null && mounted) await quickAdd(action);
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
      await actions.setShortcutItems(const [
        ShortcutItem(type: 'expense', localizedTitle: 'Расход'),
        ShortcutItem(type: 'income', localizedTitle: 'Доход'),
      ]);
    } catch (_) {
      // Shortcuts are optional; the plugin is absent in tests.
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
          ? ' · ${money(t.amountMinor, store.currency)}'
          : '';
      // No chip tooltip: its long-press recognizer would swallow deletion.
      return Semantics(
        hint: isSaved
            ? 'Шаблон. Удерживайте, чтобы удалить'
            : 'Часто повторяется',
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
            label: Text('${t.title}$amount', overflow: TextOverflow.ellipsis),
            onPressed: () => editTransaction(null, t),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        sectionTitle('Быстрый ввод'),
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
      'Удалить шаблон «${t.title}»?',
      message: 'Операции не изменятся, удалится только шаблон.',
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
    final amount = TextEditingController(
      text: amountInput(FinanceMath.totalBalance(store.transactions)),
    );
    final note = TextEditingController();
    final form = GlobalKey<FormState>();
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Скорректировать баланс'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Укажите фактический остаток. Разница сохранится отдельной операцией и не повлияет на аналитику.',
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Фактический баланс, ${store.currency}',
                  ),
                  validator: (s) => parseAmount(s ?? '', signed: true) == null
                      ? 'Введите сумму'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Заметка'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, parseAmount(amount.text, signed: true));
              }
            },
            child: const Text('Сохранить'),
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

  @override
  Widget build(BuildContext context) {
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
            const Text('Баланс', style: TextStyle(fontWeight: FontWeight.w700)),
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
                  ? 'Настроить синхронизацию'
                  : 'Синхронизировать',
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
            NavigationRail(
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              labelType: NavigationRailLabelType.all,
              minWidth: 100,
              leading: Padding(
                padding: const EdgeInsets.only(bottom: 28, top: 16),
                child: FloatingActionButton(
                  tooltip: 'Добавить операцию',
                  onPressed: editTransaction,
                  child: const Icon(Icons.add),
                ),
              ),
              destinations: List.generate(
                5,
                (i) => NavigationRailDestination(
                  icon: Icon(icons[i]),
                  label: Text(titles[i]),
                ),
              ),
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
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                titles[page],
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                page == 0
                                    ? DateFormat(
                                        'LLLL y',
                                        'ru',
                                      ).format(DateTime.now())
                                    : [
                                        '',
                                        'Вся история ваших финансов',
                                        'Понимайте, куда уходят деньги',
                                        'Планируйте расходы по категориям',
                                        'Ваши предпочтения и данные',
                                      ][page],
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
                            label: const Text('Новая операция'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    if (store.error != null) ...[
                      MaterialBanner(
                        content: Text(store.error!),
                        leading: const Icon(Icons.cloud_off_outlined),
                        actions: [
                          TextButton(
                            onPressed: store.clearError,
                            child: const Text('Закрыть'),
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
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              destinations: List.generate(
                5,
                (i) => NavigationDestination(
                  icon: Icon(icons[i]),
                  label: titles[i],
                ),
              ),
            ),
      floatingActionButton: !wide && (page == 0 || page == 1)
          ? FloatingActionButton.extended(
              onPressed: editTransaction,
              icon: const Icon(Icons.add),
              label: const Text('Операция'),
            )
          : null,
    );
  }

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
    final summary = FinanceMath.summary(store.transactions, start, end);
    return [
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
                const Expanded(child: Text('Общий баланс')),
                TextButton.icon(
                  onPressed: adjust,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Изменить'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                money(
                  FinanceMath.totalBalance(store.transactions),
                  store.currency,
                ),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              store.session == null
                  ? 'Данные хранятся на этом устройстве'
                  : '${store.email} · ${store.syncMessage ?? 'Готово к синхронизации'}',
            ),
          ],
        ),
      ),
      quickEntry(),
      const SizedBox(height: 20),
      metricRow([
        Metric(
          label: 'Доходы за месяц',
          value: money(summary.incomeMinor, store.currency),
          icon: Icons.south_west,
          color: Colors.teal,
        ),
        Metric(
          label: 'Расходы за месяц',
          value: money(summary.expensesMinor, store.currency),
          icon: Icons.north_east,
          color: Colors.deepOrange,
        ),
      ]),
      const SizedBox(height: 28),
      sectionTitle('Расходы по категориям'),
      spending(start, end, limit: 5),
      const SizedBox(height: 28),
      sectionTitle(
        'Последние операции',
        action: TextButton(
          onPressed: () => setState(() => page = 1),
          child: const Text('Все операции'),
        ),
      ),
      if (store.transactions.isEmpty)
        EmptyView(
          title: 'Начните с первой операции',
          subtitle: 'Запишите доход или расход, чтобы увидеть свой баланс.',
          action: FilledButton.icon(
            onPressed: editTransaction,
            icon: const Icon(Icons.add),
            label: const Text('Добавить'),
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

  Widget transactionTile(TransactionRecord t) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
    leading: CategoryAvatar(
      icon: t.isBalanceAdjustment ? 'tune' : t.categoryIcon,
      emoji: t.categoryEmoji,
      color: t.categoryColorName,
    ),
    title: Text(
      t.isBalanceAdjustment ? 'Корректировка баланса' : t.categoryName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      '${DateFormat('d MMM, HH:mm', 'ru').format(t.date.toLocal())}${t.note.isEmpty ? '' : ' · ${t.note}'}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${t.kindRawValue == 'income' ? '+' : '−'}${money(t.amountMinor, store.currency)}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: t.kindRawValue == 'income' ? Colors.teal : null,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Действия с операцией',
          onSelected: (v) async {
            if (v == 'edit') {
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
                success: 'Шаблон сохранён в «Быстрый ввод»',
              );
            } else if (await confirmDelete(context, 'Удалить операцию?')) {
              await run(() => store.deleteTransaction(t.id));
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Изменить')),
            // A balance adjustment is not spending to repeat or reuse.
            if (!t.isBalanceAdjustment) ...const [
              PopupMenuItem(value: 'repeat', child: Text('Повторить')),
              PopupMenuItem(
                value: 'template',
                child: Text('Сохранить как шаблон'),
              ),
            ],
            const PopupMenuItem(value: 'delete', child: Text('Удалить')),
          ],
        ),
      ],
    ),
    onTap: () => editTransaction(t),
  );
  List<Widget> transactions() {
    final items = store.transactions
        .where(
          (t) =>
              (filter == 'all' || t.kindRawValue == filter) &&
              (query.isEmpty ||
                  '${t.categoryName} ${t.note}'.toLowerCase().contains(
                    query.toLowerCase(),
                  )),
        )
        .toList();
    return [
      TextField(
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Поиск по категории или заметке',
        ),
        onChanged: (s) => setState(() => query = s),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        children: [
          for (final e in {
            'all': 'Все',
            'expense': 'Расходы',
            'income': 'Доходы',
          }.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: filter == e.key,
              onSelected: (_) => setState(() => filter = e.key),
            ),
        ],
      ),
      const SizedBox(height: 20),
      if (items.isEmpty)
        const EmptyView(
          title: 'Операций пока нет',
          subtitle: 'Добавьте операцию или измените условия поиска.',
        )
      else
        // One lightweight widget per day: the page ListView builds only the
        // days on screen, so tens of thousands of operations stay cheap.
        for (final day in _byDay(items))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _DayPanel(items: day, tile: transactionTile),
          ),
    ];
  }

  static List<List<TransactionRecord>> _byDay(List<TransactionRecord> items) {
    final days = <List<TransactionRecord>>[];
    for (final item in items) {
      if (days.isEmpty ||
          !DateUtils.isSameDay(
            days.last.last.date.toLocal(),
            item.date.toLocal(),
          )) {
        days.add([item]);
      } else {
        days.last.add(item);
      }
    }
    return days;
  }

  Widget spending(DateTime start, DateTime end, {int? limit}) {
    var groups = FinanceMath.spending(store.transactions, start, end);
    if (limit != null) groups = groups.take(limit).toList();
    final total = FinanceMath.summary(
      store.transactions,
      start,
      end,
    ).expensesMinor;
    if (groups.isEmpty) {
      return const EmptyView(
        title: 'Расходов за период нет',
        subtitle: 'Здесь появится структура ваших расходов.',
        icon: Icons.donut_large,
      );
    }
    return Panel(
      child: Column(
        children: [
          for (final g in groups)
            Padding(
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
                                g.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              money(g.amountMinor, store.currency),
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
                          '${total == 0 ? 0 : (g.amountMinor / total * 100).round()}% расходов',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> analytics() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - months + 1);
    final end = DateTime(now.year, now.month + 1);
    final sum = FinanceMath.summary(store.transactions, start, end);
    final grouped = FinanceMath.spending(store.transactions, start, end);
    final saving = sum.incomeMinor > 0
        ? sum.balanceMinor / sum.incomeMinor * 100
        : 0.0;
    final days =
        (DateTime.utc(now.year, now.month, now.day)
                    .difference(
                      DateTime.utc(start.year, start.month, start.day),
                    )
                    .inDays +
                1)
            .clamp(1, 10000);
    return [
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 1, label: Text('Месяц')),
          ButtonSegment(value: 3, label: Text('3 месяца')),
          ButtonSegment(value: 12, label: Text('12 месяцев')),
        ],
        selected: {months},
        onSelectionChanged: (s) => setState(() => months = s.first),
      ),
      const SizedBox(height: 20),
      metricRow([
        Metric(
          label: 'Доходы',
          value: money(sum.incomeMinor, store.currency),
          icon: Icons.south_west,
          color: Colors.teal,
        ),
        Metric(
          label: 'Расходы',
          value: money(sum.expensesMinor, store.currency),
          icon: Icons.north_east,
          color: Colors.deepOrange,
        ),
      ]),
      const SizedBox(height: 16),
      metricRow([
        Metric(
          label: 'Сбережения',
          value: '${saving.toStringAsFixed(1)}%',
          icon: Icons.savings_outlined,
        ),
        Metric(
          label: 'Средний расход в день',
          value: money((sum.expensesMinor / days).round(), store.currency),
          icon: Icons.calendar_today_outlined,
        ),
      ]),
      const SizedBox(height: 16),
      metricRow([
        Metric(
          label: 'Результат периода',
          value: money(sum.balanceMinor, store.currency),
          icon: Icons.account_balance_wallet_outlined,
        ),
        Metric(
          label: 'Крупнейшая категория',
          value: grouped.isEmpty ? '—' : grouped.first.name,
          icon: Icons.category_outlined,
        ),
      ]),
      const SizedBox(height: 28),
      sectionTitle('Динамика доходов и расходов'),
      trend(start, end),
      const SizedBox(height: 28),
      sectionTitle('Структура расходов'),
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
            total: money(sum.expensesMinor, store.currency),
          ),
        ),
        const SizedBox(height: 16),
      ],
      spending(start, end),
    ];
  }

  Widget trend(DateTime start, DateTime end) {
    final buckets = <(DateTime, DateTime, String)>[];
    if (months == 1) {
      for (
        var d = start;
        d.isBefore(end);
        d = DateTime(d.year, d.month, d.day + 1)
      ) {
        buckets.add((d, DateTime(d.year, d.month, d.day + 1), '${d.day}'));
      }
    } else if (months == 3) {
      for (
        var d = DateTime(
          start.year,
          start.month,
          start.day - start.weekday + 1,
        );
        d.isBefore(end);
        d = DateTime(d.year, d.month, d.day + 7)
      ) {
        final e = DateTime(d.year, d.month, d.day + 7);
        buckets.add((
          d.isBefore(start) ? start : d,
          e.isAfter(end) ? end : e,
          DateFormat('d.MM').format(d),
        ));
      }
    } else {
      for (var d = start; d.isBefore(end); d = DateTime(d.year, d.month + 1)) {
        buckets.add((
          d,
          DateTime(d.year, d.month + 1),
          DateFormat('MMM', 'ru').format(d),
        ));
      }
    }
    final summaries = buckets
        .map((b) => FinanceMath.summary(store.transactions, b.$1, b.$2))
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
          const Wrap(
            spacing: 20,
            children: [
              Text('● Доходы', style: TextStyle(color: Colors.teal)),
              Text('● Расходы', style: TextStyle(color: Colors.deepOrange)),
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
                      message:
                          '${DateFormat('d MMM', 'ru').format(buckets[i].$1)}\nДоходы: ${money(summaries[i].incomeMinor, store.currency)}\nРасходы: ${money(summaries[i].expensesMinor, store.currency)}',
                      child: Semantics(
                        label:
                            '${buckets[i].$3}, доходы ${money(summaries[i].incomeMinor, store.currency)}, расходы ${money(summaries[i].expensesMinor, store.currency)}',
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
                                      buckets[i].$3,
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
                tooltip: 'Предыдущий месяц',
                onPressed: () => setState(
                  () => budgetMonth = DateTime(
                    budgetMonth.year,
                    budgetMonth.month - 1,
                  ),
                ),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(DateFormat('LLLL y', 'ru').format(budgetMonth)),
              IconButton(
                tooltip: 'Следующий месяц',
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
            label: const Text('Добавить лимит'),
          ),
        ],
      ),
      const SizedBox(height: 24),
      if (entries.isEmpty)
        const EmptyView(
          title: 'Бюджет ещё не запланирован',
          subtitle: 'Задайте месячные лимиты для категорий расходов.',
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
    final used = FinanceMath.budgetUsed(b, store.transactions);
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
                  b.categoryName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Изменить лимит',
                onPressed: () => editBudget(b),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Удалить лимит',
                onPressed: () async {
                  if (await confirmDelete(context, 'Удалить лимит?')) {
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
                money(used, store.currency),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              Text('из ${money(b.limitMinor, store.currency)}'),
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
                ? 'Некорректный лимит. Измените бюджет.'
                : used > b.limitMinor
                ? 'Превышение: ${money(used - b.limitMinor, store.currency)}'
                : 'Осталось: ${money(b.limitMinor - used, store.currency)}',
            style: TextStyle(color: color),
          ),
        ],
      ),
    );
  }

  List<Widget> settings() => [
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle('Оформление'),
          DropdownButtonFormField<String>(
            initialValue: store.currency,
            decoration: const InputDecoration(labelText: 'Валюта'),
            items: const [
              'RUB',
              'EUR',
              'USD',
              'SEK',
            ].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) {
              if (v != null) run(() => store.setCurrency(v));
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('theme-mode-${store.theme}'),
            initialValue: store.theme,
            decoration: const InputDecoration(labelText: 'Тема'),
            items: const [
              DropdownMenuItem(value: 'system', child: Text('Системная')),
              DropdownMenuItem(value: 'light', child: Text('Светлая')),
              DropdownMenuItem(value: 'dark', child: Text('Тёмная')),
            ],
            onChanged: (v) {
              if (v != null) run(() => store.setTheme(v));
            },
          ),
          const SizedBox(height: 20),
          Text(
            'Цветовой пресет',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ColorPreset.values
                .map(
                  (preset) => ChoiceChip(
                    label: Text(preset.label),
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
            const Text(
              'OLED: чистый чёрный фон #000000 в тёмном режиме. При выборе пресета тёмная тема включается автоматически. Можно затем выбрать системный режим.',
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Валюта задаёт формат сумм. Конвертация валют не выполняется.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle('Сервер и синхронизация'),
          Text(
            store.serverUrl.isEmpty ? 'Сервер не подключён' : store.serverUrl,
          ),
          const SizedBox(height: 12),
          Text(
            store.session == null
                ? 'Можно работать локально или подключить свой BalanceServer.'
                : store.email,
          ),
          if (store.lastSyncAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Последняя синхронизация: ${DateFormat('d.MM.y HH:mm').format(store.lastSyncAt!)}',
              ),
            ),
          if (store.syncMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(store.syncMessage!),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: serverDialog,
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Адрес сервера'),
              ),
              if (store.session == null) ...[
                FilledButton(
                  onPressed: store.serverUrl.isEmpty
                      ? null
                      : () => authDialog(false),
                  child: const Text('Войти'),
                ),
                TextButton(
                  onPressed: store.serverUrl.isEmpty
                      ? null
                      : () => authDialog(true),
                  child: const Text('Регистрация'),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: store.syncing ? null : () => run(store.sync),
                  icon: const Icon(Icons.sync),
                  label: const Text('Синхронизировать'),
                ),
                OutlinedButton(
                  onPressed: store.syncing
                      ? null
                      : () => run(store.resetAndSync),
                  child: const Text('Полная синхронизация'),
                ),
                TextButton(
                  onPressed: store.syncing ? null : () => run(store.signOut),
                  child: const Text('Выйти'),
                ),
              ],
            ],
          ),
          if (kIsWeb)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Web: используйте HTTPS и разрешите адрес приложения в CORS-настройках сервера.',
              ),
            ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(
            'Категории',
            action: FilledButton.tonalIcon(
              onPressed: editCategory,
              icon: const Icon(Icons.add),
              label: const Text('Добавить'),
            ),
          ),
          if (store.categories.isEmpty)
            const Text('Создайте свои категории или используйте встроенные.'),
          for (final c in store.categories)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CategoryAvatar(
                icon: c.icon,
                emoji: c.emoji,
                color: c.colorName,
              ),
              title: Text(c.name),
              subtitle: Text(c.kindRawValue == 'income' ? 'Доход' : 'Расход'),
              onTap: () => editCategory(c),
              trailing: IconButton(
                tooltip: 'Удалить категорию',
                onPressed: () async {
                  if (await confirmDelete(
                    context,
                    'Удалить «${c.name}»?',
                    message:
                        'Операции сохранят категорию. Связанные бюджеты будут удалены.',
                  )) {
                    await run(() => store.deleteCategory(c.id));
                  }
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Встроенные категории'),
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
                  title: Text(c.name),
                  subtitle: Text(
                    c.kindRawValue == 'income' ? 'Доход' : 'Расход',
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
    if (widget.lock != null) ...[
      const SizedBox(height: 20),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle('Приватность'),
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
          sectionTitle('Данные'),
          if (store.quarantine.isNotEmpty) ...[
            QuarantinePanel(
              entries: store.quarantine,
              onSave: saveQuarantine,
              onClear: clearQuarantine,
            ),
            const SizedBox(height: 16),
          ],
          const Text(
            'Резервная копия хранит все операции, категории и бюджеты без потерь. '
            'Восстановление добавляет записи из копии и не затирает более новые изменения.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: backup,
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Резервная копия'),
              ),
              OutlinedButton.icon(
                onPressed: restore,
                icon: const Icon(Icons.settings_backup_restore),
                label: const Text('Восстановить из копии'),
              ),
              OutlinedButton.icon(
                onPressed: importStatement,
                icon: const Icon(Icons.account_balance_outlined),
                label: const Text('Импорт выписки банка'),
              ),
              OutlinedButton.icon(
                onPressed: export,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Экспорт истории CSV'),
              ),
              TextButton(
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: 'Баланс',
                  applicationVersion: '4.2.0',
                  applicationIcon: const Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 40,
                  ),
                  children: const [
                    Text(
                      'Личный бюджет · Flutter · Material 3\nСинхронизация с BalanceServer',
                    ),
                  ],
                ),
                child: const Text('О приложении'),
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
        title: const Text('Адрес сервера'),
        content: SizedBox(
          width: 460,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'При смене сервера потребуется новый вход. Данные аккаунтов хранятся раздельно.',
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
                      return 'Введите полный адрес сервера';
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
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, controller.text);
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result != null) {
      await run(
        () => store.setServerUrl(result),
        success: 'Адрес сервера сохранён',
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
        title: Text(register ? 'Создать аккаунт' : 'Войти в аккаунт'),
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
                  decoration: const InputDecoration(
                    labelText: 'Электронная почта',
                  ),
                  validator: (s) =>
                      (s ?? '').contains('@') ? null : 'Введите email',
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
                  decoration: const InputDecoration(labelText: 'Пароль'),
                  validator: (s) => (s ?? '').isEmpty
                      ? 'Введите пароль'
                      : register && s!.length < 8
                      ? 'Не менее 8 символов'
                      : null,
                ),
                const SizedBox(height: 12),
                const Text(
                  'При первом подключении нового аккаунта локальные записи переносятся в него. Аккаунты хранятся раздельно.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: Text(register ? 'Зарегистрироваться' : 'Войти'),
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
    final file = await pickFile('Резервная копия', ['json']);
    if (file == null || !mounted) return;
    await run(() async {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(await file.readAsBytes()));
      } on FormatException {
        throw const FormatException('Файл повреждён или это не JSON');
      }
      final plan = await store.previewBackup(decoded);
      if (plan.items.isEmpty) {
        throw FormatException(
          plan.invalid > 0
              ? 'В копии нет читаемых записей'
              : 'Восстанавливать нечего: копия пуста или содержит только удаления',
        );
      }
      if (!mounted) return;
      final keys = await showBackupPreview(
        context,
        plan: plan,
        fileName: file.name,
        currency: store.currency,
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
      'Выписка',
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
          SnackBar(content: Text('Импортировано операций: $added')),
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
      'Очистить отложенные записи?',
      message:
          'Копии повреждённых записей будут удалены с устройства. Сначала сохраните отчёт, если они нужны.',
      action: 'Очистить',
    )) {
      await run(store.clearQuarantine);
    }
  }
}

class _DayPanel extends StatelessWidget {
  const _DayPanel({required this.items, required this.tile});
  final List<TransactionRecord> items;
  final Widget Function(TransactionRecord) tile;
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              DateFormat('d MMMM y', 'ru').format(items.first.date.toLocal()),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
        for (final item in items) tile(item),
      ],
    ),
  );
}
