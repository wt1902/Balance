import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/finance.dart';
import '../domain/transaction_filter.dart';
import 'design.dart';

String _day(DateTime d) => DateFormat('d MMM y', 'ru').format(d);

/// Human-readable filter chips shown above the list.
String periodTitle(TransactionFilter f) {
  final from = f.start, to = f.endExclusive;
  final now = DateTime.now();
  for (final preset in PeriodPreset.values) {
    final (s, e) = preset.range(now);
    if (from == s && to == e) return preset.title;
  }
  if (from != null && to != null) {
    return '${_day(from)} – ${_day(to.subtract(const Duration(days: 1)))}';
  }
  return from != null
      ? 'С ${_day(from)}'
      : 'По ${_day(to!.subtract(const Duration(days: 1)))}';
}

String amountTitle(TransactionFilter f, String currency) {
  final min = f.minMinor, max = f.maxMinor;
  if (min != null && max != null) {
    return '${money(min, currency)} – ${money(max, currency)}';
  }
  return min != null
      ? 'от ${money(min, currency)}'
      : 'до ${money(max!, currency)}';
}

/// Period, amount and categories; returns the edited filter or null.
class TransactionFilterSheet extends StatefulWidget {
  const TransactionFilterSheet({
    super.key,
    required this.filter,
    required this.categories,
    required this.currency,
  });
  final TransactionFilter filter;
  final List<CategoryRecord> categories;
  final String currency;
  @override
  State<TransactionFilterSheet> createState() => _TransactionFilterSheetState();
}

class _TransactionFilterSheetState extends State<TransactionFilterSheet> {
  late TransactionFilter draft = widget.filter;
  late final min = TextEditingController(
    text: draft.minMinor == null ? '' : amountInput(draft.minMinor!),
  );
  late final max = TextEditingController(
    text: draft.maxMinor == null ? '' : amountInput(draft.maxMinor!),
  );
  String? amountError;

  @override
  void dispose() {
    min.dispose();
    max.dispose();
    super.dispose();
  }

  bool isPreset(PeriodPreset preset) {
    final (s, e) = preset.range(DateTime.now());
    return draft.start == s && draft.endExclusive == e;
  }

  Future<void> pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5),
      initialDateRange: draft.start != null && draft.endExclusive != null
          ? DateTimeRange(
              start: draft.start!,
              end: draft.endExclusive!.subtract(const Duration(days: 1)),
            )
          : null,
    );
    if (picked == null) return;
    // The picker's end day is inclusive; the filter end is exclusive.
    final end = DateTime(picked.end.year, picked.end.month, picked.end.day + 1);
    setState(
      () => draft = draft.copyWith(
        start: () => picked.start,
        endExclusive: () => end,
      ),
    );
  }

  void apply() {
    final from = min.text.trim().isEmpty ? null : parseAmount(min.text);
    final to = max.text.trim().isEmpty ? null : parseAmount(max.text);
    if ((min.text.trim().isNotEmpty && from == null) ||
        (max.text.trim().isNotEmpty && to == null)) {
      setState(() => amountError = 'Введите сумму, например 1500 или 99,90');
      return;
    }
    if (from != null && to != null && from > to) {
      setState(() => amountError = '«От» больше, чем «до»');
      return;
    }
    Navigator.pop(
      context,
      draft.copyWith(minMinor: () => from, maxMinor: () => to),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = {
      for (final c in [
        ...BuiltInCategories.expense,
        ...BuiltInCategories.income,
        ...widget.categories,
      ])
        c.name: c,
    }.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Фильтры', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              Text('Период', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Всё время'),
                    selected: !draft.hasPeriod,
                    onSelected: (_) =>
                        setState(() => draft = draft.withoutPeriod()),
                  ),
                  for (final preset in PeriodPreset.values)
                    ChoiceChip(
                      label: Text(preset.title),
                      selected: isPreset(preset),
                      onSelected: (_) {
                        final (s, e) = preset.range(DateTime.now());
                        setState(
                          () => draft = draft.copyWith(
                            start: () => s,
                            endExclusive: () => e,
                          ),
                        );
                      },
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.date_range, size: 18),
                    label: Text(
                      draft.hasPeriod && !PeriodPreset.values.any(isPreset)
                          ? periodTitle(draft)
                          : 'Выбрать даты',
                    ),
                    onPressed: pickRange,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Сумма', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: min,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'От'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: max,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'До'),
                    ),
                  ),
                ],
              ),
              if (amountError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    amountError!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 20),
              Text('Категории', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in names)
                    FilterChip(
                      avatar: CategoryAvatar(
                        icon: c.icon,
                        emoji: c.emoji,
                        color: c.colorName,
                        size: 20,
                      ),
                      label: Text(c.name),
                      selected: draft.categories.contains(c.name),
                      onSelected: (on) => setState(
                        () => draft = draft.copyWith(
                          categories: on
                              ? {...draft.categories, c.name}
                              : ({...draft.categories}..remove(c.name)),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      TransactionFilter(
                        kind: draft.kind,
                        query: draft.query,
                        sort: draft.sort,
                      ),
                    ),
                    child: const Text('Сбросить'),
                  ),
                  FilledButton(
                    onPressed: apply,
                    child: const Text('Применить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A day of the list: date, income and expense totals, its transactions.
class DayPanel extends StatelessWidget {
  const DayPanel({
    super.key,
    required this.group,
    required this.tile,
    required this.currency,
  });
  final DayGroup group;
  final Widget Function(TransactionRecord) tile;
  final String currency;
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    return Panel(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    DateFormat('d MMMM y, EEE', 'ru').format(group.day),
                    style: style,
                  ),
                ),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      children: [
                        if (group.incomeMinor > 0)
                          Text(
                            '+${money(group.incomeMinor, currency)}',
                            style: style?.copyWith(color: Colors.teal),
                          ),
                        if (group.expenseMinor > 0)
                          Text(
                            '−${money(group.expenseMinor, currency)}',
                            style: style?.copyWith(color: Colors.deepOrange),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final item in group.items) tile(item),
        ],
      ),
    );
  }
}

/// A slice of an amount-sorted list; slices keep the page lazy.
class PlainPanel extends StatelessWidget {
  const PlainPanel({super.key, required this.items, required this.tile});
  final List<TransactionRecord> items;
  final Widget Function(TransactionRecord) tile;
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(children: [for (final item in items) tile(item)]),
  );
}
