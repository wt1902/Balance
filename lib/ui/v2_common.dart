import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/finance.dart';
import '../domain/records.dart';
import '../services/app_store.dart';
import 'design.dart';

/// Runs an action with a snackbar for its error or [success].
typedef Runner =
    Future<void> Function(Future<void> Function() action, {String? success});

/// Codes offered in currency pickers in addition to those already in use.
const commonCurrencies = [
  'RUB',
  'EUR',
  'USD',
  'SEK',
  'GBP',
  'CHF',
  'CNY',
  'JPY',
  'KZT',
  'BYN',
  'UAH',
  'TRY',
  'GEL',
  'AMD',
  'AED',
  'THB',
];

/// Common codes plus those in use, sorted; [extra] is always included.
List<String> currencyOptions(AppStore store, [String? extra]) =>
    {...commonCurrencies, ...store.knownCurrencies, ?extra}.toList()..sort();

/// The category-style icon of an account kind.
String accountIcon(AccountKind kind) => switch (kind) {
  AccountKind.cash => 'banknote.fill',
  AccountKind.card => 'creditcard.fill',
  AccountKind.deposit => 'chart.line.uptrend.xyaxis',
  AccountKind.other => 'bag.fill',
};

/// Colors offered for accounts and goals.
const recordColors = [
  'blue',
  'green',
  'teal',
  'orange',
  'red',
  'purple',
  'indigo',
  'pink',
  'sky',
  'gold',
  'brown',
  'slate',
];

String dayTitle(DateTime date) =>
    DateFormat('d MMMM y', 'ru').format(date.toLocal());

/// `+1 234,00 ₽` / `−1 234,00 ₽`.
String signedMoney(int minor, String currency) =>
    '${minor < 0 ? '−' : ''}${money(minor.abs(), currency)}';

/// A small arrow between two texts (the bundled font has no `→`).
InlineSpan arrowSpan(BuildContext context, {Color? color}) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Icon(
      Icons.arrow_forward,
      size: 14,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      semanticLabel: 'на',
    ),
  ),
);

/// The «по умолчанию» choice of a currency picker next to an account.
String defaultCurrencyLabel(AppStore store, String? accountId) =>
    accountId == null
    ? 'Базовая (${store.baseCurrency})'
    : 'Как у счёта (${store.accountCurrency(accountId)})';

String accountName(AppStore store, String? id) =>
    id == null ? 'Без счёта' : store.account(id)?.name ?? 'Удалённый счёт';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        ?action,
      ],
    ),
  );
}

/// «Нет курса USD→RUB»: such amounts are left out of totals (§2).
class MissingRatesNotice extends StatelessWidget {
  const MissingRatesNotice({
    super.key,
    required this.pairs,
    required this.onAddRate,
  });
  final Set<String> pairs;
  final void Function(String from, String to) onAddRate;
  @override
  Widget build(BuildContext context) {
    if (pairs.isEmpty) return const SizedBox.shrink();
    // `USD/RUB`: the bundled font has no arrow glyph, and Web loads no
    // fallback fonts.
    final sorted = [for (final p in pairs) p.replaceAll('→', '/')]..sort();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Panel(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.currency_exchange, color: scheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Нет курса ${sorted.join(', ')}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text('Такие суммы не входят в общие итоги.'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final pair in sorted)
                        TextButton.icon(
                          onPressed: () {
                            final parts = pair.split('/');
                            onAddRate(parts.first, parts.last);
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: Text('Курс $pair'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A day picked in a dialog, keeping the time of [initial].
Future<DateTime?> pickDay(
  BuildContext context,
  DateTime initial, {
  DateTime? first,
}) async {
  final local = initial.toLocal();
  final day = await showDatePicker(
    context: context,
    initialDate: local,
    firstDate: first ?? DateTime(1900),
    lastDate: DateTime(2200),
  );
  if (day == null) return null;
  return DateTime(
    day.year,
    day.month,
    day.day,
    local.hour,
    local.minute,
    local.second,
  );
}

/// Tags of an operation (§6): chips, a field for new ones and suggestions.
class TagsField extends StatefulWidget {
  const TagsField({
    super.key,
    required this.tags,
    required this.onChanged,
    this.suggestions = const [],
  });
  final List<String> tags;
  final List<String> suggestions;
  final ValueChanged<List<String>> onChanged;
  @override
  State<TagsField> createState() => _TagsFieldState();
}

class _TagsFieldState extends State<TagsField> {
  final controller = TextEditingController();
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  bool _has(String tag) =>
      widget.tags.any((t) => t.toLowerCase() == tag.toLowerCase());

  void add(String raw) {
    final next = [...widget.tags];
    for (final part in raw.split(',')) {
      final tag = part.trim();
      if (tag.isEmpty ||
          next.any((t) => t.toLowerCase() == tag.toLowerCase())) {
        continue;
      }
      next.add(tag);
    }
    try {
      final valid = TagRules.validate(next);
      setState(() => error = null);
      controller.clear();
      widget.onChanged(valid);
    } on ArgumentError catch (e) {
      setState(() => error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.suggestions
        .where((t) => !_has(t))
        .take(8)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          maxLength: TagRules.maxLength,
          decoration: InputDecoration(
            labelText: 'Теги',
            hintText: 'Например: отпуск',
            border: const OutlineInputBorder(),
            errorText: error,
            counterText: '',
            suffixIcon: IconButton(
              tooltip: 'Добавить тег',
              icon: const Icon(Icons.add),
              onPressed: () => add(controller.text),
            ),
          ),
          onChanged: (s) {
            if (s.contains(',')) add(s);
          },
          onSubmitted: add,
        ),
        if (widget.tags.isNotEmpty || suggestions.isNotEmpty)
          const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in widget.tags)
              InputChip(
                label: Text('#$tag'),
                onDeleted: () => widget.onChanged([
                  for (final t in widget.tags)
                    if (t != tag) t,
                ]),
                deleteButtonTooltipMessage: 'Убрать тег $tag',
              ),
            for (final tag in suggestions)
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: Text(tag),
                onPressed: () => add(tag),
              ),
          ],
        ),
      ],
    );
  }
}

/// Dialog buttons shared by the editors.
class EditorActions extends StatelessWidget {
  const EditorActions({super.key, required this.onSave, this.extra});
  final VoidCallback onSave;
  final Widget? extra;
  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    spacing: 8,
    runSpacing: 8,
    children: [
      ?extra,
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: onSave, child: const Text('Сохранить')),
    ],
  );
}

class ColorChoice extends StatelessWidget {
  const ColorChoice({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final c in recordColors)
        IconButton(
          style: IconButton.styleFrom(backgroundColor: categoryColors[c]),
          tooltip: c,
          onPressed: () => onChanged(c),
          icon: Icon(
            c == value ? Icons.check : Icons.circle,
            color: c == value ? Colors.white : Colors.transparent,
          ),
        ),
    ],
  );
}

/// A tappable date row with an optional clear button.
class DateRow extends StatelessWidget {
  const DateRow({
    super.key,
    required this.label,
    required this.value,
    required this.onPick,
    this.onClear,
    this.emptyText = 'Не задана',
  });
  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final String emptyText;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.calendar_today_outlined),
    title: Text(label),
    subtitle: Text(value == null ? emptyText : dayTitle(value!)),
    onTap: onPick,
    trailing: value != null && onClear != null
        ? IconButton(
            tooltip: 'Очистить: $label',
            icon: const Icon(Icons.close),
            onPressed: onClear,
          )
        : const Icon(Icons.edit_outlined),
  );
}

/// A currency dropdown; [nullLabel] adds a «по умолчанию» choice.
class CurrencyField extends StatelessWidget {
  const CurrencyField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.label = 'Валюта',
    this.nullLabel,
    this.enabled = true,
  });
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final String label;
  final String? nullLabel;
  final bool enabled;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String?>(
    key: ValueKey('currency-$label-$value-$nullLabel'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    items: [
      if (nullLabel != null)
        DropdownMenuItem<String?>(
          value: null,
          child: Text(nullLabel!, overflow: TextOverflow.ellipsis),
        ),
      for (final code in {...options, ?value})
        DropdownMenuItem<String?>(value: code, child: Text(code)),
    ],
    onChanged: enabled ? onChanged : null,
  );
}

/// An account dropdown: «Без счёта» ([noneLabel]) plus [accounts]; an
/// archived or deleted current value stays selectable.
class AccountField extends StatelessWidget {
  const AccountField({
    super.key,
    required this.store,
    required this.value,
    required this.onChanged,
    this.label = 'Счёт',
    this.noneLabel = 'Без счёта',
    this.allowNone = true,
    this.exclude,
  });
  final AppStore store;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String label, noneLabel;
  final bool allowNone;
  final String? exclude;
  @override
  Widget build(BuildContext context) {
    final accounts = [
      for (final a in store.activeAccounts)
        if (a.id != exclude) a,
    ];
    final current = value;
    final missing = current != null && !accounts.any((a) => a.id == current);
    return DropdownButtonFormField<String?>(
      key: ValueKey('account-$label-$value'),
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      validator: allowNone ? null : (v) => v == null ? 'Выберите счёт' : null,
      items: [
        if (allowNone)
          DropdownMenuItem<String?>(value: null, child: Text(noneLabel)),
        for (final a in accounts)
          DropdownMenuItem<String?>(
            value: a.id,
            child: Text(
              '${a.name} · ${store.accountCurrency(a.id)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (missing)
          DropdownMenuItem<String?>(
            value: current,
            child: Text(
              store.account(current) == null
                  ? 'Удалённый счёт'
                  : '${store.account(current)!.name} (в архиве)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
