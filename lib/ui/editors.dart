import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../domain/finance.dart';
import 'design.dart';

const _uuid = Uuid();
Future<T?> editDialog<T>(BuildContext context, Widget child) => showDialog<T>(
  context: context,
  builder: (_) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: child,
    ),
  ),
);

class TransactionEditor extends StatefulWidget {
  const TransactionEditor({super.key, this.existing, required this.categories});
  final TransactionRecord? existing;
  final List<CategoryRecord> categories;
  @override
  State<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends State<TransactionEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController amount, note;
  late DateTime date;
  late String kind;
  late CategoryRecord selected;
  List<CategoryRecord> get choices {
    final list = [
      ...BuiltInCategories.forKind(kind),
      ...widget.categories.where((c) => c.kindRawValue == kind),
    ];
    if (!list.any((c) => c.name == selected.name)) list.add(selected);
    return {for (final c in list) c.name: c}.values.toList();
  }

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    amount = TextEditingController(
      text: t == null ? '' : amountInput(t.amountMinor),
    );
    note = TextEditingController(text: t?.note ?? '');
    date = t?.date.toLocal() ?? DateTime.now();
    kind = t?.kindRawValue ?? 'expense';
    selected = t == null
        ? BuiltInCategories.expense.first
        : CategoryRecord(
            id: 'archived',
            name: t.categoryName,
            icon: t.categoryIcon,
            emoji: t.categoryEmoji,
            colorName: t.categoryColorName,
            kindRawValue: kind,
            createdAt: date,
            updatedAt: date,
          );
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
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
          Text(
            widget.existing == null ? 'Новая операция' : 'Изменить операцию',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'expense',
                label: Text('Расход'),
                icon: Icon(Icons.north_east),
              ),
              ButtonSegment(
                value: 'income',
                label: Text('Доход'),
                icon: Icon(Icons.south_west),
              ),
            ],
            selected: {kind},
            onSelectionChanged: widget.existing?.isBalanceAdjustment == true
                ? null
                : (s) => setState(() {
                    kind = s.first;
                    selected = BuiltInCategories.forKind(kind).first;
                  }),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Сумма',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              final m = parseAmount(v ?? '');
              return m == null || m <= 0
                  ? 'Введите положительную сумму, до 2 знаков после запятой'
                  : null;
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: selected.name,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Категория',
              border: OutlineInputBorder(),
            ),
            items: choices
                .map(
                  (c) => DropdownMenuItem(
                    value: c.name,
                    child: Row(
                      children: [
                        CategoryAvatar(
                          icon: c.icon,
                          emoji: c.emoji,
                          color: c.colorName,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(c.name, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
            onChanged: widget.existing?.isBalanceAdjustment == true
                ? null
                : (v) => setState(
                    () => selected = choices.firstWhere((c) => c.name == v),
                  ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: Text(DateFormat('d MMMM y, HH:mm', 'ru').format(date)),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: date,
                firstDate: DateTime(1900),
                lastDate: DateTime(2200),
              );
              if (d == null || !context.mounted) return;
              final time = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(date),
              );
              if (time != null && mounted) {
                setState(
                  () => date = DateTime(
                    d.year,
                    d.month,
                    d.day,
                    time.hour,
                    time.minute,
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: note,
            maxLines: 3,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: 'Заметка',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  if (!form.currentState!.validate()) return;
                  final now = DateTime.now();
                  Navigator.pop(
                    context,
                    TransactionRecord(
                      id: widget.existing?.id ?? _uuid.v4(),
                      amountMinor: parseAmount(amount.text)!,
                      date: date,
                      note: note.text.trim(),
                      categoryName: selected.name,
                      categoryIcon: selected.icon,
                      categoryEmoji: selected.emoji,
                      categoryColorName: selected.colorName,
                      kindRawValue: kind,
                      isBalanceAdjustment:
                          widget.existing?.isBalanceAdjustment ?? false,
                      updatedAt: now,
                    ),
                  );
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class CategoryEditor extends StatefulWidget {
  const CategoryEditor({super.key, this.existing, required this.categories});
  final CategoryRecord? existing;
  final List<CategoryRecord> categories;
  @override
  State<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<CategoryEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, emoji;
  late String kind, icon, color;
  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    name = TextEditingController(text: c?.name ?? '');
    emoji = TextEditingController(text: c?.emoji ?? '');
    kind = c?.kindRawValue ?? 'expense';
    icon = c?.icon ?? 'star.fill';
    color = c?.colorName ?? 'indigo';
  }

  @override
  void dispose() {
    name.dispose();
    emoji.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.existing == null ? 'Новая категория' : 'Изменить категорию',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: name,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Название',
              border: OutlineInputBorder(),
            ),
            validator: (s) {
              final n = (s ?? '').trim().toLowerCase();
              if (n.isEmpty) return 'Введите название';
              if ([
                ...BuiltInCategories.expense,
                ...BuiltInCategories.income,
                ...widget.categories,
              ].any(
                (c) => c.id != widget.existing?.id && c.name.toLowerCase() == n,
              )) {
                return 'Категория с таким названием уже есть';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('Расход')),
              ButtonSegment(value: 'income', label: Text('Доход')),
            ],
            selected: {kind},
            onSelectionChanged: widget.existing != null
                ? null
                : (s) => setState(() => kind = s.first),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              CategoryAvatar(
                icon: icon,
                emoji: emoji.text,
                color: color,
                size: 60,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: emoji,
                  decoration: InputDecoration(
                    labelText: 'Свой эмодзи',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Убрать эмодзи',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => emoji.clear()),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  maxLength: 8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: CategoryDesignOptions.emojis
                .map(
                  (e) => IconButton(
                    onPressed: () => setState(() => emoji.text = e),
                    tooltip: e,
                    icon: Text(e, style: const TextStyle(fontSize: 23)),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
          Text('Значок', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: CategoryDesignOptions.icons
                .map(
                  (i) => IconButton.filledTonal(
                    isSelected: i == icon && emoji.text.isEmpty,
                    onPressed: () => setState(() {
                      icon = i;
                      emoji.clear();
                    }),
                    tooltip: i,
                    icon: Icon(categoryIcons[i] ?? Icons.category_outlined),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 20),
          Text('Цвет', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: CategoryDesignOptions.colors
                .map(
                  (c) => IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: categoryColors[c],
                    ),
                    tooltip: c,
                    onPressed: () => setState(() => color = c),
                    icon: Icon(
                      c == color ? Icons.check : Icons.circle,
                      color: c == color ? Colors.white : Colors.transparent,
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  if (!form.currentState!.validate()) return;
                  final now = DateTime.now();
                  Navigator.pop(
                    context,
                    CategoryRecord(
                      id: widget.existing?.id ?? _uuid.v4(),
                      name: name.text.trim(),
                      icon: icon,
                      emoji: emoji.text.characters.take(1).toString(),
                      colorName: color,
                      kindRawValue: kind,
                      createdAt: widget.existing?.createdAt ?? now,
                      updatedAt: now,
                    ),
                  );
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class BudgetEditor extends StatefulWidget {
  const BudgetEditor({
    super.key,
    this.existing,
    required this.categories,
    required this.month,
  });
  final BudgetRecord? existing;
  final List<CategoryRecord> categories;
  final DateTime month;
  @override
  State<BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<BudgetEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController amount;
  late CategoryRecord selected;
  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: widget.existing == null
          ? ''
          : amountInput(widget.existing!.limitMinor),
    );
    selected =
        widget.categories
            .where((c) => c.name == widget.existing?.categoryName)
            .firstOrNull ??
        widget.categories.first;
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
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
          Text(
            'Лимит на ${DateFormat('LLLL y', 'ru').format(widget.month)}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          DropdownButtonFormField<String>(
            initialValue: selected.name,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Категория',
              border: OutlineInputBorder(),
            ),
            items: widget.categories
                .map(
                  (c) => DropdownMenuItem(value: c.name, child: Text(c.name)),
                )
                .toList(),
            onChanged: (n) => setState(
              () => selected = widget.categories.firstWhere((c) => c.name == n),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Месячный лимит',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                parseAmount(v ?? '') == null || parseAmount(v ?? '')! <= 0
                ? 'Введите положительный лимит'
                : null,
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  if (!form.currentState!.validate()) return;
                  Navigator.pop(
                    context,
                    BudgetRecord(
                      id: widget.existing?.id ?? _uuid.v4(),
                      categoryName: selected.name,
                      categoryIcon: selected.icon,
                      categoryEmoji: selected.emoji,
                      limitMinor: parseAmount(amount.text)!,
                      monthStart: widget.month,
                      updatedAt: DateTime.now(),
                    ),
                  );
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<bool> confirmDelete(
  BuildContext context,
  String title, {
  String message =
      'Это действие будет синхронизировано с другими устройствами.',
  String action = 'Удалить',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
