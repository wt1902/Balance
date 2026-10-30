/// Finance values use hundredths of a currency unit internally. JSON retains
/// the existing iOS / Android / Go synchronization protocol.
enum TransactionKind {
  expense,
  income;

  String get title => this == income ? 'Доход' : 'Расход';
  static TransactionKind parse(String value) =>
      value == 'income' ? income : expense;
}

int moneyToMinor(num value) {
  if (!value.isFinite) throw const FormatException('Invalid money amount');
  return (value * 100).round();
}

/// Parse user-entered amounts without passing through binary floating point.
/// An empty value, exponent, sign or more than two decimal places is rejected.
int parseMoney(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(normalized)) {
    throw const FormatException(
      'Введите положительную сумму, максимум 2 знака после запятой',
    );
  }
  final parts = normalized.split('.');
  return int.parse(parts[0]) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
}

String formatMinor(int value) {
  final absolute = value.abs();
  return '${value < 0 ? '-' : ''}${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
}

DateTime _date(dynamic value) => DateTime.parse(value as String);
String _timestamp(DateTime value) => value.toUtc().toIso8601String();

class TransactionRecord {
  final String id;
  final int amountMinor;
  final DateTime date;
  final String note,
      categoryName,
      categoryIcon,
      categoryEmoji,
      categoryColorName;
  final bool isBalanceAdjustment;
  final String kindRawValue;
  final DateTime updatedAt;

  const TransactionRecord({
    required this.id,
    required this.amountMinor,
    required this.date,
    required this.categoryName,
    required this.updatedAt,
    this.note = '',
    this.categoryIcon = 'circle.fill',
    this.categoryEmoji = '',
    this.categoryColorName = 'auto',
    this.isBalanceAdjustment = false,
    this.kindRawValue = 'expense',
  });

  double get amount => amountMinor / 100;
  TransactionKind get kind => TransactionKind.parse(kindRawValue);
  Map<String, dynamic> payload() => {
    'amount': amount,
    'date': _timestamp(date),
    'note': note,
    'categoryName': categoryName,
    'categoryIcon': categoryIcon,
    'categoryEmoji': categoryEmoji,
    'categoryColorName': categoryColorName,
    'isBalanceAdjustment': isBalanceAdjustment,
    'kindRawValue': kindRawValue,
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'updatedAt': _timestamp(updatedAt),
    ...payload(),
    'amountMinor': amountMinor,
  };
  factory TransactionRecord.fromJson(Map<String, dynamic> json) =>
      TransactionRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      ).copyWith(amountMinor: json['amountMinor'] as int?);
  factory TransactionRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => TransactionRecord(
    id: id,
    updatedAt: updatedAt,
    amountMinor: moneyToMinor(payload['amount'] as num),
    date: _date(payload['date']),
    categoryName: payload['categoryName'] as String,
    note: payload['note'] as String? ?? '',
    categoryIcon: payload['categoryIcon'] as String? ?? 'circle.fill',
    categoryEmoji: payload['categoryEmoji'] as String? ?? '',
    categoryColorName: payload['categoryColorName'] as String? ?? 'auto',
    isBalanceAdjustment: payload['isBalanceAdjustment'] as bool? ?? false,
    kindRawValue: payload['kindRawValue'] as String? ?? 'expense',
  );
  TransactionRecord copyWith({
    String? id,
    int? amountMinor,
    DateTime? date,
    String? note,
    String? categoryName,
    String? categoryIcon,
    String? categoryEmoji,
    String? categoryColorName,
    bool? isBalanceAdjustment,
    String? kindRawValue,
    DateTime? updatedAt,
  }) => TransactionRecord(
    id: id ?? this.id,
    amountMinor: amountMinor ?? this.amountMinor,
    date: date ?? this.date,
    updatedAt: updatedAt ?? this.updatedAt,
    note: note ?? this.note,
    categoryName: categoryName ?? this.categoryName,
    categoryIcon: categoryIcon ?? this.categoryIcon,
    categoryEmoji: categoryEmoji ?? this.categoryEmoji,
    categoryColorName: categoryColorName ?? this.categoryColorName,
    isBalanceAdjustment: isBalanceAdjustment ?? this.isBalanceAdjustment,
    kindRawValue: kindRawValue ?? this.kindRawValue,
  );
}

class CategoryRecord {
  final String id, name, icon, emoji, colorName, kindRawValue;
  final DateTime createdAt, updatedAt;
  const CategoryRecord({
    required this.id,
    required this.name,
    required this.icon,
    required this.colorName,
    required this.createdAt,
    required this.updatedAt,
    this.emoji = '',
    this.kindRawValue = 'expense',
  });
  TransactionKind get kind => TransactionKind.parse(kindRawValue);
  Map<String, dynamic> payload() => {
    'name': name,
    'icon': icon,
    'emoji': emoji,
    'colorName': colorName,
    'kindRawValue': kindRawValue,
    'createdAt': _timestamp(createdAt),
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'updatedAt': _timestamp(updatedAt),
    ...payload(),
  };
  factory CategoryRecord.fromJson(Map<String, dynamic> json) =>
      CategoryRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );
  factory CategoryRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => CategoryRecord(
    id: id,
    updatedAt: updatedAt,
    name: payload['name'] as String,
    icon: payload['icon'] as String? ?? 'star.fill',
    emoji: payload['emoji'] as String? ?? '',
    colorName: payload['colorName'] as String? ?? 'indigo',
    kindRawValue: payload['kindRawValue'] as String? ?? 'expense',
    createdAt: payload['createdAt'] == null
        ? updatedAt
        : _date(payload['createdAt']),
  );
  CategoryRecord copyWith({
    String? id,
    String? name,
    String? icon,
    String? emoji,
    String? colorName,
    String? kindRawValue,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => CategoryRecord(
    id: id ?? this.id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    emoji: emoji ?? this.emoji,
    colorName: colorName ?? this.colorName,
    kindRawValue: kindRawValue ?? this.kindRawValue,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class BudgetRecord {
  final String id, categoryName, categoryIcon, categoryEmoji;
  final int limitMinor;
  final DateTime monthStart, updatedAt;
  const BudgetRecord({
    required this.id,
    required this.categoryName,
    required this.limitMinor,
    required this.monthStart,
    required this.updatedAt,
    this.categoryIcon = 'circle.fill',
    this.categoryEmoji = '',
  });
  double get limit => limitMinor / 100;
  Map<String, dynamic> payload() => {
    'categoryName': categoryName,
    'categoryIcon': categoryIcon,
    'categoryEmoji': categoryEmoji,
    'limit': limit,
    'monthStart': _timestamp(monthStart),
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'updatedAt': _timestamp(updatedAt),
    ...payload(),
    'limitMinor': limitMinor,
  };
  factory BudgetRecord.fromJson(Map<String, dynamic> json) =>
      BudgetRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      ).copyWith(limitMinor: json['limitMinor'] as int?);
  factory BudgetRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => BudgetRecord(
    id: id,
    updatedAt: updatedAt,
    categoryName: payload['categoryName'] as String,
    categoryIcon: payload['categoryIcon'] as String? ?? 'circle.fill',
    categoryEmoji: payload['categoryEmoji'] as String? ?? '',
    limitMinor: moneyToMinor(payload['limit'] as num),
    monthStart: _date(payload['monthStart']),
  );
  BudgetRecord copyWith({
    String? id,
    String? categoryName,
    String? categoryIcon,
    String? categoryEmoji,
    int? limitMinor,
    DateTime? monthStart,
    DateTime? updatedAt,
  }) => BudgetRecord(
    id: id ?? this.id,
    categoryName: categoryName ?? this.categoryName,
    categoryIcon: categoryIcon ?? this.categoryIcon,
    categoryEmoji: categoryEmoji ?? this.categoryEmoji,
    limitMinor: limitMinor ?? this.limitMinor,
    monthStart: monthStart ?? this.monthStart,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class Tombstone {
  final String entity, id;
  final DateTime updatedAt;
  const Tombstone({
    required this.entity,
    required this.id,
    required this.updatedAt,
  });
  String get recordID => id;
  Map<String, dynamic> toJson() => {
    'entity': entity,
    'id': id,
    'deleted': true,
    'updatedAt': _timestamp(updatedAt),
  };
  factory Tombstone.fromJson(Map<String, dynamic> json) => Tombstone(
    entity: json['entity'] as String,
    id: json['id'] as String,
    updatedAt: _date(json['updatedAt']),
  );
}

class FinanceSummary {
  final int incomeMinor, expensesMinor;
  const FinanceSummary({
    required this.incomeMinor,
    required this.expensesMinor,
  });
  int get balanceMinor => incomeMinor - expensesMinor;
  double get income => incomeMinor / 100;
  double get expenses => expensesMinor / 100;
  double get balance => balanceMinor / 100;
}

class CategorySpending {
  final String name, icon, emoji, colorName;
  final int amountMinor;
  const CategorySpending({
    required this.name,
    required this.icon,
    required this.emoji,
    required this.colorName,
    required this.amountMinor,
  });
  double get amount => amountMinor / 100;
}

class MonthlyTotal {
  final DateTime month;
  final FinanceSummary summary;
  const MonthlyTotal(this.month, this.summary);
}

class FinanceMath {
  static int totalBalance(Iterable<TransactionRecord> items) => items.fold(
    0,
    (value, item) =>
        value +
        (item.kind == TransactionKind.income
            ? item.amountMinor
            : -item.amountMinor),
  );
  static DateTime monthStart(DateTime date) => date.isUtc
      ? DateTime.utc(date.year, date.month)
      : DateTime(date.year, date.month);
  static DateTime nextMonth(DateTime date) => date.isUtc
      ? DateTime.utc(date.year, date.month + 1)
      : DateTime(date.year, date.month + 1);
  static bool _inPeriod(TransactionRecord item, DateTime start, DateTime end) =>
      !item.isBalanceAdjustment &&
      !item.date.isBefore(start) &&
      item.date.isBefore(end);
  static FinanceSummary summary(
    Iterable<TransactionRecord> items,
    DateTime start,
    DateTime endExclusive,
  ) {
    var income = 0;
    var expenses = 0;
    for (final item in items) {
      if (!_inPeriod(item, start, endExclusive)) continue;
      if (item.kind == TransactionKind.income) {
        income += item.amountMinor;
      } else {
        expenses += item.amountMinor;
      }
    }
    return FinanceSummary(incomeMinor: income, expensesMinor: expenses);
  }

  static List<CategorySpending> spending(
    Iterable<TransactionRecord> items,
    DateTime start,
    DateTime endExclusive,
  ) {
    final grouped = <String, CategorySpending>{};
    for (final item in items) {
      if (item.kind != TransactionKind.expense ||
          !_inPeriod(item, start, endExclusive)) {
        continue;
      }
      final existing = grouped[item.categoryName];
      grouped[item.categoryName] = CategorySpending(
        name: item.categoryName,
        icon: existing?.icon ?? item.categoryIcon,
        emoji: existing?.emoji ?? item.categoryEmoji,
        colorName: existing?.colorName ?? item.categoryColorName,
        amountMinor: (existing?.amountMinor ?? 0) + item.amountMinor,
      );
    }
    return grouped.values.toList()..sort((a, b) {
      final byAmount = b.amountMinor.compareTo(a.amountMinor);
      return byAmount == 0 ? a.name.compareTo(b.name) : byAmount;
    });
  }

  /// Includes empty months, ordered from oldest to newest.
  static List<MonthlyTotal> monthlyTrend(
    Iterable<TransactionRecord> items,
    DateTime through, {
    int months = 6,
  }) {
    if (months < 0) throw ArgumentError.value(months, 'months');
    final snapshot = items.toList();
    return List.generate(months, (index) {
      final month = through.isUtc
          ? DateTime.utc(through.year, through.month - months + 1 + index)
          : DateTime(through.year, through.month - months + 1 + index);
      return MonthlyTotal(month, summary(snapshot, month, nextMonth(month)));
    });
  }

  static int budgetUsed(
    BudgetRecord budget,
    Iterable<TransactionRecord> items,
  ) {
    // Native clients serialize local month starts as UTC instants. In positive
    // offsets January 1 becomes December 31 on the wire; recover the local
    // calendar month before building its spending interval.
    final start = monthStart(budget.monthStart.toLocal());
    return items
        .where(
          (item) =>
              item.categoryName == budget.categoryName &&
              item.kind == TransactionKind.expense &&
              _inPeriod(item, start, nextMonth(start)),
        )
        .fold(0, (value, item) => value + item.amountMinor);
  }

  static String escapeCsv(String value) => '"${value.replaceAll('"', '""')}"';

  /// The first five columns match the native clients' export; the rest make a
  /// transaction lossless, so StatementImport can read the file back exactly.
  static const csvHeader = [
    'Дата',
    'Тип',
    'Категория',
    'Сумма',
    'Заметка',
    'ID',
    'Вид',
    'Иконка',
    'Эмодзи',
    'Цвет',
    'Изменено',
  ];

  /// Spreadsheets run cells starting with `= + - @`, tab or CR as formulas.
  /// A leading apostrophe disarms them; it is also added before an existing
  /// apostrophe, so [csvValue] can remove exactly one and restore the text.
  static String csvCell(String value) =>
      RegExp(r"^[=+\-@\t\r']").hasMatch(value) ? "'$value" : value;
  static String csvValue(String cell) =>
      RegExp(r"^'[=+\-@\t\r']").hasMatch(cell) ? cell.substring(1) : cell;

  /// UTF-8 with BOM (spreadsheets otherwise misread Cyrillic), LF rows,
  /// ISO 8601 UTC dates, amounts in units with exactly two decimals.
  static String exportCsv(Iterable<TransactionRecord> items) {
    final ordered = items.toList()..sort((a, b) => b.date.compareTo(a.date));
    return '\uFEFF${[
      csvHeader.join(','),
      ...ordered.map((item) => [_timestamp(item.date), item.isBalanceAdjustment ? 'Корректировка' : item.kind.title, item.categoryName, formatMinor(item.amountMinor), item.note, item.id, item.kindRawValue, item.categoryIcon, item.categoryEmoji, item.categoryColorName, _timestamp(item.updatedAt)].map((value) => escapeCsv(csvCell(value))).join(',')),
    ].join('\n')}';
  }
}

class CategoryDesignOptions {
  static const icons = <String>[
    'star.fill',
    'heart.fill',
    'sparkles',
    'bolt.fill',
    'flame.fill',
    'drop.fill',
    'cart.fill',
    'bag.fill',
    'creditcard.fill',
    'banknote.fill',
    'gift.fill',
    'tag.fill',
    'cup.and.saucer.fill',
    'fork.knife',
    'takeoutbag.and.cup.and.straw.fill',
    'birthday.cake.fill',
    'car.fill',
    'bus.fill',
    'tram.fill',
    'bicycle',
    'airplane',
    'fuelpump.fill',
    'house.fill',
    'bed.double.fill',
    'lightbulb.fill',
    'wifi',
    'phone.fill',
    'printer.fill',
    'pawprint.fill',
    'leaf.fill',
    'figure.walk',
    'figure.run',
    'dumbbell.fill',
    'cross.case.fill',
    'pills.fill',
    'stethoscope',
    'book.fill',
    'graduationcap.fill',
    'laptopcomputer',
    'briefcase.fill',
    'gamecontroller.fill',
    'music.note',
    'film.fill',
    'camera.fill',
    'paintpalette.fill',
    'tshirt.fill',
    'hammer.fill',
    'wrench.and.screwdriver.fill',
    'shippingbox.fill',
    'globe.europe.africa.fill',
  ];
  static const emojis = <String>[
    '🍔',
    '☕️',
    '🛒',
    '🚕',
    '✈️',
    '🏠',
    '💡',
    '📱',
    '💻',
    '🎮',
    '🎬',
    '🎵',
    '📚',
    '🎓',
    '💊',
    '🏋️',
    '🐶',
    '🐱',
    '👕',
    '🎁',
    '💰',
    '💳',
    '📈',
    '🔧',
    '🌿',
    '❤️',
    '⭐️',
    '🎯',
    '🧾',
    '🏖️',
  ];
  static const colors = <String>[
    'red',
    'orange',
    'yellow',
    'green',
    'mint',
    'teal',
    'cyan',
    'blue',
    'indigo',
    'purple',
    'pink',
    'gray',
    'coral',
    'peach',
    'gold',
    'lime',
    'forest',
    'turquoise',
    'sky',
    'navy',
    'lavender',
    'magenta',
    'brown',
    'slate',
  ];
}

class BuiltInCategories {
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  static final expense = List<CategoryRecord>.unmodifiable([
    CategoryRecord(
      id: 'food',
      name: 'Продукты',
      icon: 'cart.fill',
      colorName: 'orange',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'transport',
      name: 'Транспорт',
      icon: 'car.fill',
      colorName: 'blue',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'home',
      name: 'Дом',
      icon: 'house.fill',
      colorName: 'indigo',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'entertainment',
      name: 'Развлечения',
      icon: 'gamecontroller.fill',
      colorName: 'pink',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'health',
      name: 'Здоровье',
      icon: 'cross.case.fill',
      colorName: 'red',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'shopping',
      name: 'Покупки',
      icon: 'bag.fill',
      colorName: 'purple',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'subscriptions',
      name: 'Подписки',
      icon: 'repeat',
      colorName: 'cyan',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'education',
      name: 'Образование',
      icon: 'book.fill',
      colorName: 'mint',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'other-expense',
      name: 'Другое',
      icon: 'ellipsis.circle.fill',
      colorName: 'gray',
      kindRawValue: 'expense',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
  ]);
  static final income = List<CategoryRecord>.unmodifiable([
    CategoryRecord(
      id: 'salary',
      name: 'Зарплата',
      icon: 'banknote.fill',
      colorName: 'green',
      kindRawValue: 'income',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'freelance',
      name: 'Подработка',
      icon: 'laptopcomputer',
      colorName: 'teal',
      kindRawValue: 'income',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'investments',
      name: 'Инвестиции',
      icon: 'chart.line.uptrend.xyaxis',
      colorName: 'blue',
      kindRawValue: 'income',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'gift',
      name: 'Подарок',
      icon: 'gift.fill',
      colorName: 'pink',
      kindRawValue: 'income',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
    CategoryRecord(
      id: 'other-income',
      name: 'Другое',
      icon: 'plus.circle.fill',
      colorName: 'gray',
      kindRawValue: 'income',
      createdAt: _epoch,
      updatedAt: _epoch,
    ),
  ]);
  static List<CategoryRecord> forKind(String kind) =>
      kind == 'income' ? income : expense;
}
