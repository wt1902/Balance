import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

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
      () async => throw ArgumentError('Для перевода нужны хотя бы два счёта'),
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
    await run(() => store.saveRate(result), success: 'Курс сохранён');
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
                    (s ?? '').trim().isEmpty ? 'Заполните поле' : null,
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
              Navigator.pop(context, controller.text.trim());
            }
          },
          child: Text(action),
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
              const Text(
                'Укажите фактический остаток. Разница сохранится '
                'корректировкой и не повлияет на аналитику.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Фактический баланс, $currency',
                ),
                validator: (s) => parseAmount(s ?? '', signed: true) == null
                    ? 'Введите сумму'
                    : null,
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
              Navigator.pop(
                context,
                parseAmount(controller.text, signed: true),
              );
            }
          },
          child: const Text('Сохранить'),
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
      subtitle: Text('${a.kind.title} · $currency'),
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
            'Действия со счётом',
            {
              'edit': 'Изменить',
              if (!a.isArchived) 'transfer': 'Перевод с этого счёта',
              'adjust': 'Скорректировать баланс',
              'archive': a.isArchived ? 'Вернуть из архива' : 'В архив',
              'delete': 'Удалить',
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
                    'Баланс «${a.name}»',
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
                    'Удалить счёт «${a.name}»?',
                    message:
                        'Операции и переводы останутся и будут показаны как '
                        '«Удалённый счёт». Чтобы просто скрыть счёт, '
                        'отправьте его в архив.',
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
              const Text('Общий баланс'),
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
                'Все счета в базовой валюте $base, архивные тоже.',
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
              label: const Text('Новый счёт'),
            ),
            OutlinedButton.icon(
              onPressed: active.length < 2
                  ? null
                  : () => editTransfer(context, store, run),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Перевод'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (store.accounts.isEmpty)
          const EmptyView(
            title: 'Счетов пока нет',
            subtitle:
                'Добавьте наличные, карту или вклад, чтобы видеть баланс '
                'каждого и записывать переводы.',
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
                    title: const Text('Без счёта'),
                    subtitle: const Text('Операции без выбранного счёта'),
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
                    title: const Text('Удалённый счёт'),
                    subtitle: const Text('Остались операции или переводы'),
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
              title: Text('Архив (${archived.length})'),
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
  if (frequency == null) return 'Неизвестный повтор';
  if (n == 1) {
    return switch (frequency) {
      RecurrenceFrequency.daily => 'Каждый день',
      RecurrenceFrequency.weekly => 'Каждую неделю',
      RecurrenceFrequency.monthly => 'Каждый месяц',
      RecurrenceFrequency.yearly => 'Каждый год',
    };
  }
  return 'Каждые $n ${switch (frequency) {
    RecurrenceFrequency.daily => 'дн.',
    RecurrenceFrequency.weekly => 'нед.',
    RecurrenceFrequency.monthly => 'мес.',
    RecurrenceFrequency.yearly => n < 5 ? 'года' : 'лет',
  }}';
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
                    'Ожидают: ${all.length}',
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
                      success: 'Операция записана',
                    ),
                    child: const Text('Записать'),
                  ),
                  TextButton(
                    onPressed: () =>
                        run(() => store.skipRecurring(o.rule.id, o.occurrence)),
                    child: const Text('Пропустить'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (items.length < all.length)
              Text('И ещё ${all.length - items.length}'),
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
            label: const Text('Новый платёж'),
          ),
        ),
        const SizedBox(height: 20),
        if (rules.isEmpty)
          const EmptyView(
            title: 'Регулярных платежей нет',
            subtitle:
                'Аренда, связь, подписки, зарплата: операции будут '
                'создаваться сами или ждать подтверждения.',
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
                            ? 'с напоминанием'
                            : 'автоматически',
                        if (rule.isPaused)
                          'на паузе'
                        else if (next != null)
                          'следующий ${dayTitle(next)}'
                        else
                          'завершён',
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
                          'Действия с платежом',
                          {
                            'edit': 'Изменить',
                            'pause': rule.isPaused ? 'Возобновить' : 'Пауза',
                            'delete': 'Удалить',
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
                              'Удалить регулярный платёж?',
                              message:
                                  'Уже созданные операции останутся. Новые '
                                  'создаваться не будут.',
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
                          'Счёт: ${accountName(store, goal.accountId)}',
                        if (goal.deadline != null)
                          'до ${dayTitle(goal.deadline!)}',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _menu(
                'Действия с целью',
                {
                  'edit': 'Изменить',
                  'archive': goal.isArchived ? 'Вернуть из архива' : 'В архив',
                  'delete': 'Удалить',
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
                    'Удалить цель «${goal.name}»?',
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
              Text('из ${money(goal.targetMinor, currency)}'),
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
                ? 'Цель достигнута'
                : 'Осталось: ${money(remaining, currency)} · '
                      '${(ratio * 100).floor()}%',
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
            label: const Text('Новая цель'),
          ),
        ),
        const SizedBox(height: 20),
        if (goals.isEmpty)
          const EmptyView(
            title: 'Целей пока нет',
            subtitle:
                'Отпуск, подушка безопасности, техника: следите, сколько '
                'накоплено и сколько осталось.',
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
              title: Text('Архив (${archived.length})'),
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
                          '${overdue ? 'просрочен, срок' : 'вернуть до'} '
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
                'Действия с долгом',
                {
                  'edit': 'Изменить',
                  'close': debt.isClosed ? 'Открыть снова' : 'Закрыть',
                  'delete': 'Удалить',
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
                    'Удалить долг «${debt.person}»?',
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
              Text('осталось из ${money(debt.amountMinor, currency)}'),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 8),
          Text('Возвращено: ${money(debt.repaidMinor, currency)}'),
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
        SectionHeader(direction.title),
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
            label: const Text('Новый долг'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Долги не меняют баланс и аналитику. Деньги, которые реально ушли '
          'или пришли, записывайте обычной операцией.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        if (open.isEmpty)
          const EmptyView(
            title: 'Открытых долгов нет',
            subtitle: 'Записывайте, кому вы должны и кто должен вам.',
            icon: Icons.handshake_outlined,
          ),
        ...group(DebtDirection.owedToMe),
        ...group(DebtDirection.iOwe),
        if (closed.isNotEmpty)
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ExpansionTile(
              title: Text('Закрытые (${closed.length})'),
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
          label: 'Базовая валюта',
          options: currencyOptions(store),
          onChanged: (v) {
            if (v != null && v != store.baseCurrency) {
              run(() => store.setBaseCurrency(v));
            }
          },
        ),
        const SizedBox(height: 8),
        Text(
          'В базовой валюте считаются общий баланс, аналитика и бюджеты. '
          'Настройка синхронизируется между устройствами. Суммы в других '
          'валютах пересчитываются по последнему курсу.',
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
                'Курсы',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: () => editRate(context, store, run),
              icon: const Icon(Icons.add),
              label: const Text('Добавить курс'),
            ),
          ],
        ),
        if (rates.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Курсов нет. Они нужны, только если валют несколько.'),
          ),
        for (final r in rates)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.currency_exchange),
            title: Text('1 ${r.from} = ${r.rate.replaceAll('.', ',')} ${r.to}'),
            subtitle: Text(dayTitle(r.date)),
            onTap: () => editRate(context, store, run, existing: r),
            trailing: IconButton(
              tooltip: 'Удалить курс',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirmDelete(context, 'Удалить курс?')) {
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
      role == 'owner' ? 'Владелец' : 'Участник';

  Future<void> showInvite(BuildContext context, Ledger ledger) async {
    LedgerInvite? invite;
    await run(() async => invite = await store.createLedgerInvite(ledger.id));
    final code = invite;
    if (code == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Приглашение в «${ledger.name}»'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Передайте код участнику. Код одноразовый.'),
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
              'Действует до '
              '${DateFormat('d MMMM y, HH:mm', 'ru').format(code.expiresAt.toLocal())}',
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: code.code)),
            icon: const Icon(Icons.copy),
            label: const Text('Копировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
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
          title: Text('Участники «${ledger.name}»'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ledger.members.isEmpty)
                  const Text('Список участников появится после обновления.'),
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
                            tooltip: 'Удалить участника',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () async {
                              Navigator.pop(context);
                              await run(
                                () => store.removeLedgerMember(
                                  ledger.id,
                                  m.userId,
                                ),
                                success: 'Участник удалён',
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
              child: const Text('Закрыть'),
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
          title: 'Переименовать пространство',
          label: 'Название',
          initial: ledger.name,
        );
        if (name != null) await run(() => store.renameLedger(ledger.id, name));
      case 'delete':
        if (await confirmDelete(
          context,
          'Удалить «${ledger.name}»?',
          message:
              'Пространство будет удалено на сервере со всеми записями и '
              'вложениями для всех участников.',
        )) {
          await run(() => store.deleteLedger(ledger.id));
        }
      case 'leave':
        if (await confirmDelete(
          context,
          'Выйти из «${ledger.name}»?',
          message: 'Вернуться можно будет только по новому приглашению.',
          action: 'Выйти',
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
        const Text(
          'Общее пространство — отдельный набор операций, счетов и бюджетов, '
          'который видят все участники. Личные данные в него не переносятся.',
        ),
        const SizedBox(height: 8),
        entry(
          context,
          title: 'Личное пространство',
          subtitle: 'Только ваши данные',
          active: active == null,
          onOpen: () => run(() => store.selectLedger(null)),
        ),
        for (final l in store.ledgers)
          entry(
            context,
            title: l.name,
            subtitle: [
              roleTitle(l.role),
              if (l.members.isNotEmpty) 'участников: ${l.members.length}',
            ].join(' · '),
            active: active == l.id,
            onOpen: () => run(() => store.selectLedger(l.id)),
            trailing: _menu('Действия с пространством', {
              if (active != l.id) 'open': 'Открыть',
              if (l.isOwner) 'invite': 'Пригласить',
              'members': 'Участники',
              if (l.isOwner) 'rename': 'Переименовать',
              if (l.isOwner) 'delete': 'Удалить',
              if (!l.isOwner) 'leave': 'Выйти',
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
                  title: 'Новое пространство',
                  label: 'Название',
                  action: 'Создать',
                );
                if (name != null) {
                  await run(
                    () => store.createLedger(name),
                    success: 'Пространство создано',
                  );
                }
              },
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Создать'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final code = await askText(
                  context,
                  title: 'Присоединиться',
                  label: 'Код приглашения',
                  action: 'Присоединиться',
                );
                if (code != null) {
                  await run(
                    () => store.joinLedger(code),
                    success: 'Вы присоединились к пространству',
                  );
                }
              },
              icon: const Icon(Icons.login),
              label: const Text('Присоединиться'),
            ),
            TextButton.icon(
              onPressed: () => run(store.refreshLedgers),
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить'),
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
    'Чек или документ',
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
    final name = a.name.isEmpty ? 'файл' : a.name;
    final ext = name.contains('.') ? name.split('.').last : 'bin';
    Future<void> save() => saveFile(
      context,
      bytes,
      name: name,
      mimeType: a.contentType,
      label: 'Вложение',
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
                    errorBuilder: (_, _, _) => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Не удалось показать изображение'),
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
                      label: const Text('Открыть или сохранить'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Закрыть'),
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
    if (await confirmDelete(context, 'Удалить вложение?')) {
      await guarded(() => store.deleteAttachment(a.id));
    }
  }

  static String size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).ceil()} КБ'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';

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
                  'Вложения',
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
                a.name.isEmpty ? 'Файл' : a.name,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${size(a.size)}'
                '${store.isUploadPending(a) ? ' · ждёт загрузки' : ''}',
              ),
              onTap: busy ? null : () => open(a),
              trailing: IconButton(
                tooltip: 'Удалить вложение',
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
              label: const Text('Прикрепить чек'),
            ),
          ),
          if (kIsWeb)
            Text(
              'Файлы хранятся в браузере до загрузки на сервер.',
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
