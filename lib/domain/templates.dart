import 'finance.dart';

/// A device-local preset for a new transaction: kind, category snapshot,
/// optional amount and note. Templates are preferences and never synced.
class TransactionTemplate {
  const TransactionTemplate({
    required this.id,
    required this.kindRawValue,
    required this.categoryName,
    this.amountMinor = 0,
    this.categoryIcon = 'circle.fill',
    this.categoryEmoji = '',
    this.categoryColorName = 'auto',
    this.note = '',
  });

  final String id, kindRawValue, categoryName;

  /// Zero leaves the amount for the user to enter.
  final int amountMinor;
  final String categoryIcon, categoryEmoji, categoryColorName, note;

  TransactionKind get kind => TransactionKind.parse(kindRawValue);
  String get title => note.isNotEmpty ? note : categoryName;

  /// Same preset regardless of id, used to avoid saving duplicates.
  String get signature =>
      '$kindRawValue|$categoryName|$amountMinor|${note.trim()}';

  /// An empty new transaction of [kind], e.g. from an app shortcut.
  factory TransactionTemplate.blank(TransactionKind kind) {
    final category = BuiltInCategories.forKind(kind.name).first;
    return TransactionTemplate.fromCategory('blank', kind, category);
  }

  factory TransactionTemplate.fromCategory(
    String id,
    TransactionKind kind,
    CategoryRecord category, {
    int amountMinor = 0,
    String note = '',
  }) => TransactionTemplate(
    id: id,
    kindRawValue: kind.name,
    categoryName: category.name,
    categoryIcon: category.icon,
    categoryEmoji: category.emoji,
    categoryColorName: category.colorName,
    amountMinor: amountMinor,
    note: note,
  );

  /// «Повторить»: everything except id and date.
  factory TransactionTemplate.fromTransaction(
    String id,
    TransactionRecord record,
  ) => TransactionTemplate(
    id: id,
    kindRawValue: record.kindRawValue,
    categoryName: record.categoryName,
    categoryIcon: record.categoryIcon,
    categoryEmoji: record.categoryEmoji,
    categoryColorName: record.categoryColorName,
    amountMinor: record.amountMinor,
    note: record.note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kindRawValue': kindRawValue,
    'categoryName': categoryName,
    'amountMinor': amountMinor,
    'categoryIcon': categoryIcon,
    'categoryEmoji': categoryEmoji,
    'categoryColorName': categoryColorName,
    'note': note,
  };

  factory TransactionTemplate.fromJson(Map<String, dynamic> json) {
    final amount = json['amountMinor'];
    final name = json['categoryName'];
    if (name is! String || name.isEmpty || amount is! int || amount < 0) {
      throw const FormatException('Invalid template');
    }
    return TransactionTemplate(
      id: json['id'] as String,
      kindRawValue: json['kindRawValue'] == 'income' ? 'income' : 'expense',
      categoryName: name,
      amountMinor: amount,
      categoryIcon: json['categoryIcon'] as String? ?? 'circle.fill',
      categoryEmoji: json['categoryEmoji'] as String? ?? '',
      categoryColorName: json['categoryColorName'] as String? ?? 'auto',
      note: json['note'] as String? ?? '',
    );
  }

  /// Transactions that repeat with the same kind, category, amount and note
  /// at least twice in the last 90 days, most frequent and recent first.
  /// Balance adjustments are not spending and never suggested.
  static List<TransactionTemplate> frequent(
    Iterable<TransactionRecord> items,
    DateTime now, {
    int limit = 3,
  }) {
    final since = now.subtract(const Duration(days: 90));
    final groups = <String, ({TransactionRecord latest, int count})>{};
    for (final item in items) {
      if (item.isBalanceAdjustment || item.date.isBefore(since)) continue;
      final key = TransactionTemplate.fromTransaction('', item).signature;
      final group = groups[key];
      groups[key] = (
        latest: group == null || item.date.isAfter(group.latest.date)
            ? item
            : group.latest,
        count: (group?.count ?? 0) + 1,
      );
    }
    final ranked = groups.entries.where((e) => e.value.count >= 2).toList()
      ..sort((a, b) {
        final byCount = b.value.count.compareTo(a.value.count);
        return byCount != 0
            ? byCount
            : b.value.latest.date.compareTo(a.value.latest.date);
      });
    return [
      for (final entry in ranked.take(limit))
        TransactionTemplate.fromTransaction(
          'frequent:${entry.key}',
          entry.value.latest,
        ),
    ];
  }
}
