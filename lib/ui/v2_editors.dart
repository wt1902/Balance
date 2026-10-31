import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../domain/finance.dart';
import '../domain/records.dart';
import '../services/app_store.dart';
import 'design.dart';
import 'v2_common.dart';

const _uuid = Uuid();

Widget _title(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 20),
  child: Text(text, style: Theme.of(context).textTheme.headlineSmall),
);

const _gap = SizedBox(height: 16);

InputDecoration _decoration(String label, {String? helper}) => InputDecoration(
  labelText: label,
  helperText: helper,
  helperMaxLines: 3,
  border: const OutlineInputBorder(),
);

String? _positive(String? v, {String message = 'Введите положительную сумму'}) {
  final m = parseAmount(v ?? '');
  return m == null || m <= 0 ? message : null;
}

String? _nonNegative(String? v) {
  if ((v ?? '').trim().isEmpty) return null;
  return parseAmount(v ?? '') == null ? 'Введите сумму' : null;
}

/// UTC noon of a local calendar day, so the UTC date of a recurring start or
/// end date (§4) is the day the user picked in nearly every time zone.
DateTime utcNoon(DateTime day) {
  final local = day.toLocal();
  return DateTime.utc(local.year, local.month, local.day, 12);
}

/// The local calendar day of a UTC-noon date.
DateTime fromUtcNoon(DateTime value) {
  final utc = value.toUtc();
  return DateTime(utc.year, utc.month, utc.day, 12);
}

class AccountEditor extends StatefulWidget {
  const AccountEditor({super.key, required this.store, this.existing});
  final AppStore store;
  final AccountRecord? existing;
  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late AccountKind kind = widget.existing?.kind ?? AccountKind.card;
  late String currency = widget.existing?.currency ?? widget.store.baseCurrency;
  late String color = widget.existing?.colorName ?? 'blue';
  late bool archived = widget.existing?.isArchived ?? false;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final now = DateTime.now();
    final e = widget.existing;
    final accounts = widget.store.accounts;
    Navigator.pop(
      context,
      e?.copyWith(
            name: name.text.trim(),
            kindRawValue: kind.name,
            icon: accountIcon(kind),
            colorName: color,
            currency: currency,
            isArchived: archived,
            updatedAt: now,
          ) ??
          AccountRecord(
            id: _uuid.v4(),
            name: name.text.trim(),
            kindRawValue: kind.name,
            icon: accountIcon(kind),
            colorName: color,
            currency: currency,
            createdAt: now,
            updatedAt: now,
            sortOrder: accounts.isEmpty ? 0 : accounts.last.sortOrder + 1,
          ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            context,
            widget.existing == null ? 'Новый счёт' : 'Изменить счёт',
          ),
          TextFormField(
            controller: name,
            autofocus: widget.existing == null,
            maxLength: 80,
            decoration: _decoration('Название'),
            validator: (s) =>
                (s ?? '').trim().isEmpty ? 'Введите название счёта' : null,
          ),
          _gap,
          DropdownButtonFormField<AccountKind>(
            initialValue: kind,
            isExpanded: true,
            decoration: _decoration('Тип'),
            items: [
              for (final k in AccountKind.values)
                DropdownMenuItem(
                  value: k,
                  child: Row(
                    children: [
                      Icon(categoryIcons[accountIcon(k)], size: 20),
                      const SizedBox(width: 12),
                      Text(k.title),
                    ],
                  ),
                ),
            ],
            onChanged: (k) => setState(() => kind = k ?? kind),
          ),
          _gap,
          CurrencyField(
            value: currency,
            options: currencyOptions(widget.store, currency),
            onChanged: (c) => setState(() => currency = c ?? currency),
            label: 'Валюта счёта',
          ),
          if (widget.existing != null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'При смене валюты суммы операций счёта не пересчитываются.',
              ),
            ),
          _gap,
          Text('Цвет', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ColorChoice(
            value: color,
            onChanged: (c) => setState(() => color = c),
          ),
          if (widget.existing != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('В архиве'),
              subtitle: const Text(
                'Счёт скрыт из выбора, но его баланс входит в общий.',
              ),
              value: archived,
              onChanged: (v) => setState(() => archived = v),
            ),
          const SizedBox(height: 24),
          EditorActions(onSave: save),
        ],
      ),
    ),
  );
}

class TransferEditor extends StatefulWidget {
  const TransferEditor({
    super.key,
    required this.store,
    this.existing,
    this.fromAccountId,
  });
  final AppStore store;
  final TransferRecord? existing;
  final String? fromAccountId;
  @override
  State<TransferEditor> createState() => _TransferEditorState();
}

class _TransferEditorState extends State<TransferEditor> {
  final form = GlobalKey<FormState>();
  late String? from =
      widget.existing?.fromAccountId ??
      widget.fromAccountId ??
      widget.store.activeAccounts.firstOrNull?.id;
  late String? to =
      widget.existing?.toAccountId ??
      widget.store.activeAccounts.where((a) => a.id != from).firstOrNull?.id;
  late final amount = TextEditingController(
    text: widget.existing == null
        ? ''
        : amountInput(widget.existing!.amountMinor),
  );
  late final toAmount = TextEditingController(
    text: widget.existing == null
        ? ''
        : amountInput(widget.existing!.toAmountMinor),
  );
  late final note = TextEditingController(text: widget.existing?.note ?? '');
  late DateTime date = widget.existing?.date.toLocal() ?? DateTime.now();

  @override
  void dispose() {
    amount.dispose();
    toAmount.dispose();
    note.dispose();
    super.dispose();
  }

  String currencyOf(String? id) => widget.store.accountCurrency(id);
  bool get crossCurrency =>
      from != null && to != null && currencyOf(from) != currencyOf(to);

  void save() {
    if (!form.currentState!.validate()) return;
    final sent = parseAmount(amount.text)!;
    final received = crossCurrency ? parseAmount(toAmount.text)! : sent;
    final now = DateTime.now();
    final e = widget.existing;
    Navigator.pop(
      context,
      e != null
          ? TransferRecord(
              id: e.id,
              fromAccountId: from!,
              toAccountId: to!,
              amountMinor: sent,
              toAmountMinor: received,
              date: date,
              note: note.text.trim(),
              updatedAt: now,
              extra: e.extra,
            )
          : TransferRecord(
              id: _uuid.v4(),
              fromAccountId: from!,
              toAccountId: to!,
              amountMinor: sent,
              toAmountMinor: received,
              date: date,
              note: note.text.trim(),
              updatedAt: now,
            ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            context,
            widget.existing == null ? 'Новый перевод' : 'Изменить перевод',
          ),
          const Text(
            'Перевод между своими счетами — не доход и не расход: он не '
            'входит в аналитику и бюджеты.',
          ),
          _gap,
          AccountField(
            store: widget.store,
            value: from,
            label: 'Со счёта',
            allowNone: false,
            onChanged: (v) => setState(() => from = v),
          ),
          _gap,
          AccountField(
            store: widget.store,
            value: to,
            label: 'На счёт',
            allowNone: false,
            exclude: from,
            onChanged: (v) => setState(() => to = v),
          ),
          _gap,
          TextFormField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _decoration(
              from == null ? 'Сумма' : 'Сумма, ${currencyOf(from)}',
            ),
            validator: (v) {
              if (from != null && from == to) return 'Счета должны различаться';
              return _positive(v);
            },
          ),
          if (crossCurrency) ...[
            _gap,
            TextFormField(
              controller: toAmount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _decoration(
                'Зачислено, ${currencyOf(to)}',
                helper: 'Валюты счетов различаются: укажите сумму зачисления.',
              ),
              validator: _positive,
            ),
          ],
          const SizedBox(height: 8),
          DateRow(
            label: 'Дата',
            value: date,
            onPick: () async {
              final d = await pickDay(context, date);
              if (d != null) setState(() => date = d);
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: note,
            maxLength: 4000,
            decoration: _decoration('Заметка'),
          ),
          const SizedBox(height: 16),
          EditorActions(onSave: save),
        ],
      ),
    ),
  );
}

class RecurringEditor extends StatefulWidget {
  const RecurringEditor({super.key, required this.store, this.existing});
  final AppStore store;
  final RecurringRecord? existing;
  @override
  State<RecurringEditor> createState() => _RecurringEditorState();
}

class _RecurringEditorState extends State<RecurringEditor> {
  final form = GlobalKey<FormState>();
  late final e = widget.existing;
  late String kind = e?.kindRawValue ?? 'expense';
  late final amount = TextEditingController(
    text: e == null ? '' : amountInput(e!.amountMinor),
  );
  late final note = TextEditingController(text: e?.note ?? '');
  late final interval = TextEditingController(text: '${e?.interval ?? 1}');
  late CategoryRecord category = e == null
      ? widget.store.categoriesForKind(kind).first
      : CategoryRecord(
          id: 'recurring',
          name: e!.categoryName,
          icon: e!.categoryIcon,
          emoji: e!.categoryEmoji,
          colorName: e!.categoryColorName,
          kindRawValue: kind,
          createdAt: e!.startDate,
          updatedAt: e!.updatedAt,
        );
  late String? accountId = e?.accountId;
  late String? currency = e?.currency;
  late List<String> tags = e?.tags ?? const [];
  late String frequency = e?.frequency?.name ?? 'monthly';
  late DateTime start = e == null ? DateTime.now() : fromUtcNoon(e!.startDate);
  late DateTime? end = e?.endDate == null ? null : fromUtcNoon(e!.endDate!);
  late String mode = e?.mode?.name ?? 'auto';
  late bool paused = e?.isPaused ?? false;

  List<CategoryRecord> get choices {
    final list = widget.store.categoriesForKind(kind);
    if (!list.any((c) => c.name == category.name)) list.add(category);
    return list;
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    interval.dispose();
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final now = DateTime.now();
    final startDate = utcNoon(start);
    final record = RecurringRecord(
      id: e?.id ?? _uuid.v4(),
      kindRawValue: kind,
      amountMinor: parseAmount(amount.text)!,
      currency: currency,
      accountId: accountId,
      categoryName: category.name,
      categoryIcon: category.icon,
      categoryEmoji: category.emoji,
      categoryColorName: category.colorName,
      note: note.text.trim(),
      tags: tags,
      frequencyRawValue: frequency,
      interval: int.parse(interval.text.trim()),
      startDate: startDate,
      endDate: end == null ? null : utcNoon(end!),
      modeRawValue: mode,
      isPaused: paused,
      // Already handled occurrences stay handled after any edit.
      generatedThrough: e?.generatedThrough,
      updatedAt: now,
      extra: e?.extra ?? const {},
    );
    Navigator.pop(context, record);
  }

  static const frequencies = {
    'daily': 'Каждый день',
    'weekly': 'Каждую неделю',
    'monthly': 'Каждый месяц',
    'yearly': 'Каждый год',
  };

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            context,
            e == null
                ? 'Новый регулярный платёж'
                : 'Изменить регулярный платёж',
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('Расход')),
              ButtonSegment(value: 'income', label: Text('Доход')),
            ],
            selected: {kind},
            onSelectionChanged: (s) => setState(() {
              kind = s.first;
              category = widget.store.categoriesForKind(kind).first;
            }),
          ),
          _gap,
          TextFormField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _decoration('Сумма'),
            validator: _positive,
          ),
          _gap,
          DropdownButtonFormField<String>(
            key: ValueKey('recurring-category-$kind'),
            initialValue: category.name,
            isExpanded: true,
            decoration: _decoration('Категория'),
            items: [
              for (final c in choices)
                DropdownMenuItem(
                  value: c.name,
                  child: Text(c.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(
              () => category = choices.firstWhere((c) => c.name == v),
            ),
          ),
          _gap,
          AccountField(
            store: widget.store,
            value: accountId,
            onChanged: (v) => setState(() => accountId = v),
          ),
          _gap,
          CurrencyField(
            value: currency,
            options: currencyOptions(widget.store),
            nullLabel: defaultCurrencyLabel(widget.store, accountId),
            onChanged: (v) => setState(() => currency = v),
          ),
          _gap,
          TextFormField(
            controller: note,
            maxLength: 4000,
            decoration: _decoration('Заметка'),
          ),
          const SizedBox(height: 8),
          TagsField(
            tags: tags,
            suggestions: widget.store.knownTags,
            onChanged: (t) => setState(() => tags = t),
          ),
          _gap,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  initialValue: frequency,
                  isExpanded: true,
                  decoration: _decoration('Повтор'),
                  items: [
                    for (final f in frequencies.entries)
                      DropdownMenuItem(
                        value: f.key,
                        child: Text(f.value, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => frequency = v ?? frequency),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: interval,
                  keyboardType: TextInputType.number,
                  decoration: _decoration('Интервал'),
                  validator: (v) {
                    final n = int.tryParse((v ?? '').trim());
                    return n == null || n < 1 || n > 999 ? '1–999' : null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DateRow(
            label: 'Начало',
            value: start,
            onPick: () async {
              final d = await pickDay(context, start);
              if (d != null) setState(() => start = d);
            },
          ),
          DateRow(
            label: 'Окончание',
            value: end,
            emptyText: 'Без окончания',
            onPick: () async {
              final d = await pickDay(context, end ?? start, first: start);
              if (d != null) setState(() => end = d);
            },
            onClear: () => setState(() => end = null),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'auto',
                label: Text('Автоматически'),
                icon: Icon(Icons.autorenew),
              ),
              ButtonSegment(
                value: 'remind',
                label: Text('Напоминать'),
                icon: Icon(Icons.notifications_none),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setState(() => mode = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            mode == 'auto'
                ? 'Операции создаются сами в день платежа.'
                : 'В день платежа операция появится в блоке «Ожидают»: '
                      'её можно записать или пропустить.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (e != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Пауза'),
              subtitle: const Text('Ничего не создаётся и не напоминается.'),
              value: paused,
              onChanged: (v) => setState(() => paused = v),
            ),
          const SizedBox(height: 24),
          EditorActions(onSave: save),
        ],
      ),
    ),
  );
}

class GoalEditor extends StatefulWidget {
  const GoalEditor({super.key, required this.store, this.existing});
  final AppStore store;
  final GoalRecord? existing;
  @override
  State<GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends State<GoalEditor> {
  final form = GlobalKey<FormState>();
  late final e = widget.existing;
  late final name = TextEditingController(text: e?.name ?? '');
  late final target = TextEditingController(
    text: e == null ? '' : amountInput(e!.targetMinor),
  );
  late final saved = TextEditingController(
    text: e == null || e!.savedMinor == 0 ? '' : amountInput(e!.savedMinor),
  );
  late String? accountId = e?.accountId;
  late String currency = e == null
      ? widget.store.baseCurrency
      : widget.store.goalCurrency(e!);
  late DateTime? deadline = e?.deadline?.toLocal();
  late String color = e?.colorName ?? 'sky';
  late bool archived = e?.isArchived ?? false;

  @override
  void dispose() {
    name.dispose();
    target.dispose();
    saved.dispose();
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final now = DateTime.now();
    final goalCurrency = accountId == null
        ? currency
        : widget.store.accountCurrency(accountId);
    final savedMinor = saved.text.trim().isEmpty ? 0 : parseAmount(saved.text)!;
    final record =
        e?.copyWith(
          name: name.text.trim(),
          targetMinor: parseAmount(target.text)!,
          currency: goalCurrency,
          deadline: deadline,
          accountId: accountId,
          savedMinor: savedMinor,
          colorName: color,
          isArchived: archived,
          updatedAt: now,
        ) ??
        GoalRecord(
          id: _uuid.v4(),
          name: name.text.trim(),
          targetMinor: parseAmount(target.text)!,
          currency: goalCurrency,
          deadline: deadline,
          accountId: accountId,
          savedMinor: savedMinor,
          colorName: color,
          createdAt: now,
          updatedAt: now,
        );
    Navigator.pop(context, record);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, e == null ? 'Новая цель' : 'Изменить цель'),
          TextFormField(
            controller: name,
            autofocus: e == null,
            maxLength: 80,
            decoration: _decoration('Название'),
            validator: (s) =>
                (s ?? '').trim().isEmpty ? 'Введите название цели' : null,
          ),
          _gap,
          AccountField(
            store: widget.store,
            value: accountId,
            label: 'Копить на счёте',
            noneLabel: 'Не привязана к счёту',
            onChanged: (v) => setState(() => accountId = v),
          ),
          const SizedBox(height: 6),
          Text(
            accountId == null
                ? 'Прогресс — сумма в поле «Накоплено».'
                : 'Прогресс — баланс выбранного счёта.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          _gap,
          CurrencyField(
            value: accountId == null
                ? currency
                : widget.store.accountCurrency(accountId),
            options: currencyOptions(widget.store, currency),
            enabled: accountId == null,
            onChanged: (c) => setState(() => currency = c ?? currency),
          ),
          _gap,
          TextFormField(
            controller: target,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _decoration('Цель, сумма'),
            validator: _positive,
          ),
          if (accountId == null) ...[
            _gap,
            TextFormField(
              controller: saved,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _decoration('Накоплено'),
              validator: _nonNegative,
            ),
          ],
          const SizedBox(height: 8),
          DateRow(
            label: 'Срок',
            value: deadline,
            emptyText: 'Без срока',
            onPick: () async {
              final d = await pickDay(context, deadline ?? DateTime.now());
              if (d != null) setState(() => deadline = d);
            },
            onClear: () => setState(() => deadline = null),
          ),
          const SizedBox(height: 8),
          Text('Цвет', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ColorChoice(
            value: color,
            onChanged: (c) => setState(() => color = c),
          ),
          if (e != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('В архиве'),
              value: archived,
              onChanged: (v) => setState(() => archived = v),
            ),
          const SizedBox(height: 24),
          EditorActions(onSave: save),
        ],
      ),
    ),
  );
}

class DebtEditor extends StatefulWidget {
  const DebtEditor({super.key, required this.store, this.existing});
  final AppStore store;
  final DebtRecord? existing;
  @override
  State<DebtEditor> createState() => _DebtEditorState();
}

class _DebtEditorState extends State<DebtEditor> {
  final form = GlobalKey<FormState>();
  late final e = widget.existing;
  late String direction = e?.directionRawValue ?? 'owedToMe';
  late final person = TextEditingController(text: e?.person ?? '');
  late final amount = TextEditingController(
    text: e == null ? '' : amountInput(e!.amountMinor),
  );
  late final repaid = TextEditingController(
    text: e == null || e!.repaidMinor == 0 ? '' : amountInput(e!.repaidMinor),
  );
  late final note = TextEditingController(text: e?.note ?? '');
  late String currency = e?.currency ?? widget.store.baseCurrency;
  late DateTime date = e?.date.toLocal() ?? DateTime.now();
  late DateTime? due = e?.dueDate?.toLocal();
  late bool closed = e?.isClosed ?? false;

  @override
  void dispose() {
    person.dispose();
    amount.dispose();
    repaid.dispose();
    note.dispose();
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final now = DateTime.now();
    final repaidMinor = repaid.text.trim().isEmpty
        ? 0
        : parseAmount(repaid.text)!;
    final record =
        e?.copyWith(
          person: person.text.trim(),
          directionRawValue: direction,
          amountMinor: parseAmount(amount.text)!,
          currency: currency,
          date: date,
          dueDate: due,
          note: note.text.trim(),
          repaidMinor: repaidMinor,
          isClosed: closed,
          updatedAt: now,
        ) ??
        DebtRecord(
          id: _uuid.v4(),
          person: person.text.trim(),
          directionRawValue: direction,
          amountMinor: parseAmount(amount.text)!,
          currency: currency,
          date: date,
          dueDate: due,
          note: note.text.trim(),
          repaidMinor: repaidMinor,
          isClosed: closed,
          updatedAt: now,
        );
    Navigator.pop(context, record);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context, e == null ? 'Новый долг' : 'Изменить долг'),
          SegmentedButton<String>(
            segments: [
              for (final d in DebtDirection.values)
                ButtonSegment(value: d.name, label: Text(d.title)),
            ],
            selected: {direction},
            onSelectionChanged: (s) => setState(() => direction = s.first),
          ),
          _gap,
          TextFormField(
            controller: person,
            maxLength: 80,
            decoration: _decoration(
              direction == 'iOwe' ? 'Кому я должен' : 'Кто должен',
            ),
            validator: (s) =>
                (s ?? '').trim().isEmpty ? 'Укажите, кто должен' : null,
          ),
          _gap,
          TextFormField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _decoration('Сумма долга'),
            validator: _positive,
          ),
          _gap,
          CurrencyField(
            value: currency,
            options: currencyOptions(widget.store, currency),
            onChanged: (c) => setState(() => currency = c ?? currency),
          ),
          _gap,
          TextFormField(
            controller: repaid,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _decoration('Уже возвращено'),
            validator: (v) {
              final error = _nonNegative(v);
              if (error != null) return error;
              final total = parseAmount(amount.text);
              final back = (v ?? '').trim().isEmpty ? 0 : parseAmount(v!)!;
              return total != null && back > total
                  ? 'Больше суммы долга'
                  : null;
            },
          ),
          const SizedBox(height: 8),
          DateRow(
            label: 'Дата',
            value: date,
            onPick: () async {
              final d = await pickDay(context, date);
              if (d != null) setState(() => date = d);
            },
          ),
          DateRow(
            label: 'Вернуть до',
            value: due,
            emptyText: 'Без срока',
            onPick: () async {
              final d = await pickDay(context, due ?? date);
              if (d != null) setState(() => due = d);
            },
            onClear: () => setState(() => due = null),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: note,
            maxLength: 4000,
            decoration: _decoration('Заметка'),
          ),
          if (e != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Закрыт'),
              value: closed,
              onChanged: (v) => setState(() => closed = v),
            ),
          const SizedBox(height: 8),
          Text(
            'Долги не меняют баланс. Деньги, которые реально ушли или пришли, '
            'запишите обычной операцией.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          EditorActions(onSave: save),
        ],
      ),
    ),
  );
}

class RateEditor extends StatefulWidget {
  const RateEditor({
    super.key,
    required this.store,
    this.existing,
    this.from,
    this.to,
  });
  final AppStore store;
  final RateRecord? existing;
  final String? from, to;
  @override
  State<RateEditor> createState() => _RateEditorState();
}

class _RateEditorState extends State<RateEditor> {
  final form = GlobalKey<FormState>();
  late final e = widget.existing;
  late String to = e?.to ?? widget.to ?? widget.store.baseCurrency;
  late String from =
      e?.from ??
      widget.from ??
      currencyOptions(widget.store).firstWhere((c) => c != to);
  late final rate = TextEditingController(text: e?.rate ?? '');
  late DateTime date = e?.date.toLocal() ?? DateTime.now();

  @override
  void dispose() {
    rate.dispose();
    super.dispose();
  }

  String get normalized => rate.text.trim().replaceAll(',', '.');

  void save() {
    if (!form.currentState!.validate()) return;
    final now = DateTime.now();
    // A rate for today applies right away: its date is the current moment,
    // not a later midnight (§2 uses the latest rate on the calculation day).
    final today = DateUtils.isSameDay(date, now);
    final at = today ? now : DateTime(date.year, date.month, date.day);
    Navigator.pop(
      context,
      e?.copyWith(
            from: from,
            to: to,
            rate: normalized,
            date: at.toUtc(),
            updatedAt: now,
          ) ??
          RateRecord(
            id: _uuid.v4(),
            from: from,
            to: to,
            rate: normalized,
            date: at.toUtc(),
            updatedAt: now,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = currencyOptions(widget.store, from);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(context, e == null ? 'Новый курс' : 'Изменить курс'),
            Row(
              children: [
                Expanded(
                  child: CurrencyField(
                    value: from,
                    label: 'Из',
                    options: options,
                    onChanged: (c) => setState(() => from = c ?? from),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward),
                ),
                Expanded(
                  child: CurrencyField(
                    value: to,
                    label: 'В',
                    options: currencyOptions(widget.store, to),
                    onChanged: (c) => setState(() => to = c ?? to),
                  ),
                ),
              ],
            ),
            _gap,
            TextFormField(
              controller: rate,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _decoration(
                'Курс: 1 $from = ? $to',
                helper: 'До 6 знаков после запятой.',
              ),
              validator: (v) {
                if (from == to) return 'Валюты должны различаться';
                try {
                  RateRecord.parseRateMicros(
                    (v ?? '').trim().replaceAll(',', '.'),
                  );
                  return null;
                } on FormatException catch (error) {
                  return error.message;
                }
              },
            ),
            const SizedBox(height: 8),
            DateRow(
              label: 'Дата курса',
              value: date,
              onPick: () async {
                final d = await pickDay(context, date);
                if (d != null) setState(() => date = d);
              },
            ),
            const SizedBox(height: 24),
            EditorActions(onSave: save),
          ],
        ),
      ),
    );
  }
}
