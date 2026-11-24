import 'package:file_selector/file_selector.dart';
import '../l10n/app_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/backup.dart';
import '../domain/finance.dart';
import '../domain/statement_import.dart';
import '../services/app_lock.dart';
import '../services/app_store.dart';
import 'design.dart';

/// Phones share the file, Web downloads it, desktops ask where to save.
Future<void> saveFile(
  BuildContext context,
  Uint8List bytes, {
  required String name,
  required String mimeType,
  required String label,
  required String extension,
}) async {
  final file = XFile.fromData(bytes, mimeType: mimeType, name: name);
  await AppLock.whileExternal(() async {
    if (kIsWeb) {
      await file.saveTo(name);
    } else if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [name],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          XTypeGroup(label: label, extensions: [extension]),
        ],
      );
      if (location != null) await file.saveTo(location.path);
    }
  });
}

/// [androidMimeTypes] covers extensions Android cannot map to a MIME type:
/// its picker filters by MIME only, and stores e.g. `.ofx` as octet-stream.
Future<XFile?> pickFile(
  String label,
  List<String> extensions, {
  List<String> androidMimeTypes = const [],
}) => AppLock.whileExternal(
  () => openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: label,
        extensions: extensions,
        mimeTypes: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? androidMimeTypes
            : null,
        // iOS needs UTIs; public.data keeps any statement selectable.
        uniformTypeIdentifiers: const ['public.data'],
      ),
    ],
  ),
);

Future<T?> _sizedDialog<T>(BuildContext context, Widget child) => showDialog<T>(
  context: context,
  builder: (context) => MediaQuery.sizeOf(context).width < 600
      ? Dialog.fullscreen(child: child)
      : Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
            child: child,
          ),
        ),
);

/// Reads a statement file and returns the transactions the user confirmed.
/// Throws FormatException with a user-facing message for unreadable files.
Future<List<TransactionRecord>?> runStatementImport(
  BuildContext context,
  AppStore store,
  XFile file,
) async {
  final text = StatementImport.decode(await file.readAsBytes());
  StatementParseResult result;
  if (StatementImport.looksLikeOfx(text)) {
    result = StatementImport.readOfx(text);
  } else {
    final table = StatementImport.parseCsv(text);
    if (table.length < 2) {
      throw FormatException(uiText('В файле нет операций'));
    }
    var mapping = StatementImport.tbankMapping(table.first);
    var format = uiText('Т-Банк, CSV');
    if (StatementImport.isBalanceExport(table.first)) {
      result = StatementImport.readBalanceCsv(table);
    } else {
      if (mapping == null) {
        if (!context.mounted) return null;
        mapping = await _sizedDialog<CsvMapping>(
          context,
          CsvMappingDialog(table: table),
        );
        if (mapping == null) return null;
        format = 'CSV';
      }
      result = StatementImport.readCsv(table, mapping, format: format);
    }
  }
  if (!context.mounted) return null;
  return _preview(context, store, result);
}

Future<List<TransactionRecord>?> _preview(
  BuildContext context,
  AppStore store,
  StatementParseResult result,
) async {
  if (result.rows.isEmpty) {
    throw FormatException(
      result.problems.isEmpty
          ? uiText('Операции не найдены')
          : uiText('Операции не найдены. {0}', [result.problems.first]),
    );
  }
  if (!context.mounted) return null;
  return _sizedDialog<List<TransactionRecord>>(
    context,
    StatementPreviewDialog(result: result, store: store),
  );
}

class CsvMappingDialog extends StatefulWidget {
  const CsvMappingDialog({super.key, required this.table});
  final List<List<String>> table;
  @override
  State<CsvMappingDialog> createState() => _CsvMappingDialogState();
}

class _CsvMappingDialogState extends State<CsvMappingDialog> {
  late CsvMapping mapping = StatementImport.guessMapping(widget.table.first);

  List<String> get header => widget.table.first;
  String columnName(int index) {
    final name = index < header.length ? header[index].trim() : '';
    return name.isEmpty ? uiText('Колонка {0}', [index + 1]) : name;
  }

  int get columns =>
      widget.table.fold(0, (max, row) => row.length > max ? row.length : max);

  Widget column(
    String label,
    int? value,
    ValueChanged<int?> changed, {
    bool optional = false,
  }) => DropdownButtonFormField<int?>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      if (optional)
        DropdownMenuItem<int?>(value: null, child: Text(uiText('Нет'))),
      for (var i = 0; i < columns; i++)
        DropdownMenuItem<int?>(
          value: i,
          child: Text(columnName(i), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: changed,
  );

  @override
  Widget build(BuildContext context) {
    final preview = StatementImport.readCsv(
      widget.table.take(6).toList(),
      mapping,
    );
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: Text(uiText('Колонки выписки')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(
            uiText(
              'Формат банка не распознан. Укажите, где дата, сумма и описание.',
            ),
          ),
          const SizedBox(height: 20),
          column(
            uiText('Дата'),
            mapping.date,
            (v) => setState(() => mapping = mapping.copyWith(date: v)),
          ),
          const SizedBox(height: 12),
          column(
            uiText('Сумма'),
            mapping.amount,
            (v) => setState(() => mapping = mapping.copyWith(amount: v)),
          ),
          const SizedBox(height: 12),
          column(
            uiText('Описание'),
            mapping.description,
            (v) => setState(
              () => mapping = mapping.copyWith(description: () => v),
            ),
            optional: true,
          ),
          const SizedBox(height: 12),
          column(
            uiText('Категория банка'),
            mapping.category,
            (v) =>
                setState(() => mapping = mapping.copyWith(category: () => v)),
            optional: true,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(uiText('Расходы указаны положительными числами')),
            value: mapping.invertSign,
            onChanged: (v) =>
                setState(() => mapping = mapping.copyWith(invertSign: v)),
          ),
          const SizedBox(height: 12),
          Text(uiText('Первые строки'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final row in preview.rows)
            _RowPreview(row: row, currency: 'RUB'),
          for (final problem in preview.problems)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                problem,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _Actions(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: preview.rows.isEmpty
                ? null
                : () => Navigator.pop(context, mapping),
            child: Text(uiText('Далее')),
          ),
        ],
      ),
    );
  }
}

class _RowPreview extends StatelessWidget {
  const _RowPreview({required this.row, required this.currency});
  final StatementRow row;
  final String currency;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '${localDateFormat('dd.MM.yyyy').format(row.date)} · '
            '${row.description.isEmpty ? uiText('Без описания') : row.description}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        _Amount(row: row, currency: currency),
      ],
    ),
  );
}

class _Amount extends StatelessWidget {
  const _Amount({required this.row, required this.currency});
  final StatementRow row;
  final String currency;
  @override
  Widget build(BuildContext context) {
    final income = row.kind == TransactionKind.income;
    // ListTile renders trailing text in a small label style; keep amounts
    // as readable as in the operations list.
    return Text(
      '${income ? '+' : '−'}${money(row.amountMinor, currency)}',
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: income ? Colors.teal : Colors.deepOrange,
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: children,
      ),
    ),
  );
}

class StatementPreviewDialog extends StatefulWidget {
  const StatementPreviewDialog({
    super.key,
    required this.result,
    required this.store,
  });
  final StatementParseResult result;
  final AppStore store;
  @override
  State<StatementPreviewDialog> createState() => _StatementPreviewDialogState();
}

class _PreviewItem {
  _PreviewItem(
    this.row,
    this.category, {
    required this.known,
    required this.duplicate,
  }) : selected = !known && !duplicate;
  final StatementRow row;
  CategoryRecord category;
  final bool known, duplicate;
  bool selected;
}

class _StatementPreviewDialogState extends State<StatementPreviewDialog> {
  late final List<_PreviewItem> items = [
    for (final row in widget.result.rows)
      _PreviewItem(
        row,
        StatementImport.suggestCategory(
          row,
          widget.store.categoriesForKind(row.kind),
        ),
        known: widget.store.knowsTransaction(
          StatementImport.transactionId(row),
        ),
        duplicate: StatementImport.likelyDuplicate(
          row,
          widget.store.transactions,
        ),
      ),
  ];

  int get selectedCount => items.where((i) => i.selected).length;
  Iterable<_PreviewItem> get selectable => items.where((i) => !i.known);

  Future<void> chooseCategory(_PreviewItem item) async {
    final choice = await showModalBottomSheet<CategoryRecord>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final category in widget.store.categoriesForKind(
              item.row.kind,
            ))
              ListTile(
                leading: CategoryAvatar(
                  icon: category.icon,
                  emoji: category.emoji,
                  color: category.colorName,
                  size: 36,
                ),
                title: Text(categoryTitle(category.name)),
                selected: category.name == item.category.name,
                onTap: () => Navigator.pop(context, category),
              ),
          ],
        ),
      ),
    );
    if (choice != null) setState(() => item.category = choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = widget.result;
    final known = items.where((i) => i.known).length;
    final duplicates = items.where((i) => i.duplicate && !i.known).length;
    final allSelected =
        selectable.isNotEmpty && selectable.every((i) => i.selected);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: Text(uiText('Импорт выписки')),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  uiText('{0} · операций: {1}', [result.format, items.length]),
                ),
                if (known > 0)
                  Text(uiText('Уже импортированы раньше: {0}', [known])),
                if (duplicates > 0)
                  Text(
                    uiText(
                      'Похожи на уже записанные: {0} — проверьте и отметьте вручную',
                      [duplicates],
                    ),
                  ),
                if (result.skipped > 0)
                  Text(
                    uiText('Пропущены (отклонённые или нулевые): {0}', [
                      result.skipped,
                    ]),
                  ),
                if (result.problems.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      uiText('Не удалось прочитать строк: {0}', [
                        result.problems.length,
                      ]),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    children: [
                      for (final problem in result.problems.take(20))
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(problem),
                        ),
                    ],
                  ),
                Text(
                  uiText(
                    'Переводы между своими счетами лучше снять: в приложении один общий баланс.',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(uiText('Выбрать все')),
                  value: allSelected,
                  onChanged: selectable.isEmpty
                      ? null
                      : (v) => setState(() {
                          for (final item in selectable) {
                            item.selected = v ?? false;
                          }
                        }),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final row = item.row;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: Checkbox(
                    value: item.selected,
                    onChanged: item.known
                        ? null
                        : (v) => setState(() => item.selected = v ?? false),
                  ),
                  title: Text(
                    row.description.isEmpty
                        ? uiText('Без описания')
                        : row.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(localDateFormat('d MMM y').format(row.date)),
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: CategoryAvatar(
                          icon: item.category.icon,
                          emoji: item.category.emoji,
                          color: item.category.colorName,
                          size: 20,
                        ),
                        label: Text(categoryTitle(item.category.name)),
                        onPressed: item.known || row.isBalanceAdjustment
                            ? null
                            : () => chooseCategory(item),
                      ),
                      if (item.known)
                        Text(uiText('уже импортирована'))
                      else if (item.duplicate)
                        Text(
                          uiText('возможный дубль'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                    ],
                  ),
                  trailing: _Amount(row: row, currency: widget.store.currency),
                  onTap: item.known
                      ? null
                      : () => setState(() => item.selected = !item.selected),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: _Actions(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: selectedCount == 0
                ? null
                : () => Navigator.pop(context, [
                    for (final item in items)
                      if (item.selected)
                        StatementImport.toTransaction(item.row, item.category),
                  ]),
            child: Text(uiText('Импортировать ({0})', [selectedCount])),
          ),
        ],
      ),
    );
  }
}

/// Records set aside from the device or the server, with save and clear.
class QuarantinePanel extends StatelessWidget {
  const QuarantinePanel({
    super.key,
    required this.entries,
    required this.onSave,
    required this.onClear,
  });
  final List<QuarantineEntry> entries;
  final VoidCallback onSave, onClear;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fromServer = entries.any((e) => e.source == 'server');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.report_problem_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  uiText('Отложено записей с ошибками: {0}', [entries.length]),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            uiText(
              'Эти записи не удалось прочитать, поэтому они не участвуют в балансе. Остальные данные в порядке. Сохраните отчёт, чтобы восстановить их вручную.{0}',
              [
                fromServer
                    ? uiText(
                        ' Записи с сервера снова загрузит «Полная синхронизация» после обновления приложения.',
                      )
                    : '',
              ],
            ),
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          const SizedBox(height: 8),
          for (final entry in entries.take(5))
            Text(
              '• ${entry.source == 'server' ? uiText('Сервер') : uiText('Устройство')} · '
              '${entry.sectionTitle}${entry.recordId == null ? '' : ' ${entry.recordId}'}: ${entry.reason}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          if (entries.length > 5)
            Text(
              uiText('и ещё {0}', [entries.length - 5]),
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: onSave,
                icon: const Icon(Icons.save_alt),
                label: Text(uiText('Сохранить отчёт')),
              ),
              TextButton(onPressed: onClear, child: Text(uiText('Очистить'))),
            ],
          ),
        ],
      ),
    );
  }
}

/// Backup restore preview: what each record would do, with the same
/// select-and-confirm flow as the statement import. Returns selected keys.
class BackupPreviewDialog extends StatefulWidget {
  const BackupPreviewDialog({
    super.key,
    required this.plan,
    required this.fileName,
    required this.currency,
  });
  final BackupPlan plan;
  final String fileName, currency;
  @override
  State<BackupPreviewDialog> createState() => _BackupPreviewDialogState();
}

class _BackupPreviewDialogState extends State<BackupPreviewDialog> {
  late final Set<String> selected = {
    for (final item in widget.plan.actionable) item.key,
  };

  static String actionTitle(BackupAction action) => switch (action) {
    BackupAction.add => uiText('Добавится'),
    BackupAction.update => uiText('Обновится'),
    BackupAction.delete => uiText('Удалится'),
    BackupAction.skip => uiText('Без изменений'),
  };

  int count(BackupAction action) =>
      widget.plan.items.where((i) => i.action == action).length;

  Widget tile(BackupPlanItem item) {
    final theme = Theme.of(context);
    final skip = item.action == BackupAction.skip;
    final record = item.record;
    String title;
    var details = '';
    Widget? leading;
    Widget? trailing;
    switch (record) {
      case TransactionRecord t:
        title = t.isBalanceAdjustment
            ? uiText('Корректировка баланса')
            : categoryTitle(t.categoryName);
        details =
            '${localDateFormat('d MMM y').format(t.date.toLocal())}'
            '${t.note.isEmpty ? '' : ' · ${t.note}'}';
        leading = CategoryAvatar(
          icon: t.isBalanceAdjustment ? 'tune' : t.categoryIcon,
          emoji: t.categoryEmoji,
          color: t.categoryColorName,
          size: 36,
        );
        final income = t.kind == TransactionKind.income;
        trailing = Text(
          '${income ? '+' : '−'}${money(t.amountMinor, widget.currency)}',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: income ? Colors.teal : Colors.deepOrange,
          ),
        );
      case CategoryRecord c:
        title = uiText('Категория «{0}»', [c.name]);
        details = c.kind == TransactionKind.income
            ? uiText('Доход')
            : uiText('Расход');
        leading = CategoryAvatar(
          icon: c.icon,
          emoji: c.emoji,
          color: c.colorName,
          size: 36,
        );
      case BudgetRecord b:
        title = uiText('Бюджет «{0}»', [categoryTitle(b.categoryName)]);
        details = localDateFormat('LLLL y').format(b.monthStart.toLocal());
        leading = CategoryAvatar(
          icon: b.categoryIcon,
          emoji: b.categoryEmoji,
          color: 'auto',
          size: 36,
        );
        trailing = Text(
          money(b.limitMinor, widget.currency),
          style: theme.textTheme.bodyLarge,
        );
      default:
        title = item.id;
    }
    final status = skip ? uiText(item.reason) : actionTitle(item.action);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: selected.contains(item.key),
            onChanged: skip
                ? null
                : (v) => setState(
                    () => v == true
                        ? selected.add(item.key)
                        : selected.remove(item.key),
                  ),
          ),
          ?leading,
        ],
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [status, if (details.isNotEmpty) details].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: item.action == BackupAction.delete
            ? TextStyle(color: theme.colorScheme.error)
            : null,
      ),
      trailing: trailing,
      onTap: skip
          ? null
          : () => setState(
              () => selected.contains(item.key)
                  ? selected.remove(item.key)
                  : selected.add(item.key),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final actionable = plan.actionable.toList();
    final allSelected =
        actionable.isNotEmpty &&
        actionable.every((i) => selected.contains(i.key));
    // Changes first, then what stays as it is.
    final items = [
      ...actionable,
      ...plan.items.where((i) => i.action == BackupAction.skip),
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: Text(uiText('Восстановление из копии')),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    for (final action in BackupAction.values)
                      if (count(action) > 0)
                        '${actionTitle(action).toLowerCase()}: ${count(action)}',
                  ].join(', '),
                ),
                if (plan.invalid > 0)
                  Text(
                    uiText('Не удалось прочитать записей: {0}', [plan.invalid]),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Text(
                  uiText(
                    'Отмеченные записи попадут на устройство и в синхронизацию. Более новые изменения на устройстве не затираются.',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(uiText('Выбрать все')),
                  value: allSelected,
                  onChanged: actionable.isEmpty
                      ? null
                      : (v) => setState(() {
                          for (final item in actionable) {
                            v == true
                                ? selected.add(item.key)
                                : selected.remove(item.key);
                          }
                        }),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) => tile(items[index]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _Actions(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(uiText('Отмена')),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(context, Set<String>.of(selected)),
            child: Text(uiText('Восстановить ({0})', [selected.length])),
          ),
        ],
      ),
    );
  }
}

Future<Set<String>?> showBackupPreview(
  BuildContext context, {
  required BackupPlan plan,
  required String fileName,
  required String currency,
}) => _sizedDialog<Set<String>>(
  context,
  BackupPreviewDialog(plan: plan, fileName: fileName, currency: currency),
);
