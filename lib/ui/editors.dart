import 'package:flutter/foundation.dart';
import '../l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../domain/finance.dart';
import '../domain/pdf_receipt.dart';
import '../domain/receipt.dart';
import '../domain/templates.dart';
import '../services/app_store.dart';
import '../services/pdf_receipt_reader.dart';
import 'data_tools.dart' show pickFile;
import 'design.dart';
import 'pdf_receipt_preview.dart';
import 'receipt_scanner.dart';
import 'v2_common.dart';

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
  const TransactionEditor({
    super.key,
    this.existing,
    this.draft,
    required this.categories,
    this.store,
    this.attachments,
  });
  final TransactionRecord? existing;

  /// Accounts, currencies and known tags (contract v2); without it the
  /// editor keeps those fields of [existing] unchanged.
  final AppStore? store;

  /// Attachments of [existing], shown under the form.
  final Widget? attachments;

  /// Prefills a new transaction (repeat, template, app shortcut).
  final TransactionTemplate? draft;
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
  late String? accountId = widget.existing?.accountId;
  late String? currency = widget.existing?.currency;
  late List<String> tags = widget.existing?.tags ?? const [];
  bool _scannedReceipt = false;
  bool _readingPdf = false;
  String? _pdfError;
  String? _importedPositions;

  bool get _isNewExpense => widget.existing == null && kind == 'expense';

  bool get _canScanReceipt =>
      _isNewExpense &&
      _importedPositions == null &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _scanReceipt() async {
    FocusScope.of(context).unfocus();
    final receipt = await Navigator.of(
      context,
    ).push<Receipt>(MaterialPageRoute(builder: (_) => const ReceiptScanner()));
    if (!mounted || receipt == null) return;
    setState(() {
      amount.text = amountInput(receipt.amountMinor);
      date = receipt.date;
      currency = 'RUB';
      _scannedReceipt = true;
    });
  }

  Future<void> _importPdfReceipt() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _readingPdf = true;
      _pdfError = null;
    });
    try {
      final file = await pickFile(
        uiText('Электронный чек PDF'),
        const ['pdf'],
        androidMimeTypes: const ['application/pdf'],
      );
      if (!mounted || file == null) return;
      final receipt = await readPdfReceipt(file);
      if (!mounted ||
          !_isNewExpense ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final confirmed = await Navigator.of(context).push<PdfReceipt>(
        MaterialPageRoute(builder: (_) => PdfReceiptPreview(receipt: receipt)),
      );
      if (!mounted || confirmed == null) return;

      var previous = note.text.trim();
      final imported = _importedPositions;
      if (imported != null && previous.endsWith(imported)) {
        previous = previous
            .substring(0, previous.length - imported.length)
            .trimRight();
      }
      final detail = confirmed.note;
      final combined = previous.isEmpty ? detail : '$previous\n\n$detail';
      if (combined.characters.length > 4000) {
        throw FormatException(
          uiText(
            'Позиции и заметка превышают 4000 символов. Сократите заметку или уточните список позиций.',
          ),
        );
      }
      setState(() {
        amount.text = amountInput(confirmed.total!);
        date = confirmed.date ?? date;
        currency = 'RUB';
        note.text = combined;
        _importedPositions = detail;
        _scannedReceipt = true;
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _pdfError = uiText(error.message));
    } catch (_) {
      if (mounted) {
        setState(() => _pdfError = uiText('Не удалось прочитать PDF-чек.'));
      }
    } finally {
      if (mounted) setState(() => _readingPdf = false);
    }
  }

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
    final d = widget.draft;
    final amountMinor = t?.amountMinor ?? d?.amountMinor ?? 0;
    amount = TextEditingController(
      text: amountMinor > 0 ? amountInput(amountMinor) : '',
    );
    note = TextEditingController(text: t?.note ?? d?.note ?? '');
    date = t?.date.toLocal() ?? DateTime.now();
    kind = t?.kindRawValue ?? d?.kindRawValue ?? 'expense';
    selected = t != null
        ? CategoryRecord(
            id: 'archived',
            name: t.categoryName,
            icon: t.categoryIcon,
            emoji: t.categoryEmoji,
            colorName: t.categoryColorName,
            kindRawValue: kind,
            createdAt: date,
            updatedAt: date,
          )
        : d != null
        ? CategoryRecord(
            id: 'draft',
            name: d.categoryName,
            icon: d.categoryIcon,
            emoji: d.categoryEmoji,
            colorName: d.categoryColorName,
            kindRawValue: kind,
            createdAt: date,
            updatedAt: date,
          )
        : BuiltInCategories.expense.first;
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
            _scannedReceipt
                ? uiText('Предпросмотр операции')
                : widget.existing == null
                ? uiText('Новая операция')
                : uiText('Изменить операцию'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (_scannedReceipt) ...[
            const SizedBox(height: 8),
            Text(uiText('Проверьте данные чека и выберите категорию и счёт.')),
          ],
          const SizedBox(height: 24),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'expense',
                label: Text(uiText('Расход')),
                icon: Icon(Icons.north_east),
              ),
              ButtonSegment(
                value: 'income',
                label: Text(uiText('Доход')),
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
          if (_canScanReceipt) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _readingPdf ? null : _scanReceipt,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(
                _scannedReceipt
                    ? uiText('Сканировать снова')
                    : uiText('Сканировать чек'),
              ),
            ),
          ],
          if (_isNewExpense) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _readingPdf ? null : _importPdfReceipt,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(
                _readingPdf
                    ? uiText('Читаем чек…')
                    : uiText('Импортировать PDF-чек'),
              ),
            ),
            if (_pdfError case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
          const SizedBox(height: 20),
          TextFormField(
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: uiText('Сумма'),
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              final m = parseAmount(v ?? '');
              return m == null || m <= 0
                  ? uiText(
                      'Введите положительную сумму, до 2 знаков после запятой',
                    )
                  : null;
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: selected.name,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: uiText('Категория'),
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
                          child: Text(
                            categoryTitle(c.name),
                            overflow: TextOverflow.ellipsis,
                          ),
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
          if (widget.store case final store?) ...[
            const SizedBox(height: 16),
            AccountField(
              store: store,
              value: accountId,
              onChanged: (v) => setState(() => accountId = v),
            ),
            const SizedBox(height: 16),
            CurrencyField(
              value: currency,
              options: currencyOptions(store),
              nullLabel: defaultCurrencyLabel(store, accountId),
              onChanged: (v) => setState(() => currency = v),
            ),
          ],
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: Text(localDateFormat('d MMMM y, HH:mm').format(date)),
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
            decoration: InputDecoration(
              labelText: uiText('Заметка'),
              border: OutlineInputBorder(),
            ),
          ),
          if (widget.store case final store?) ...[
            const SizedBox(height: 4),
            TagsField(
              tags: tags,
              suggestions: store.knownTags,
              onChanged: (t) => setState(() => tags = t),
            ),
          ],
          if (widget.attachments case final attachments?) ...[
            const SizedBox(height: 16),
            attachments,
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(uiText('Отмена')),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  if (!form.currentState!.validate()) return;
                  final now = DateTime.now();
                  final existing = widget.existing;
                  // Editing keeps fields this form does not show, including
                  // payload fields of newer clients (contract v2 §0.2).
                  Navigator.pop(
                    context,
                    existing?.copyWith(
                          amountMinor: parseAmount(amount.text)!,
                          date: date,
                          note: note.text.trim(),
                          categoryName: selected.name,
                          categoryIcon: selected.icon,
                          categoryEmoji: selected.emoji,
                          categoryColorName: selected.colorName,
                          kindRawValue: kind,
                          accountId: accountId,
                          currency: currency,
                          tags: tags,
                          updatedAt: now,
                        ) ??
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
                          isBalanceAdjustment: false,
                          accountId: accountId,
                          currency: currency,
                          tags: tags,
                          updatedAt: now,
                        ),
                  );
                },
                child: Text(uiText('Сохранить')),
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
            widget.existing == null
                ? uiText('Новая категория')
                : uiText('Изменить категорию'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: name,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: uiText('Название'),
              border: OutlineInputBorder(),
            ),
            validator: (s) {
              final n = (s ?? '').trim().toLowerCase();
              if (n.isEmpty) return uiText('Введите название');
              if ([
                ...BuiltInCategories.expense,
                ...BuiltInCategories.income,
                ...widget.categories,
              ].any(
                (c) => c.id != widget.existing?.id && c.name.toLowerCase() == n,
              )) {
                return uiText('Категория с таким названием уже есть');
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'expense', label: Text(uiText('Расход'))),
              ButtonSegment(value: 'income', label: Text(uiText('Доход'))),
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
                    labelText: uiText('Свой эмодзи'),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: uiText('Убрать эмодзи'),
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
          Text(uiText('Значок'), style: Theme.of(context).textTheme.titleSmall),
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
          Text(uiText('Цвет'), style: Theme.of(context).textTheme.titleSmall),
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
                child: Text(uiText('Отмена')),
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
                child: Text(uiText('Сохранить')),
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
            uiText('Лимит на {0}', [
              localDateFormat('LLLL y').format(widget.month),
            ]),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          DropdownButtonFormField<String>(
            initialValue: selected.name,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: uiText('Категория'),
              border: OutlineInputBorder(),
            ),
            items: widget.categories
                .map(
                  (c) => DropdownMenuItem(
                    value: c.name,
                    child: Text(categoryTitle(c.name)),
                  ),
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
            decoration: InputDecoration(
              labelText: uiText('Месячный лимит'),
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                parseAmount(v ?? '') == null || parseAmount(v ?? '')! <= 0
                ? uiText('Введите положительный лимит')
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
                child: Text(uiText('Отмена')),
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
                child: Text(uiText('Сохранить')),
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
        content: Text(uiText(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(uiText(action)),
          ),
        ],
      ),
    ) ??
    false;
