import 'package:cross_file/cross_file.dart';
import '../l10n/app_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/finance.dart';
import '../domain/records.dart';
import '../domain/recurring.dart';
import '../services/app_store.dart';
import '../services/sync_api.dart';
import 'data_tools.dart';
import 'design.dart';
import 'editors.dart';
import 'v2_common.dart';
import 'v2_editors.dart';

// ---------------------------------------------------------------------------
// Editor launchers: every change goes through AppStore.

Future<void> editAccount(
  BuildContext context,
  AppStore store,
  Runner run, [
  AccountRecord? existing,
]) async {
  final result = await editDialog<AccountRecord>(
    context,
    AccountEditor(store: store, existing: existing),
  );
  if (result != null) await run(() => store.saveAccount(result));
}

Future<void> editTransfer(
  BuildContext context,
  AppStore store,
  Runner run, {
  TransferRecord? existing,
  String? from,
}) async {
  if (existing == null && store.activeAccounts.length < 2) {
    await run(
      () async =>
          throw ArgumentError(uiText('Для перевода нужны хотя бы два счёта')),
    );
    return;
  }
  final result = await editDialog<TransferRecord>(
    context,
    TransferEditor(store: store, existing: existing, fromAccountId: from),
  );
  if (result != null) await run(() => store.saveTransfer(result));
}

Future<void> editRecurring(
  BuildContext context,
  AppStore store,
  Runner run, [
  RecurringRecord? existing,
]) async {
  final result = await editDialog<RecurringRecord>(
    context,
    RecurringEditor(store: store, existing: existing),
  );
  if (result != null) await run(() => store.saveRecurring(result));
}

Future<void> editGoal(
  BuildContext context,
  AppStore store,
  Runner run, [
  GoalRecord? existing,
]) async {
  final result = await editDialog<GoalRecord>(
    context,
    GoalEditor(store: store, existing: existing),
  );
  if (result != null) await run(() => store.saveGoal(result));
}

Future<void> editDebt(
  BuildContext context,
  AppStore store,
  Runner run, [
  DebtRecord? existing,
]) async {
  final result = await editDialog<DebtRecord>(
    context,
    DebtEditor(store: store, existing: existing),
  );
  if (result != null) await run(() => store.saveDebt(result));
}

Future<void> editRate(
  BuildContext context,
  AppStore store,
  Runner run, {
  RateRecord? existing,
  String? from,
  String? to,
}) async {
  final result = await editDialog<RateRecord>(
    context,
    RateEditor(store: store, existing: existing, from: from, to: to),
  );
  if (result != null) {
    await run(() => store.saveRate(result), success: uiText('Курс сохранён'));
  }
}

/// A one-field dialog; returns the trimmed text or null.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String action = 'Сохранить',
  String? message,
}) async {
  final controller = TextEditingController(text: initial);
  final form = GlobalKey<FormState>();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: SizedBox(
        width: 400,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) ...[
                Text(message),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: controller,
                autofocus: true,
                maxLength: 80,
                decoration: InputDecoration(labelText: label),
                validator: (s) =>
                    (s ?? '').trim().isEmpty ? uiText('Заполните поле') : null,
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
              Navigator.pop(context, controller.text.trim());
            }
          },
          child: Text(uiText(action)),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}

/// The actual balance of an account; returns the target in hundredths.
Future<int?> askBalance(
  BuildContext context,
  String title,
  String currency,
  int current,
) async {
  final controller = TextEditingController(text: amountInput(current));
  final form = GlobalKey<FormState>();
  final result = await showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: SizedBox(
        width: 400,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                uiText(
                  'Укажите фактический остаток. Разница сохранится корректировкой и не повлияет на аналитику.',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: uiText('Фактический баланс, {0}', [currency]),
                ),
                validator: (s) => parseAmount(s ?? '', signed: true) == null
                    ? uiText('Введите сумму')
                    : null,
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
              Navigator.pop(
                context,
                parseAmount(controller.text, signed: true),
              );
            }
          },
          child: Text(uiText('Сохранить')),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}

Widget _menu(
  String tooltip,
  Map<String, String> items,
  void Function(String) onSelected,
) => PopupMenuButton<String>(
  tooltip: tooltip,
  onSelected: onSelected,
  itemBuilder: (_) => [
    for (final e in items.entries)
      PopupMenuItem(value: e.key, child: Text(e.value)),
  ],
);

// ---------------------------------------------------------------------------
// «Счета»

class AccountsSection extends StatelessWidget {
  const AccountsSection({super.key, required this.store, required this.run});
  final AppStore store;
  final Runner run;

  Widget tile(BuildContext context, AccountRecord a) {
    final currency = store.accountCurrency(a.id);
    final balance = store.accountBalances[a.id] ?? 0;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: CategoryAvatar(icon: a.icon, color: a.colorName),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${uiText(a.kind.title)} · $currency'),
      onTap: () => editAccount(context, store, run, a),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            signedMoney(balance, currency),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: balance < 0 ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          _menu(
            uiText('Действия со счётом'),
            {
              'edit': uiText('Изменить'),
              if (!a.isArchived) 'transfer': uiText('Перевод с этого счёта'),
              'adjust': uiText('Скорректировать баланс'),
              'archive': a.isArchived
                  ? uiText('Вернуть из архива')
                  : uiText('В архив'),
              'delete': uiText('Удалить'),
            },
            (v) async {
              switch (v) {
                case 'edit':
                  await editAccount(context, store, run, a);
                case 'transfer':
                  await editTransfer(context, store, run, from: a.id);
                case 'adjust':
                  final target = await askBalance(
                    context,
                    uiText('Баланс «{0}»', [a.name]),
                    currency,
                    balance,
                  );
                  if (target != null) {
                    await run(
                      () => store.adjustBalance(target, accountId: a.id),
                    );
                  }
                case 'archive':
                  await run(
                    () => store.saveAccount(
                      a.copyWith(
                        isArchived: !a.isArchived,
                        updatedAt: DateTime.now(),
                      ),
                    ),
                  );
                case 'delete':
                  if (await confirmDelete(
                    context,
                    uiText('Удалить счёт «{0}»?', [a.name]),
                    message: uiText(
                      'Операции и переводы останутся и будут показаны как «Удалённый счёт». Чтобы просто скрыть счёт, отправьте его в архив.',
                    ),
                  )) {
                    await run(() => store.deleteAccount(a.id));
                  }
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = store.activeAccounts;
    final archived = store.accounts.where((a) => a.isArchived).toList();
    final known = {for (final a in store.accounts) a.id};
    final deleted = {
      for (final e in store.accountBalances.entries)
        if (!known.contains(e.key) && e.value != 0) e.key: e.value,
    };
    final unassigned = {
      for (final e in store.unassignedBalances.entries)
        if (e.value != 0) e.key: e.value,
    };
    final base = store.baseCurrency;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MissingRatesNotice(
          pairs: store.missingRates,
          onAddRate: (from, to) =>
              editRate(context, store, run, from: from, to: to),
        ),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(uiText('Общий баланс')),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  signedMoney(store.balanceMinor, base),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                uiText('Все счета в базовой валюте {0}, архивные тоже.', [
                  base,
                ]),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => editAccount(context, store, run),
              icon: const Icon(Icons.add),
              label: Text(uiText('Новый счёт')),
            ),
            OutlinedButton.icon(
              onPressed: active.length < 2
                  ? null
                  : () => editTransfer(context, store, run),
              icon: const Icon(Icons.swap_horiz),
              label: Text(uiText('Перевод')),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (store.accounts.isEmpty)
          EmptyView(
            title: uiText('Счетов пока нет'),
            subtitle: uiText(
              'Добавьте наличные, карту или вклад, чтобы видеть баланс каждого и записывать переводы.',
            ),
            icon: Icons.account_balance_wallet_outlined,
          )
        else
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                for (final a in active) tile(context, a),
                if (unassigned.isNotEmpty)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    leading: const CategoryAvatar(
                      icon: 'ellipsis.circle.fill',
                      color: 'gray',
                    ),
                    title: Text(uiText('Без счёта')),
                    subtitle: Text(uiText('Операции без выбранного счёта')),
                    trailing: Text(
                      [
                        for (final e in unassigned.entries)
                          signedMoney(e.value, e.key),
                      ].join('\n'),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                for (final e in deleted.entries)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    leading: const CategoryAvatar(
                      icon: 'ellipsis.circle.fill',
                      color: 'slate',
                    ),
                    title: Text(uiText('Удалённый счёт')),
                    subtitle: Text(uiText('Остались операции или переводы')),
                    trailing: Text(
                      signedMoney(e.value, base),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: 16),
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ExpansionTile(
              title: Text(uiText('Архив ({0})', [archived.length])),
              shape: const Border(),
              children: [for (final a in archived) tile(context, a)],
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// «Регулярные платежи»

String frequencyTitle(RecurringRecord rule) {
  final n = rule.interval;
  final frequency = rule.frequency;
  if (frequency == null) return uiText('Неизвестный повтор');
  if (n == 1) {
    return switch (frequency) {
      RecurrenceFrequency.daily => uiText('Каждый день'),
      RecurrenceFrequency.weekly => uiText('Каждую неделю'),
      RecurrenceFrequency.monthly => uiText('Каждый месяц'),
      RecurrenceFrequency.yearly => uiText('Каждый год'),
    };
  }
  return uiText('Каждые {0} {1}', [
    n,
    switch (frequency) {
      RecurrenceFrequency.daily => uiText('дн.'),
      RecurrenceFrequency.weekly => uiText('нед.'),
      RecurrenceFrequency.monthly => uiText('мес.'),
      RecurrenceFrequency.yearly => n < 5 ? uiText('года') : uiText('лет'),
    },
  ]);
}

String _ruleCurrency(AppStore store, RecurringRecord rule) =>
    rule.currency ?? store.accountCurrency(rule.accountId);

/// «Ожидают»: occurrences of `remind` rules to record or skip (§4).
class PendingRecurringPanel extends StatelessWidget {
  const PendingRecurringPanel({
    super.key,
    required this.store,
    required this.run,
    this.limit,
  });
  final AppStore store;
  final Runner run;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final all = store.pendingReminders;
    if (all.isEmpty) return const SizedBox.shrink();
    final items = limit == null ? all : all.take(limit!).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    uiText('Ожидают: {0}', [all.length]),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final o in items) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CategoryAvatar(
                  icon: o.rule.categoryIcon,
                  emoji: o.rule.categoryEmoji,
                  color: o.rule.categoryColorName,
                  size: 36,
                ),
                title: Text(
                  o.rule.note.isEmpty ? o.rule.categoryName : o.rule.note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(dayTitle(o.date)),
                trailing: Text(
                  '${o.rule.kind == TransactionKind.income ? '+' : '−'}'
                  '${money(o.rule.amountMinor, _ruleCurrency(store, o.rule))}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () => run(
                      () => store.confirmRecurring(o.rule.id, o.occurrence),
                      success: uiText('Операция записана'),
                    ),
                    child: Text(uiText('Записать')),
                  ),
                  TextButton(
                    onPressed: () =>
                        run(() => store.skipRecurring(o.rule.id, o.occurrence)),
                    child: Text(uiText('Пропустить')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (items.length < all.length)
              Text(uiText('И ещё {0}', [all.length - items.length])),
          ],
        ),
      ),
    );
  }
}

class RecurringSection extends StatelessWidget {
  const RecurringSection({super.key, required this.store, required this.run});
  final AppStore store;
  final Runner run;

  @override
  Widget build(BuildContext context) {
    final rules = store.recurring;
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PendingRecurringPanel(store: store, run: run),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => editRecurring(context, store, run),
            icon: const Icon(Icons.add),
            label: Text(uiText('Новый платёж')),
          ),
        ),
        const SizedBox(height: 20),
        if (rules.isEmpty)
          EmptyView(
            title: uiText('Регулярных платежей нет'),
            subtitle: uiText(
              'Аренда, связь, подписки, зарплата: операции будут создаваться сами или ждать подтверждения.',
            ),
            icon: Icons.event_repeat,
          )
        else
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                for (final rule in rules)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    leading: CategoryAvatar(
                      icon: rule.categoryIcon,
                      emoji: rule.categoryEmoji,
                      color: rule.categoryColorName,
                    ),
                    title: Text(
                      rule.note.isEmpty ? rule.categoryName : rule.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(() {
                      final next = RecurringEngine.nextOccurrence(rule, now);
                      return [
                        frequencyTitle(rule),
                        rule.mode == RecurringMode.remind
                            ? uiText('с напоминанием')
                            : uiText('автоматически'),
                        if (rule.isPaused)
                          uiText('на паузе')
                        else if (next != null)
                          uiText('следующий {0}', [dayTitle(next)])
                        else
                          uiText('завершён'),
                      ].join(' · ');
                    }(), maxLines: 3),
                    onTap: () => editRecurring(context, store, run, rule),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${rule.kind == TransactionKind.income ? '+' : '−'}'
                          '${money(rule.amountMinor, _ruleCurrency(store, rule))}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: rule.kind == TransactionKind.income
                                ? Colors.teal
                                : null,
                          ),
                        ),
                        _menu(
                          uiText('Действия с платежом'),
                          {
                            'edit': uiText('Изменить'),
                            'pause': rule.isPaused
                                ? uiText('Возобновить')
                                : uiText('Пауза'),
                            'delete': uiText('Удалить'),
                          },
                          (v) async {
                            if (v == 'edit') {
                              await editRecurring(context, store, run, rule);
                            } else if (v == 'pause') {
                              await run(
                                () => store.saveRecurring(
                                  rule.copyWith(
                                    isPaused: !rule.isPaused,
                                    updatedAt: DateTime.now(),
                                  ),
                                ),
                              );
                            } else if (await confirmDelete(
                              context,
                              uiText('Удалить регулярный платёж?'),
                              message: uiText(
                                'Уже созданные операции останутся. Новые создаваться не будут.',
                              ),
                            )) {
                              await run(() => store.deleteRecurring(rule.id));
                            }
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// «Цели»

class GoalsSection extends StatelessWidget {
  const GoalsSection({super.key, required this.store, required this.run});
  final AppStore store;
  final Runner run;

  Widget card(BuildContext context, GoalRecord goal) {
    final currency = store.goalCurrency(goal);
    final progress = store.goalProgress(goal);
    final remaining = store.goalRemaining(goal);
    final ratio = (progress / goal.targetMinor).clamp(0.0, 1.0);
    final color =
        categoryColors[goal.colorName] ?? Theme.of(context).colorScheme.primary;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CategoryAvatar(icon: goal.icon, color: goal.colorName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      [
                        if (goal.accountId != null)
                          uiText('Счёт: {0}', [
                            accountName(store, goal.accountId),
                          ]),
                        if (goal.deadline != null)
                          uiText('до {0}', [dayTitle(goal.deadline!)]),
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _menu(
                uiText('Действия с целью'),
                {
                  'edit': uiText('Изменить'),
                  'archive': goal.isArchived
                      ? uiText('Вернуть из архива')
                      : uiText('В архив'),
                  'delete': uiText('Удалить'),
                },
                (v) async {
                  if (v == 'edit') {
                    await editGoal(context, store, run, goal);
                  } else if (v == 'archive') {
                    await run(
                      () => store.saveGoal(
                        goal.copyWith(
                          isArchived: !goal.isArchived,
                          updatedAt: DateTime.now(),
                        ),
                      ),
                    );
                  } else if (await confirmDelete(
                    context,
                    uiText('Удалить цель «{0}»?', [goal.name]),
                  )) {
                    await run(() => store.deleteGoal(goal.id));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                signedMoney(progress, currency),
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(uiText('из {0}', [money(goal.targetMinor, currency)])),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: ratio,
            color: color,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 10),
          Text(
            remaining == 0
                ? uiText('Цель достигнута')
                : uiText('Осталось: {0} · {1}%', [
                    money(remaining, currency),
                    (ratio * 100).floor(),
                  ]),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final goals = store.goals.where((g) => !g.isArchived).toList();
    final archived = store.goals.where((g) => g.isArchived).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => editGoal(context, store, run),
            icon: const Icon(Icons.add),
            label: Text(uiText('Новая цель')),
          ),
        ),
        const SizedBox(height: 20),
        if (goals.isEmpty)
          EmptyView(
            title: uiText('Целей пока нет'),
            subtitle: uiText(
              'Отпуск, подушка безопасности, техника: следите, сколько накоплено и сколько осталось.',
            ),
            icon: Icons.flag_outlined,
          ),
        for (final g in goals)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: card(context, g),
          ),
        if (archived.isNotEmpty)
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ExpansionTile(
              title: Text(uiText('Архив ({0})', [archived.length])),
              shape: const Border(),
              childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: [
                for (final g in archived)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: card(context, g),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// «Долги»

class DebtsSection extends StatelessWidget {
  const DebtsSection({super.key, required this.store, required this.run});
  final AppStore store;
  final Runner run;

  Widget card(BuildContext context, DebtRecord debt) {
    final currency = debt.currency ?? store.baseCurrency;
    final ratio = (debt.repaidMinor / debt.amountMinor).clamp(0.0, 1.0);
    final now = DateTime.now();
    final overdue =
        !debt.isClosed &&
        debt.dueDate != null &&
        debt.dueDate!.toLocal().isBefore(
          DateTime(now.year, now.month, now.day),
        );
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CategoryAvatar(
                icon: debt.direction == DebtDirection.iOwe
                    ? 'banknote.fill'
                    : 'heart.fill',
                color: debt.direction == DebtDirection.iOwe ? 'orange' : 'teal',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      debt.person,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      [
                        dayTitle(debt.date),
                        if (debt.dueDate != null)
                          '${overdue ? uiText('просрочен, срок') : uiText('вернуть до')} '
                              '${dayTitle(debt.dueDate!)}',
                        if (debt.note.isNotEmpty) debt.note,
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: overdue ? scheme.error : null,
                      ),
                    ),
                  ],
                ),
              ),
              _menu(
                uiText('Действия с долгом'),
                {
                  'edit': uiText('Изменить'),
                  'close': debt.isClosed
                      ? uiText('Открыть снова')
                      : uiText('Закрыть'),
                  'delete': uiText('Удалить'),
                },
                (v) async {
                  if (v == 'edit') {
                    await editDebt(context, store, run, debt);
                  } else if (v == 'close') {
                    await run(
                      () => store.saveDebt(
                        debt.copyWith(
                          isClosed: !debt.isClosed,
                          updatedAt: DateTime.now(),
                        ),
                      ),
                    );
                  } else if (await confirmDelete(
                    context,
                    uiText('Удалить долг «{0}»?', [debt.person]),
                  )) {
                    await run(() => store.deleteDebt(debt.id));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                money(debt.remainingMinor, currency),
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                uiText('осталось из {0}', [money(debt.amountMinor, currency)]),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 8),
          Text(uiText('Возвращено: {0}', [money(debt.repaidMinor, currency)])),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = store.debts.where((d) => !d.isClosed).toList();
    final closed = store.debts.where((d) => d.isClosed).toList();
    List<Widget> group(DebtDirection direction) {
      final items = open.where((d) => d.direction == direction).toList();
      if (items.isEmpty) return const [];
      return [
        SectionHeader(uiText(direction.title)),
        for (final d in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: card(context, d),
          ),
        const SizedBox(height: 8),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => editDebt(context, store, run),
            icon: const Icon(Icons.add),
            label: Text(uiText('Новый долг')),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          uiText(
            'Долги не меняют баланс и аналитику. Деньги, которые реально ушли или пришли, записывайте обычной операцией.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        if (open.isEmpty)
          EmptyView(
            title: uiText('Открытых долгов нет'),
            subtitle: uiText('Записывайте, кому вы должны и кто должен вам.'),
            icon: Icons.handshake_outlined,
          ),
        ...group(DebtDirection.owedToMe),
        ...group(DebtDirection.iOwe),
        if (closed.isNotEmpty)
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ExpansionTile(
              title: Text(uiText('Закрытые ({0})', [closed.length])),
              shape: const Border(),
              childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: [
                for (final d in closed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: card(context, d),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings → «Валюты и курсы»

class CurrencySettingsPanel extends StatelessWidget {
  const CurrencySettingsPanel({
    super.key,
    required this.store,
    required this.run,
  });
  final AppStore store;
  final Runner run;

  @override
  Widget build(BuildContext context) {
    final rates = store.rates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CurrencyField(
          value: store.baseCurrency,
          label: uiText('Базовая валюта'),
          options: currencyOptions(store),
          onChanged: (v) {
            if (v != null && v != store.baseCurrency) {
              run(() => store.setBaseCurrency(v));
            }
          },
        ),
        const SizedBox(height: 8),
        Text(
          uiText(
            'В базовой валюте считаются общий баланс, аналитика и бюджеты. Настройка синхронизируется между устройствами. Суммы в других валютах пересчитываются по последнему курсу.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        MissingRatesNotice(
          pairs: store.missingRates,
          onAddRate: (from, to) =>
              editRate(context, store, run, from: from, to: to),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                uiText('Курсы'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: () => editRate(context, store, run),
              icon: const Icon(Icons.add),
              label: Text(uiText('Добавить курс')),
            ),
          ],
        ),
        if (rates.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              uiText('Курсов нет. Они нужны, только если валют несколько.'),
            ),
          ),
        for (final r in rates)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.currency_exchange),
            title: Text('1 ${r.from} = ${r.rate.replaceAll('.', ',')} ${r.to}'),
            subtitle: Text(dayTitle(r.date)),
            onTap: () => editRate(context, store, run, existing: r),
            trailing: IconButton(
              tooltip: uiText('Удалить курс'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirmDelete(context, uiText('Удалить курс?'))) {
                  await run(() => store.deleteRate(r.id));
                }
              },
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings → «Общие пространства» (§7)

class LedgersPanel extends StatelessWidget {
  const LedgersPanel({super.key, required this.store, required this.run});
  final AppStore store;
  final Runner run;

  static String roleTitle(String role) =>
      role == 'owner' ? uiText('Владелец') : uiText('Участник');

  Future<void> showInvite(BuildContext context, Ledger ledger) async {
    LedgerInvite? invite;
    await run(() async => invite = await store.createLedgerInvite(ledger.id));
    final code = invite;
    if (code == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(uiText('Приглашение в «{0}»', [ledger.name])),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(uiText('Передайте код участнику. Код одноразовый.')),
            const SizedBox(height: 16),
            SelectableText(
              code.code,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              uiText('Действует до {0}', [
                localDateFormat(
                  'd MMMM y, HH:mm',
                ).format(code.expiresAt.toLocal()),
              ]),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: code.code)),
            icon: const Icon(Icons.copy),
            label: Text(uiText('Копировать')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(uiText('Готово')),
          ),
        ],
      ),
    );
  }

  Future<void> showMembers(BuildContext context, Ledger ledger) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(uiText('Участники «{0}»', [ledger.name])),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ledger.members.isEmpty)
                  Text(uiText('Список участников появится после обновления.')),
                for (final m in ledger.members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text(
                      m.email.isEmpty ? m.userId : m.email,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(roleTitle(m.role)),
                    trailing:
                        ledger.isOwner &&
                            m.role != 'owner' &&
                            m.userId != store.session?.userId
                        ? IconButton(
                            tooltip: uiText('Удалить участника'),
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () async {
                              Navigator.pop(context);
                              await run(
                                () => store.removeLedgerMember(
                                  ledger.id,
                                  m.userId,
                                ),
                                success: uiText('Участник удалён'),
                              );
                            },
                          )
                        : null,
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(uiText('Закрыть')),
            ),
          ],
        ),
      );

  Future<void> onAction(
    BuildContext context,
    Ledger ledger,
    String action,
  ) async {
    switch (action) {
      case 'open':
        await run(() => store.selectLedger(ledger.id));
      case 'invite':
        await showInvite(context, ledger);
      case 'members':
        await showMembers(context, ledger);
      case 'rename':
        final name = await askText(
          context,
          title: uiText('Переименовать пространство'),
          label: uiText('Название'),
          initial: ledger.name,
        );
        if (name != null) await run(() => store.renameLedger(ledger.id, name));
      case 'delete':
        if (await confirmDelete(
          context,
          uiText('Удалить «{0}»?', [ledger.name]),
          message: uiText(
            'Пространство будет удалено на сервере со всеми записями и вложениями для всех участников.',
          ),
        )) {
          await run(() => store.deleteLedger(ledger.id));
        }
      case 'leave':
        if (await confirmDelete(
          context,
          uiText('Выйти из «{0}»?', [ledger.name]),
          message: uiText(
            'Вернуться можно будет только по новому приглашению.',
          ),
          action: uiText('Выйти'),
        )) {
          await run(() => store.leaveLedger(ledger.id));
        }
    }
  }

  Widget entry(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool active,
    required VoidCallback onOpen,
    Widget? trailing,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: active ? Theme.of(context).colorScheme.primary : null,
    ),
    title: Text(title, overflow: TextOverflow.ellipsis),
    subtitle: Text(subtitle),
    selected: active,
    onTap: active ? null : onOpen,
    trailing: trailing,
  );

  @override
  Widget build(BuildContext context) {
    final active = store.activeLedgerId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          uiText(
            'Общее пространство — отдельный набор операций, счетов и бюджетов, который видят все участники. Личные данные в него не переносятся.',
          ),
        ),
        const SizedBox(height: 8),
        entry(
          context,
          title: uiText('Личное пространство'),
          subtitle: uiText('Только ваши данные'),
          active: active == null,
          onOpen: () => run(() => store.selectLedger(null)),
        ),
        for (final l in store.ledgers)
          entry(
            context,
            title: l.name,
            subtitle: [
              roleTitle(l.role),
              if (l.members.isNotEmpty)
                uiText('участников: {0}', [l.members.length]),
            ].join(' · '),
            active: active == l.id,
            onOpen: () => run(() => store.selectLedger(l.id)),
            trailing: _menu(uiText('Действия с пространством'), {
              if (active != l.id) 'open': uiText('Открыть'),
              if (l.isOwner) 'invite': uiText('Пригласить'),
              'members': uiText('Участники'),
              if (l.isOwner) 'rename': uiText('Переименовать'),
              if (l.isOwner) 'delete': uiText('Удалить'),
              if (!l.isOwner) 'leave': uiText('Выйти'),
            }, (v) => onAction(context, l, v)),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                final name = await askText(
                  context,
                  title: uiText('Новое пространство'),
                  label: uiText('Название'),
                  action: uiText('Создать'),
                );
                if (name != null) {
                  await run(
                    () => store.createLedger(name),
                    success: uiText('Пространство создано'),
                  );
                }
              },
              icon: const Icon(Icons.group_add_outlined),
              label: Text(uiText('Создать')),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final code = await askText(
                  context,
                  title: uiText('Присоединиться'),
                  label: uiText('Код приглашения'),
                  action: uiText('Присоединиться'),
                );
                if (code != null) {
                  await run(
                    () => store.joinLedger(code),
                    success: uiText('Вы присоединились к пространству'),
                  );
                }
              },
              icon: const Icon(Icons.login),
              label: Text(uiText('Присоединиться')),
            ),
            TextButton.icon(
              onPressed: () => run(store.refreshLedgers),
              icon: const Icon(Icons.refresh),
              label: Text(uiText('Обновить')),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Attachments of a transaction (§8)

const _attachmentTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'heic': 'image/heic',
  'pdf': 'application/pdf',
};

String attachmentType(XFile file) {
  final name = file.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1);
  return _attachmentTypes[ext] ?? file.mimeType ?? 'application/octet-stream';
}

class AttachmentsSection extends StatefulWidget {
  const AttachmentsSection({
    super.key,
    required this.store,
    required this.transactionId,
  });
  final AppStore store;
  final String transactionId;

  /// Replaced in tests; the default opens the system file picker.
  static Future<XFile?> Function() picker = () => pickFile(
    uiText('Чек или документ'),
    _attachmentTypes.keys.toList(),
    androidMimeTypes: _attachmentTypes.values.toSet().toList(),
  );

  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  bool busy = false;
  String? error;
  AppStore get store => widget.store;

  Future<void> guarded(Future<void> Function() body) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e.toString().replaceFirst(
            RegExp(r'^(Invalid argument\(s\)|Bad state|FormatException): '),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add() => guarded(() async {
    final file = await AttachmentsSection.picker();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await store.addAttachment(
      transactionId: widget.transactionId,
      bytes: bytes,
      contentType: attachmentType(file),
      name: file.name,
    );
  });

  Future<void> open(AttachmentRecord a) => guarded(() async {
    final bytes = await store.attachmentBytes(a);
    if (!mounted) return;
    final name = a.name.isEmpty ? uiText('файл') : a.name;
    final ext = name.contains('.') ? name.split('.').last : 'bin';
    Future<void> save() => saveFile(
      context,
      bytes,
      name: name,
      mimeType: a.contentType,
      label: uiText('Вложение'),
      extension: ext,
    );
    if (a.contentType == 'image/jpeg' || a.contentType == 'image/png') {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: InteractiveViewer(
                  child: Image.memory(
                    bytes,
                    semanticLabel: name,
                    errorBuilder: (_, _, _) => Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(uiText('Не удалось показать изображение')),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: save,
                      icon: const Icon(Icons.open_in_new),
                      label: Text(uiText('Открыть или сохранить')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(uiText('Закрыть')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      await save();
    }
  });

  Future<void> remove(AttachmentRecord a) async {
    if (await confirmDelete(context, uiText('Удалить вложение?'))) {
      await guarded(() => store.deleteAttachment(a.id));
    }
  }

  static String size(int bytes) => bytes < 1024 * 1024
      ? uiText('{0} КБ', [(bytes / 1024).ceil()])
      : uiText('{0} МБ', [(bytes / 1024 / 1024).toStringAsFixed(1)]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final items = store.attachmentsFor(widget.transactionId);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  uiText('Вложения'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          for (final a in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                a.contentType == 'application/pdf'
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
              ),
              title: Text(
                a.name.isEmpty ? uiText('Файл') : a.name,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${size(a.size)}'
                '${store.isUploadPending(a) ? uiText(' · ждёт загрузки') : ''}',
              ),
              onTap: busy ? null : () => open(a),
              trailing: IconButton(
                tooltip: uiText('Удалить вложение'),
                icon: const Icon(Icons.delete_outline),
                onPressed: busy ? null : () => remove(a),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: busy ? null : add,
              icon: const Icon(Icons.attach_file),
              label: Text(uiText('Прикрепить чек')),
            ),
          ),
          if (kIsWeb)
            Text(
              uiText('Файлы хранятся в браузере до загрузки на сервер.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// «Ещё» on phones

class MoreEntry {
  const MoreEntry(this.page, this.title, this.icon, this.subtitle);
  final int page;
  final String title;
  final IconData icon;
  final String subtitle;
}

class MoreHub extends StatelessWidget {
  const MoreHub({super.key, required this.entries, required this.onOpen});
  final List<MoreEntry> entries;
  final ValueChanged<int> onOpen;
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        for (final e in entries)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 4,
            ),
            leading: Icon(e.icon),
            title: Text(e.title),
            subtitle: Text(e.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(e.page),
          ),
      ],
    ),
  );
}
