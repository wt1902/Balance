/// Contract v2 entities (docs/ecosystem/CONTRACT_V2.md §1): accounts,
/// transfers, recurring rules, goals, debts, exchange rates, settings and
/// attachment metadata. Amounts are integer hundredths inside the client and
/// numbers on the wire; every record keeps payload fields it does not know.
library;

import 'finance.dart';

DateTime _date(Object? value) => DateTime.parse(value as String);
DateTime? _optionalDate(Object? value) =>
    value == null ? null : DateTime.parse(value as String);
String _timestamp(DateTime value) => value.toUtc().toIso8601String();
String? _optionalTimestamp(DateTime? value) =>
    value == null ? null : _timestamp(value);
int _money(Object? value, {int fallback = 0}) =>
    value == null ? fallback : moneyToMinor(value as num);
double _wire(int minor) => minor / 100;
String? _optionalString(Object? value) {
  final text = value as String?;
  return text == null || text.isEmpty ? null : text;
}

String? _optionalCurrency(Object? value) {
  final text = (value as String?)?.trim().toUpperCase();
  if (text == null || text.isEmpty) return null;
  if (!isCurrencyCode(text)) throw const FormatException('Неверный код валюты');
  return text;
}

String _requiredCurrency(Object? value) =>
    _optionalCurrency(value) ??
    (throw const FormatException('Нет кода валюты'));

Map<String, dynamic> _withLocal(SyncRecord record) => {
  ...record.payload(),
  'id': record.id,
  'updatedAt': _timestamp(record.updatedAt),
};

enum AccountKind {
  cash,
  card,
  deposit,
  other;

  String get title => switch (this) {
    cash => 'Наличные',
    card => 'Карта',
    deposit => 'Вклад',
    other => 'Другое',
  };

  /// An unknown kind from a newer client reads as [other].
  static AccountKind parse(String value) =>
      values.firstWhere((kind) => kind.name == value, orElse: () => other);
}

class AccountRecord implements SyncRecord {
  const AccountRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.kindRawValue = 'card',
    this.icon = 'creditcard.fill',
    this.colorName = 'blue',
    this.currency,
    this.isArchived = false,
    this.sortOrder = 0,
    this.extra = const {},
  });

  @override
  final String id;
  final String name, kindRawValue, icon, colorName;

  /// Null: the base currency.
  final String? currency;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  final bool isArchived;
  final int sortOrder;
  final Map<String, dynamic> extra;

  static const payloadKeys = {
    'name',
    'kindRawValue',
    'icon',
    'colorName',
    'currency',
    'createdAt',
    'isArchived',
    'sortOrder',
  };

  AccountKind get kind => AccountKind.parse(kindRawValue);

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'name': name,
    'kindRawValue': kindRawValue,
    'icon': icon,
    'colorName': colorName,
    'currency': currency,
    'createdAt': _timestamp(createdAt),
    'isArchived': isArchived,
    'sortOrder': sortOrder,
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory AccountRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => AccountRecord(
    id: id,
    updatedAt: updatedAt,
    name: payload['name'] as String,
    kindRawValue: payload['kindRawValue'] as String? ?? 'other',
    icon: payload['icon'] as String? ?? 'creditcard.fill',
    colorName: payload['colorName'] as String? ?? 'blue',
    currency: _optionalCurrency(payload['currency']),
    createdAt: _optionalDate(payload['createdAt']) ?? updatedAt,
    isArchived: payload['isArchived'] as bool? ?? false,
    sortOrder: (payload['sortOrder'] as num?)?.toInt() ?? 0,
    extra: unknownPayloadFields(payload, payloadKeys),
  );
  factory AccountRecord.fromJson(Map<String, dynamic> json) =>
      AccountRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  AccountRecord copyWith({
    String? name,
    String? kindRawValue,
    String? icon,
    String? colorName,
    Object? currency = keepValue,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isArchived,
    int? sortOrder,
  }) => AccountRecord(
    id: id,
    name: name ?? this.name,
    kindRawValue: kindRawValue ?? this.kindRawValue,
    icon: icon ?? this.icon,
    colorName: colorName ?? this.colorName,
    currency: keepOr<String>(currency, this.currency),
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    isArchived: isArchived ?? this.isArchived,
    sortOrder: sortOrder ?? this.sortOrder,
    extra: extra,
  );
  @override
  AccountRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

/// Money moved between two accounts. [amountMinor] is in the source account's
/// currency, [toAmountMinor] in the destination's (equal by default).
class TransferRecord implements SyncRecord {
  const TransferRecord({
    required this.id,
    required this.fromAccountId,
    required this.toAccountId,
    required this.amountMinor,
    required this.date,
    required this.updatedAt,
    int? toAmountMinor,
    this.note = '',
    this.extra = const {},
  }) : toAmountMinor = toAmountMinor ?? amountMinor;

  @override
  final String id;
  final String fromAccountId, toAccountId, note;
  final int amountMinor, toAmountMinor;
  final DateTime date;
  @override
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  static const payloadKeys = {
    'fromAccountId',
    'toAccountId',
    'amount',
    'toAmount',
    'date',
    'note',
  };

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'fromAccountId': fromAccountId,
    'toAccountId': toAccountId,
    'amount': _wire(amountMinor),
    'toAmount': _wire(toAmountMinor),
    'date': _timestamp(date),
    'note': note,
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory TransferRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) {
    final amount = _money(payload['amount']);
    return TransferRecord(
      id: id,
      updatedAt: updatedAt,
      fromAccountId: payload['fromAccountId'] as String,
      toAccountId: payload['toAccountId'] as String,
      amountMinor: amount,
      toAmountMinor: _money(payload['toAmount'], fallback: amount),
      date: _date(payload['date']),
      note: payload['note'] as String? ?? '',
      extra: unknownPayloadFields(payload, payloadKeys),
    );
  }
  factory TransferRecord.fromJson(Map<String, dynamic> json) =>
      TransferRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  TransferRecord copyWith({
    String? fromAccountId,
    String? toAccountId,
    int? amountMinor,
    int? toAmountMinor,
    DateTime? date,
    String? note,
    DateTime? updatedAt,
  }) => TransferRecord(
    id: id,
    fromAccountId: fromAccountId ?? this.fromAccountId,
    toAccountId: toAccountId ?? this.toAccountId,
    amountMinor: amountMinor ?? this.amountMinor,
    toAmountMinor: toAmountMinor ?? this.toAmountMinor,
    date: date ?? this.date,
    note: note ?? this.note,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );
  @override
  TransferRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

enum RecurringMode {
  /// Transactions are created automatically.
  auto,

  /// The user confirms or skips each occurrence.
  remind,
}

class RecurringRecord implements SyncRecord {
  const RecurringRecord({
    required this.id,
    required this.amountMinor,
    required this.categoryName,
    required this.startDate,
    required this.updatedAt,
    this.kindRawValue = 'expense',
    this.currency,
    this.accountId,
    this.categoryIcon = 'circle.fill',
    this.categoryEmoji = '',
    this.categoryColorName = 'auto',
    this.note = '',
    this.tags = const [],
    this.frequencyRawValue = 'monthly',
    this.interval = 1,
    this.endDate,
    this.modeRawValue = 'auto',
    this.isPaused = false,
    this.generatedThrough,
    this.extra = const {},
  });

  @override
  final String id;
  final String kindRawValue,
      categoryName,
      categoryIcon,
      categoryEmoji,
      categoryColorName,
      note,
      frequencyRawValue,
      modeRawValue;
  final int amountMinor, interval;
  final String? currency, accountId;
  final List<String> tags;
  final DateTime startDate;
  final DateTime? endDate;
  final bool isPaused;

  /// `YYYY-MM-DD` of the last processed occurrence.
  final String? generatedThrough;
  @override
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  static const payloadKeys = {
    'kindRawValue',
    'amount',
    'currency',
    'accountId',
    'categoryName',
    'categoryIcon',
    'categoryEmoji',
    'categoryColorName',
    'note',
    'tags',
    'frequency',
    'interval',
    'startDate',
    'endDate',
    'mode',
    'isPaused',
    'generatedThrough',
  };

  TransactionKind get kind => TransactionKind.parse(kindRawValue);

  /// Null for a frequency of a newer client: such a rule creates nothing.
  RecurrenceFrequency? get frequency => RecurrenceFrequency.values
      .where((f) => f.name == frequencyRawValue)
      .firstOrNull;
  RecurringMode? get mode =>
      RecurringMode.values.where((m) => m.name == modeRawValue).firstOrNull;

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'kindRawValue': kindRawValue,
    'amount': _wire(amountMinor),
    'currency': currency,
    'accountId': accountId,
    'categoryName': categoryName,
    'categoryIcon': categoryIcon,
    'categoryEmoji': categoryEmoji,
    'categoryColorName': categoryColorName,
    'note': note,
    'tags': tags,
    'frequency': frequencyRawValue,
    'interval': interval,
    'startDate': _timestamp(startDate),
    'endDate': _optionalTimestamp(endDate),
    'mode': modeRawValue,
    'isPaused': isPaused,
    'generatedThrough': generatedThrough,
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory RecurringRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) {
    final through = _optionalString(payload['generatedThrough']);
    if (through != null) parseIsoDay(through);
    return RecurringRecord(
      id: id,
      updatedAt: updatedAt,
      kindRawValue: payload['kindRawValue'] as String? ?? 'expense',
      amountMinor: _money(payload['amount']),
      currency: _optionalCurrency(payload['currency']),
      accountId: _optionalString(payload['accountId']),
      categoryName: payload['categoryName'] as String,
      categoryIcon: payload['categoryIcon'] as String? ?? 'circle.fill',
      categoryEmoji: payload['categoryEmoji'] as String? ?? '',
      categoryColorName: payload['categoryColorName'] as String? ?? 'auto',
      note: payload['note'] as String? ?? '',
      tags: TagRules.normalize(payload['tags'] as List? ?? const []),
      frequencyRawValue: payload['frequency'] as String? ?? 'monthly',
      interval: (payload['interval'] as num?)?.toInt() ?? 1,
      startDate: _date(payload['startDate']),
      endDate: _optionalDate(payload['endDate']),
      modeRawValue: payload['mode'] as String? ?? 'auto',
      isPaused: payload['isPaused'] as bool? ?? false,
      generatedThrough: through,
      extra: unknownPayloadFields(payload, payloadKeys),
    );
  }
  factory RecurringRecord.fromJson(Map<String, dynamic> json) =>
      RecurringRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  RecurringRecord copyWith({
    String? kindRawValue,
    int? amountMinor,
    Object? currency = keepValue,
    Object? accountId = keepValue,
    String? categoryName,
    String? categoryIcon,
    String? categoryEmoji,
    String? categoryColorName,
    String? note,
    List<String>? tags,
    String? frequencyRawValue,
    int? interval,
    DateTime? startDate,
    Object? endDate = keepValue,
    String? modeRawValue,
    bool? isPaused,
    Object? generatedThrough = keepValue,
    DateTime? updatedAt,
  }) => RecurringRecord(
    id: id,
    kindRawValue: kindRawValue ?? this.kindRawValue,
    amountMinor: amountMinor ?? this.amountMinor,
    currency: keepOr<String>(currency, this.currency),
    accountId: keepOr<String>(accountId, this.accountId),
    categoryName: categoryName ?? this.categoryName,
    categoryIcon: categoryIcon ?? this.categoryIcon,
    categoryEmoji: categoryEmoji ?? this.categoryEmoji,
    categoryColorName: categoryColorName ?? this.categoryColorName,
    note: note ?? this.note,
    tags: tags ?? this.tags,
    frequencyRawValue: frequencyRawValue ?? this.frequencyRawValue,
    interval: interval ?? this.interval,
    startDate: startDate ?? this.startDate,
    endDate: keepOr<DateTime>(endDate, this.endDate),
    modeRawValue: modeRawValue ?? this.modeRawValue,
    isPaused: isPaused ?? this.isPaused,
    generatedThrough: keepOr<String>(generatedThrough, this.generatedThrough),
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );
  @override
  RecurringRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

/// A savings goal. Progress is the balance of [accountId] when set,
/// otherwise [savedMinor] (see FinanceMath.goalProgress).
class GoalRecord implements SyncRecord {
  const GoalRecord({
    required this.id,
    required this.name,
    required this.targetMinor,
    required this.createdAt,
    required this.updatedAt,
    this.currency,
    this.deadline,
    this.accountId,
    this.savedMinor = 0,
    this.icon = 'star.fill',
    this.colorName = 'sky',
    this.isArchived = false,
    this.extra = const {},
  });

  @override
  final String id;
  final String name, icon, colorName;
  final int targetMinor, savedMinor;
  final String? currency, accountId;
  final DateTime? deadline;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  final bool isArchived;
  final Map<String, dynamic> extra;

  static const payloadKeys = {
    'name',
    'target',
    'currency',
    'deadline',
    'accountId',
    'saved',
    'icon',
    'colorName',
    'createdAt',
    'isArchived',
  };

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'name': name,
    'target': _wire(targetMinor),
    'currency': currency,
    'deadline': _optionalTimestamp(deadline),
    'accountId': accountId,
    'saved': _wire(savedMinor),
    'icon': icon,
    'colorName': colorName,
    'createdAt': _timestamp(createdAt),
    'isArchived': isArchived,
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory GoalRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => GoalRecord(
    id: id,
    updatedAt: updatedAt,
    name: payload['name'] as String,
    targetMinor: _money(payload['target']),
    currency: _optionalCurrency(payload['currency']),
    deadline: _optionalDate(payload['deadline']),
    accountId: _optionalString(payload['accountId']),
    savedMinor: _money(payload['saved']),
    icon: payload['icon'] as String? ?? 'star.fill',
    colorName: payload['colorName'] as String? ?? 'sky',
    createdAt: _optionalDate(payload['createdAt']) ?? updatedAt,
    isArchived: payload['isArchived'] as bool? ?? false,
    extra: unknownPayloadFields(payload, payloadKeys),
  );
  factory GoalRecord.fromJson(Map<String, dynamic> json) =>
      GoalRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  GoalRecord copyWith({
    String? name,
    int? targetMinor,
    Object? currency = keepValue,
    Object? deadline = keepValue,
    Object? accountId = keepValue,
    int? savedMinor,
    String? icon,
    String? colorName,
    DateTime? createdAt,
    bool? isArchived,
    DateTime? updatedAt,
  }) => GoalRecord(
    id: id,
    name: name ?? this.name,
    targetMinor: targetMinor ?? this.targetMinor,
    currency: keepOr<String>(currency, this.currency),
    deadline: keepOr<DateTime>(deadline, this.deadline),
    accountId: keepOr<String>(accountId, this.accountId),
    savedMinor: savedMinor ?? this.savedMinor,
    icon: icon ?? this.icon,
    colorName: colorName ?? this.colorName,
    createdAt: createdAt ?? this.createdAt,
    isArchived: isArchived ?? this.isArchived,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );
  @override
  GoalRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

enum DebtDirection {
  iOwe,
  owedToMe;

  String get title => this == iOwe ? 'Я должен' : 'Мне должны';
}

/// A debt. It never changes balances or analytics: money that actually moved
/// is recorded as an ordinary transaction.
class DebtRecord implements SyncRecord {
  const DebtRecord({
    required this.id,
    required this.person,
    required this.amountMinor,
    required this.date,
    required this.updatedAt,
    this.directionRawValue = 'owedToMe',
    this.currency,
    this.dueDate,
    this.note = '',
    this.repaidMinor = 0,
    this.isClosed = false,
    this.extra = const {},
  });

  @override
  final String id;
  final String person, directionRawValue, note;
  final int amountMinor, repaidMinor;
  final String? currency;
  final DateTime date;
  final DateTime? dueDate;
  final bool isClosed;
  @override
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  static const payloadKeys = {
    'person',
    'direction',
    'amount',
    'currency',
    'date',
    'dueDate',
    'note',
    'repaid',
    'isClosed',
  };

  /// Null for a direction of a newer client.
  DebtDirection? get direction => DebtDirection.values
      .where((d) => d.name == directionRawValue)
      .firstOrNull;

  /// `amount − repaid`.
  int get remainingMinor => amountMinor - repaidMinor;

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'person': person,
    'direction': directionRawValue,
    'amount': _wire(amountMinor),
    'currency': currency,
    'date': _timestamp(date),
    'dueDate': _optionalTimestamp(dueDate),
    'note': note,
    'repaid': _wire(repaidMinor),
    'isClosed': isClosed,
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory DebtRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => DebtRecord(
    id: id,
    updatedAt: updatedAt,
    person: payload['person'] as String,
    directionRawValue: payload['direction'] as String? ?? 'owedToMe',
    amountMinor: _money(payload['amount']),
    currency: _optionalCurrency(payload['currency']),
    date: _date(payload['date']),
    dueDate: _optionalDate(payload['dueDate']),
    note: payload['note'] as String? ?? '',
    repaidMinor: _money(payload['repaid']),
    isClosed: payload['isClosed'] as bool? ?? false,
    extra: unknownPayloadFields(payload, payloadKeys),
  );
  factory DebtRecord.fromJson(Map<String, dynamic> json) =>
      DebtRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  DebtRecord copyWith({
    String? person,
    String? directionRawValue,
    int? amountMinor,
    Object? currency = keepValue,
    DateTime? date,
    Object? dueDate = keepValue,
    String? note,
    int? repaidMinor,
    bool? isClosed,
    DateTime? updatedAt,
  }) => DebtRecord(
    id: id,
    person: person ?? this.person,
    directionRawValue: directionRawValue ?? this.directionRawValue,
    amountMinor: amountMinor ?? this.amountMinor,
    currency: keepOr<String>(currency, this.currency),
    date: date ?? this.date,
    dueDate: keepOr<DateTime>(dueDate, this.dueDate),
    note: note ?? this.note,
    repaidMinor: repaidMinor ?? this.repaidMinor,
    isClosed: isClosed ?? this.isClosed,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );
  @override
  DebtRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

/// How many units of [to] one unit of [from] costs, as a decimal string with
/// up to six fractional digits. [rateMicros] is that value times 10⁶.
class RateRecord implements SyncRecord {
  RateRecord({
    required this.id,
    required this.from,
    required this.to,
    required this.rate,
    required this.date,
    required this.updatedAt,
    this.extra = const {},
  }) : rateMicros = parseRateMicros(rate);

  @override
  final String id;
  final String from, to, rate;
  final BigInt rateMicros;
  final DateTime date;
  @override
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  static const payloadKeys = {'from', 'to', 'rate', 'date'};

  /// Strict decimal: digits, optional point and 1–6 fractional digits,
  /// greater than zero. Exponents, signs and commas are rejected.
  static BigInt parseRateMicros(String value) {
    final match = RegExp(r'^(\d+)(?:\.(\d{1,6}))?$').firstMatch(value.trim());
    if (match == null) {
      throw const FormatException('Курс — число, до 6 знаков после точки');
    }
    final micros =
        BigInt.parse(match[1]!) * BigInt.from(1000000) +
        BigInt.parse((match[2] ?? '').padRight(6, '0'));
    if (micros <= BigInt.zero) {
      throw const FormatException('Курс должен быть больше нуля');
    }
    return micros;
  }

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'from': from,
    'to': to,
    'rate': rate,
    'date': _timestamp(date),
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory RateRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) {
    final raw = payload['rate'];
    return RateRecord(
      id: id,
      updatedAt: updatedAt,
      from: _requiredCurrency(payload['from']),
      to: _requiredCurrency(payload['to']),
      // Tolerate a number from a lenient client; the wire format is a string.
      rate: raw is num ? raw.toString() : raw as String,
      date: _date(payload['date']),
      extra: unknownPayloadFields(payload, payloadKeys),
    );
  }
  factory RateRecord.fromJson(Map<String, dynamic> json) =>
      RateRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  RateRecord copyWith({
    String? from,
    String? to,
    String? rate,
    DateTime? date,
    DateTime? updatedAt,
  }) => RateRecord(
    id: id,
    from: from ?? this.from,
    to: to ?? this.to,
    rate: rate ?? this.rate,
    date: date ?? this.date,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra,
  );
  @override
  RateRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

/// A synchronized setting; [id] is its key. Known key: [baseCurrencyKey].
class SettingRecord implements SyncRecord {
  const SettingRecord({
    required this.id,
    required this.value,
    required this.updatedAt,
    this.extra = const {},
  });

  static const baseCurrencyKey = 'baseCurrency';

  @override
  final String id;
  final Object? value;
  @override
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  static const payloadKeys = {'value'};

  @override
  Map<String, dynamic> payload() => {...extra, 'value': value};
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory SettingRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) => SettingRecord(
    id: id,
    updatedAt: updatedAt,
    value: payload['value'],
    extra: unknownPayloadFields(payload, payloadKeys),
  );
  factory SettingRecord.fromJson(Map<String, dynamic> json) =>
      SettingRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  SettingRecord copyWith({Object? value = keepValue, DateTime? updatedAt}) =>
      SettingRecord(
        id: id,
        value: keepOr<Object>(value, this.value),
        updatedAt: updatedAt ?? this.updatedAt,
        extra: extra,
      );
  @override
  SettingRecord stamped(DateTime updatedAt) => copyWith(updatedAt: updatedAt);
}

/// Metadata of a file attached to a transaction. The bytes travel separately
/// (`/v1/attachments/{sha256}`) and are cached on the device.
class AttachmentRecord implements SyncRecord {
  const AttachmentRecord({
    required this.id,
    required this.transactionId,
    required this.sha256,
    required this.contentType,
    required this.size,
    required this.createdAt,
    required this.updatedAt,
    this.name = '',
    this.extra = const {},
  });

  @override
  final String id;
  final String transactionId, sha256, contentType, name;
  final int size;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  static const payloadKeys = {
    'transactionId',
    'sha256',
    'contentType',
    'size',
    'name',
    'createdAt',
  };

  static bool isSha256(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  @override
  Map<String, dynamic> payload() => {
    ...extra,
    'transactionId': transactionId,
    'sha256': sha256,
    'contentType': contentType,
    'size': size,
    'name': name,
    'createdAt': _timestamp(createdAt),
  };
  @override
  Map<String, dynamic> toJson() => _withLocal(this);

  factory AttachmentRecord.fromPayload({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  }) {
    final sha = (payload['sha256'] as String).toLowerCase();
    if (!isSha256(sha)) throw const FormatException('Неверный SHA-256');
    return AttachmentRecord(
      id: id,
      updatedAt: updatedAt,
      transactionId: payload['transactionId'] as String,
      sha256: sha,
      contentType: payload['contentType'] as String,
      size: (payload['size'] as num).toInt(),
      name: payload['name'] as String? ?? '',
      createdAt: _optionalDate(payload['createdAt']) ?? updatedAt,
      extra: unknownPayloadFields(payload, payloadKeys),
    );
  }
  factory AttachmentRecord.fromJson(Map<String, dynamic> json) =>
      AttachmentRecord.fromPayload(
        id: json['id'] as String,
        updatedAt: _date(json['updatedAt']),
        payload: json,
      );

  AttachmentRecord copyWith({String? name, DateTime? updatedAt}) =>
      AttachmentRecord(
        id: id,
        transactionId: transactionId,
        sha256: sha256,
        contentType: contentType,
        size: size,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        extra: extra,
      );
  @override
  AttachmentRecord stamped(DateTime updatedAt) =>
      copyWith(updatedAt: updatedAt);
}

/// How one synchronized entity is named on the wire, in a local snapshot
/// section and in per-record storage keys, and how it is read back.
class EntityCodec<T extends SyncRecord> {
  const EntityCodec({
    required this.entity,
    required this.section,
    required this.prefix,
    required this.fromPayload,
    required this.fromJson,
    required this.title,
  });

  final String entity, section, prefix, title;
  final T Function({
    required String id,
    required DateTime updatedAt,
    required Map<String, dynamic> payload,
  })
  fromPayload;
  final T Function(Map<String, dynamic> json) fromJson;
}

/// Every entity of contract v2, in the order a restore applies them.
final entityCodecs = <String, EntityCodec>{
  'setting': const EntityCodec<SettingRecord>(
    entity: 'setting',
    section: 'settings',
    prefix: 's',
    fromPayload: SettingRecord.fromPayload,
    fromJson: SettingRecord.fromJson,
    title: 'Настройка',
  ),
  'rate': const EntityCodec<RateRecord>(
    entity: 'rate',
    section: 'rates',
    prefix: 'rt',
    fromPayload: RateRecord.fromPayload,
    fromJson: RateRecord.fromJson,
    title: 'Курс',
  ),
  'account': const EntityCodec<AccountRecord>(
    entity: 'account',
    section: 'accounts',
    prefix: 'a',
    fromPayload: AccountRecord.fromPayload,
    fromJson: AccountRecord.fromJson,
    title: 'Счёт',
  ),
  'category': const EntityCodec<CategoryRecord>(
    entity: 'category',
    section: 'categories',
    prefix: 'c',
    fromPayload: CategoryRecord.fromPayload,
    fromJson: CategoryRecord.fromJson,
    title: 'Категория',
  ),
  'budget': const EntityCodec<BudgetRecord>(
    entity: 'budget',
    section: 'budgets',
    prefix: 'b',
    fromPayload: BudgetRecord.fromPayload,
    fromJson: BudgetRecord.fromJson,
    title: 'Бюджет',
  ),
  'transaction': const EntityCodec<TransactionRecord>(
    entity: 'transaction',
    section: 'transactions',
    prefix: 't',
    fromPayload: TransactionRecord.fromPayload,
    fromJson: TransactionRecord.fromJson,
    title: 'Операция',
  ),
  'transfer': const EntityCodec<TransferRecord>(
    entity: 'transfer',
    section: 'transfers',
    prefix: 'tr',
    fromPayload: TransferRecord.fromPayload,
    fromJson: TransferRecord.fromJson,
    title: 'Перевод',
  ),
  'recurring': const EntityCodec<RecurringRecord>(
    entity: 'recurring',
    section: 'recurring',
    prefix: 'rc',
    fromPayload: RecurringRecord.fromPayload,
    fromJson: RecurringRecord.fromJson,
    title: 'Регулярная операция',
  ),
  'goal': const EntityCodec<GoalRecord>(
    entity: 'goal',
    section: 'goals',
    prefix: 'g',
    fromPayload: GoalRecord.fromPayload,
    fromJson: GoalRecord.fromJson,
    title: 'Цель',
  ),
  'debt': const EntityCodec<DebtRecord>(
    entity: 'debt',
    section: 'debts',
    prefix: 'dt',
    fromPayload: DebtRecord.fromPayload,
    fromJson: DebtRecord.fromJson,
    title: 'Долг',
  ),
  'attachment': const EntityCodec<AttachmentRecord>(
    entity: 'attachment',
    section: 'attachments',
    prefix: 'at',
    fromPayload: AttachmentRecord.fromPayload,
    fromJson: AttachmentRecord.fromJson,
    title: 'Вложение',
  ),
};

/// Entities a contract v1 server accepts.
const v1Entities = {'transaction', 'category', 'budget'};
