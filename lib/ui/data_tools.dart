import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/backup.dart';
import '../domain/finance.dart';
import '../domain/statement_import.dart';
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
}

/// [androidMimeTypes] covers extensions Android cannot map to a MIME type:
/// its picker filters by MIME only, and stores e.g. `.ofx` as octet-stream.
Future<XFile?> pickFile(
  String label,
  List<String> extensions, {
  List<String> androidMimeTypes = const [],
}) => openFile(
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
      throw const FormatException('В файле нет операций');
    }
    var mapping = StatementImport.tbankMapping(table.first);
    var format = 'Т-Банк, CSV';
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
  if (result.rows.isEmpty) {
    throw FormatException(
      result.problems.isEmpty
          ? 'Операции не найдены'
          : 'Операции не найдены. ${result.problems.first}',
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
    return name.isEmpty ? 'Колонка ${index + 1}' : name;
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
        const DropdownMenuItem<int?>(value: null, child: Text('Нет')),
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
        title: const Text('Колонки выписки'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          const Text(
            'Формат банка не распознан. Укажите, где дата, сумма и описание.',
          ),
          const SizedBox(height: 20),
          column(
            'Дата',
            mapping.date,
            (v) => setState(() => mapping = mapping.copyWith(date: v)),
          ),
          const SizedBox(height: 12),
          column(
            'Сумма',
            mapping.amount,
            (v) => setState(() => mapping = mapping.copyWith(amount: v)),
          ),
          const SizedBox(height: 12),
          column(
            'Описание',
            mapping.description,
            (v) => setState(
              () => mapping = mapping.copyWith(description: () => v),
            ),
            optional: true,
          ),
          const SizedBox(height: 12),
          column(
            'Категория банка',
            mapping.category,
            (v) =>
                setState(() => mapping = mapping.copyWith(category: () => v)),
            optional: true,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Расходы указаны положительными числами'),
            value: mapping.invertSign,
            onChanged: (v) =>
                setState(() => mapping = mapping.copyWith(invertSign: v)),
          ),
          const SizedBox(height: 12),
          Text('Первые строки', style: theme.textTheme.titleMedium),
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
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: preview.rows.isEmpty
                ? null
                : () => Navigator.pop(context, mapping),
            child: const Text('Далее'),
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
            '${DateFormat('dd.MM.yyyy', 'ru').format(row.date)} · '
            '${row.description.isEmpty ? 'Без описания' : row.description}',
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
                title: Text(category.name),
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
        title: const Text('Импорт выписки'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${result.format} · операций: ${items.length}'),
                if (known > 0) Text('Уже импортированы раньше: $known'),
                if (duplicates > 0)
                  Text(
                    'Похожи на уже записанные: $duplicates — проверьте и отметьте вручную',
                  ),
                if (result.skipped > 0)
                  Text(
                    'Пропущены (отклонённые или нулевые): ${result.skipped}',
                  ),
                if (result.problems.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      'Не удалось прочитать строк: ${result.problems.length}',
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
                const Text(
                  'Переводы между своими счетами лучше снять: в приложении один общий баланс.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Выбрать все'),
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
                    row.description.isEmpty ? 'Без описания' : row.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(DateFormat('d MMM y', 'ru').format(row.date)),
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: CategoryAvatar(
                          icon: item.category.icon,
                          emoji: item.category.emoji,
                          color: item.category.colorName,
                          size: 20,
                        ),
                        label: Text(item.category.name),
                        onPressed: item.known
                            ? null
                            : () => chooseCategory(item),
                      ),
                      if (item.known)
                        const Text('уже импортирована')
                      else if (item.duplicate)
                        Text(
                          'возможный дубль',
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
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: selectedCount == 0
                ? null
                : () => Navigator.pop(context, [
                    for (final item in items)
                      if (item.selected)
                        StatementImport.toTransaction(item.row, item.category),
                  ]),
            child: Text('Импортировать ($selectedCount)'),
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
                  'Отложено записей с ошибками: ${entries.length}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Эти записи не удалось прочитать, поэтому они не участвуют в балансе. '
            'Остальные данные в порядке. Сохраните отчёт, чтобы восстановить их вручную.'
            '${fromServer ? ' Записи с сервера снова загрузит «Полная синхронизация» после обновления приложения.' : ''}',
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          const SizedBox(height: 8),
          for (final entry in entries.take(5))
            Text(
              '• ${entry.source == 'server' ? 'Сервер' : 'Устройство'} · '
              '${entry.sectionTitle}${entry.recordId == null ? '' : ' ${entry.recordId}'}: ${entry.reason}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          if (entries.length > 5)
            Text(
              'и ещё ${entries.length - 5}',
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
                label: const Text('Сохранить отчёт'),
              ),
              TextButton(onPressed: onClear, child: const Text('Очистить')),
            ],
          ),
        ],
      ),
    );
  }
}
