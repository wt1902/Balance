import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'finance.dart';

/// Bank statement import: CSV (Т-Банк recognized by its header, any other bank
/// through a column mapping) and OFX. Parsing never touches the ledger; the
/// chosen rows are added through AppStore.importTransactions.

class StatementRow {
  const StatementRow({
    required this.date,
    required this.amountMinor,
    required this.kind,
    required this.description,
    required this.importKey,
    this.bankCategory = '',
    this.id,
    this.category,
    this.isBalanceAdjustment = false,
  });

  final DateTime date;

  /// Always positive; the sign of the statement amount becomes [kind].
  final int amountMinor;
  final TransactionKind kind;
  final String description, bankCategory;

  /// Stable within its source file, so a re-imported row gets the same id.
  final String importKey;

  /// Set only for Balance's own CSV export, which carries the original id,
  /// category design and adjustment flag.
  final String? id;
  final CategoryRecord? category;
  final bool isBalanceAdjustment;
}

class StatementParseResult {
  const StatementParseResult({
    required this.format,
    required this.rows,
    this.problems = const [],
    this.skipped = 0,
  });

  final String format;
  final List<StatementRow> rows;

  /// Rows that could not be read, as «Строка N: причина».
  final List<String> problems;

  /// Rows deliberately left out, e.g. declined card operations.
  final int skipped;
}

/// Column indexes of a CSV statement; optional columns are null.
class CsvMapping {
  const CsvMapping({
    required this.date,
    required this.amount,
    this.description,
    this.category,
    this.status,
    this.invertSign = false,
  });

  final int date, amount;
  final int? description, category, status;

  /// For statements that list expenses as positive numbers.
  final bool invertSign;

  CsvMapping copyWith({
    int? date,
    int? amount,
    int? Function()? description,
    int? Function()? category,
    bool? invertSign,
  }) => CsvMapping(
    date: date ?? this.date,
    amount: amount ?? this.amount,
    description: description == null ? this.description : description(),
    category: category == null ? this.category : category(),
    status: status,
    invertSign: invertSign ?? this.invertSign,
  );
}

class StatementImport {
  static const _uuid = Uuid();
  static const _namespace = '6f1c2a05-5a1e-4f4b-9d3e-0c8a7e2b1f10';

  /// UTF-8 (with or without BOM), UTF-16 with BOM, otherwise Windows-1251,
  /// which Russian banks still use for CSV.
  static String decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
            (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      final little = bytes[0] == 0xFF;
      final units = <int>[
        for (var i = 2; i + 1 < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ];
      return String.fromCharCodes(units);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes([
        for (final byte in bytes)
          byte < 0x80
              ? byte
              : byte < 0xC0
              ? _cp1251[byte - 0x80]
              : 0x0410 + byte - 0xC0,
      ]);
    }
  }

  static const _cp1251 = <int>[
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
  ];

  static bool looksLikeOfx(String text) {
    final head = text.length > 2000 ? text.substring(0, 2000) : text;
    return head.contains('OFXHEADER') ||
        head.toUpperCase().contains('<OFX>') ||
        text.toUpperCase().contains('<STMTTRN>');
  }

  /// RFC 4180 table. The delimiter (`;`, `,` or tab) is taken from the line
  /// with the most of them among the first lines.
  static List<List<String>> parseCsv(String text) {
    if (text.startsWith('﻿')) text = text.substring(1);
    final delimiter = _delimiter(text);
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(char);
        }
      } else if (char == '"') {
        quoted = true;
      } else if (char == delimiter) {
        row.add(field.toString());
        field.clear();
      } else if (char == '\n' || char == '\r') {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
      } else {
        field.write(char);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows
        .where((r) => r.any((cell) => cell.trim().isNotEmpty))
        .toList(growable: false);
  }

  static String _delimiter(String text) {
    final lines = const LineSplitter().convert(text).take(5);
    var best = ';';
    var bestCount = 0;
    for (final candidate in const [';', ',', '\t']) {
      final count = lines.fold<int>(0, (max, line) {
        final n = candidate.allMatches(line).length;
        return n > max ? n : max;
      });
      if (count > bestCount) {
        best = candidate;
        bestCount = count;
      }
    }
    return best;
  }

  static String _norm(String header) =>
      header.trim().toLowerCase().replaceAll('ё', 'е');

  /// Balance's own lossless export (FinanceMath.exportCsv).
  static bool isBalanceExport(List<String> header) {
    final names = header.map((h) => h.trim()).toList();
    return names.length >= FinanceMath.csvHeader.length &&
        FinanceMath.csvHeader.every(names.contains);
  }

  static StatementParseResult readBalanceCsv(List<List<String>> table) {
    final columns = {
      for (var i = 0; i < table.first.length; i++) table.first[i].trim(): i,
    };
    final rows = <StatementRow>[];
    final problems = <String>[];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    for (var i = 1; i < table.length; i++) {
      final row = table[i];
      String cell(String name) {
        final index = columns[name]!;
        return index < row.length ? FinanceMath.csvValue(row[index]) : '';
      }

      try {
        final id = cell('ID').trim();
        if (id.isEmpty) throw const FormatException('Нет ID');
        final date = DateTime.tryParse(cell('Дата').trim());
        if (date == null) throw const FormatException('Неверная дата');
        final amount = parseSignedAmount(cell('Сумма'));
        if (amount <= 0) throw const FormatException('Неверная сумма');
        final kind = TransactionKind.parse(cell('Вид').trim());
        final category = CategoryRecord(
          id: 'csv',
          name: cell('Категория'),
          icon: cell('Иконка').isEmpty ? 'circle.fill' : cell('Иконка'),
          emoji: cell('Эмодзи'),
          colorName: cell('Цвет').isEmpty ? 'auto' : cell('Цвет'),
          kindRawValue: kind.name,
          createdAt: epoch,
          updatedAt: epoch,
        );
        if (category.name.isEmpty) {
          throw const FormatException('Нет категории');
        }
        rows.add(
          StatementRow(
            date: date,
            amountMinor: amount,
            kind: kind,
            description: cell('Заметка'),
            importKey: 'balance|$id',
            id: id,
            category: category,
            isBalanceAdjustment: cell('Тип').trim() == 'Корректировка',
          ),
        );
      } on FormatException catch (e) {
        problems.add('Строка ${i + 1}: ${e.message}');
      }
    }
    return StatementParseResult(
      format: 'Баланс, CSV',
      rows: rows,
      problems: problems,
    );
  }

  /// Т-Банк CSV: «Дата операции», «Статус», «Сумма платежа» in the card
  /// currency (negative for spending), «Категория», «Описание».
  static CsvMapping? tbankMapping(List<String> header) {
    final names = header.map(_norm).toList();
    final date = names.indexOf('дата операции');
    var amount = names.indexOf('сумма платежа');
    if (amount < 0) amount = names.indexOf('сумма операции');
    final description = names.indexOf('описание');
    if (date < 0 || amount < 0 || description < 0) return null;
    final category = names.indexOf('категория');
    final status = names.indexOf('статус');
    return CsvMapping(
      date: date,
      amount: amount,
      description: description,
      category: category < 0 ? null : category,
      status: status < 0 ? null : status,
    );
  }

  /// Best guess for an unknown bank; the user confirms it before import.
  static CsvMapping guessMapping(List<String> header) {
    final names = header.map(_norm).toList();
    int? find(List<String> keys, {Set<int> except = const {}}) {
      for (var i = 0; i < names.length; i++) {
        if (except.contains(i)) continue;
        if (keys.any(names[i].contains)) return i;
      }
      return null;
    }

    final date = find(const ['дата', 'date']) ?? 0;
    final amount =
        find(const ['сумма', 'amount', 'sum'], except: {date}) ??
        (date == 0 && names.length > 1 ? 1 : 0);
    return CsvMapping(
      date: date,
      amount: amount,
      description: find(
        const [
          'описание',
          'назначение',
          'комментарий',
          'контрагент',
          'получатель',
          'description',
          'memo',
          'payee',
        ],
        except: {date, amount},
      ),
      category: find(const ['категория', 'category'], except: {date, amount}),
    );
  }

  static StatementParseResult readCsv(
    List<List<String>> table,
    CsvMapping mapping, {
    String format = 'CSV',
  }) {
    final rows = <StatementRow>[];
    final problems = <String>[];
    final occurrences = <String, int>{};
    var skipped = 0;
    String cell(List<String> row, int? index) =>
        index == null || index >= row.length
        ? ''
        : row[index].trim().replaceAll(RegExp(r'\s+'), ' ');
    for (var i = 1; i < table.length; i++) {
      final row = table[i];
      try {
        final status = cell(row, mapping.status).toUpperCase();
        if (status.isNotEmpty && status != 'OK') {
          skipped++;
          continue;
        }
        final date = parseDate(cell(row, mapping.date));
        var signed = parseSignedAmount(cell(row, mapping.amount));
        if (mapping.invertSign) signed = -signed;
        if (signed == 0) {
          skipped++;
          continue;
        }
        final description = cell(row, mapping.description);
        final base = 'csv|${date.toIso8601String()}|$signed|$description';
        final n = occurrences[base] = (occurrences[base] ?? 0) + 1;
        rows.add(
          StatementRow(
            date: date,
            amountMinor: signed.abs(),
            kind: signed < 0 ? TransactionKind.expense : TransactionKind.income,
            description: description,
            bankCategory: cell(row, mapping.category),
            importKey: '$base|$n',
          ),
        );
      } on FormatException catch (e) {
        problems.add('Строка ${i + 1}: ${e.message}');
      }
    }
    return StatementParseResult(
      format: format,
      rows: rows,
      problems: problems,
      skipped: skipped,
    );
  }

  /// SGML (OFX 1.x, no closing tags) and XML (OFX 2.x) bank transactions.
  static StatementParseResult readOfx(String text) {
    final rows = <StatementRow>[];
    final problems = <String>[];
    final occurrences = <String, int>{};
    var skipped = 0;
    final blocks = RegExp(
      r'<STMTTRN>(.*?)(?=</STMTTRN>|<STMTTRN>|</BANKTRANLIST>|$)',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(text).toList();
    String tag(String block, String name) =>
        RegExp(
          '<$name>([^<\\r\\n]*)',
          caseSensitive: false,
        ).firstMatch(block)?.group(1)?.trim() ??
        '';
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i].group(1)!;
      try {
        final date = _ofxDate(tag(block, 'DTPOSTED'));
        final signed = parseSignedAmount(tag(block, 'TRNAMT'));
        if (signed == 0) {
          skipped++;
          continue;
        }
        final name = _unescape(tag(block, 'NAME'));
        final memo = _unescape(tag(block, 'MEMO'));
        final description = [
          name,
          if (memo.isNotEmpty && memo != name) memo,
        ].where((s) => s.isNotEmpty).join(' · ');
        final fitId = tag(block, 'FITID');
        final base = fitId.isNotEmpty
            ? 'ofx|$fitId'
            : 'ofx|${date.toIso8601String()}|$signed|$description';
        final n = occurrences[base] = (occurrences[base] ?? 0) + 1;
        rows.add(
          StatementRow(
            date: date,
            amountMinor: signed.abs(),
            kind: signed < 0 ? TransactionKind.expense : TransactionKind.income,
            description: description,
            importKey: n == 1 ? base : '$base|$n',
          ),
        );
      } on FormatException catch (e) {
        problems.add('Операция ${i + 1}: ${e.message}');
      }
    }
    return StatementParseResult(
      format: 'OFX',
      rows: rows,
      problems: problems,
      skipped: skipped,
    );
  }

  static String _unescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static DateTime _ofxDate(String value) {
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(?:(\d{2})(\d{2})(\d{2})?)?',
    ).firstMatch(value);
    if (match == null) throw const FormatException('Неверная дата');
    int part(int group) => int.parse(match.group(group) ?? '0');
    return _checkedDate(part(1), part(2), part(3), part(4), part(5), part(6));
  }

  /// Signed amount in hundredths without binary floating point. Accepts
  /// `-1 234,56`, `1,234.56`, `(150.00)`, a Unicode minus and currency marks.
  static int parseSignedAmount(String value) {
    var text = value
        .replaceAll(RegExp(r'[\s   \x27’]'), '')
        .replaceAll('−', '-');
    var negative = false;
    if (text.startsWith('(') && text.endsWith(')')) {
      negative = true;
      text = text.substring(1, text.length - 1);
    }
    text = text.replaceAll(RegExp(r'[^0-9,.+-]'), '');
    if (text.startsWith('-')) {
      negative = !negative;
      text = text.substring(1);
    } else if (text.startsWith('+')) {
      text = text.substring(1);
    }
    if (text.endsWith('-')) {
      negative = !negative;
      text = text.substring(0, text.length - 1);
    }
    if (!RegExp(r'^[0-9][0-9,.]*$').hasMatch(text)) {
      throw const FormatException('Неверная сумма');
    }
    // With both separators the last one is decimal. A single kind is a
    // thousands separator when repeated or followed by exactly three digits
    // (`1.234`, `1,234,567`), otherwise decimal (`1234,5`, `99.90`).
    final separator = text.lastIndexOf(RegExp('[,.]'));
    var whole = text, fraction = '';
    if (separator >= 0) {
      final mark = text[separator];
      final mixed = text.contains(mark == ',' ? '.' : ',');
      final tail = text.substring(separator + 1);
      final repeated = text.indexOf(mark) != separator;
      final leadingZero = RegExp(
        r'^0+$',
      ).hasMatch(text.substring(0, separator));
      if (mixed || (!repeated && (tail.length != 3 || leadingZero))) {
        whole = text.substring(0, separator);
        fraction = tail;
      }
    }
    whole = whole.replaceAll(RegExp(r'[,.]'), '');
    if (whole.isEmpty) whole = '0';
    if (!RegExp(r'^\d+$').hasMatch(whole) ||
        !RegExp(r'^\d*$').hasMatch(fraction)) {
      throw const FormatException('Неверная сумма');
    }
    var minor =
        int.parse(whole) * 100 +
        int.parse(fraction.padRight(2, '0').substring(0, 2));
    if (fraction.length > 2 && int.parse(fraction[2]) >= 5) minor++;
    return negative ? -minor : minor;
  }

  /// Local calendar date and time: `dd.MM.yyyy[ HH:mm[:ss]]`, `dd.MM.yy`,
  /// `dd/MM/yyyy`, ISO 8601 (an explicit offset is converted to local time).
  static DateTime parseDate(String value) {
    final text = value.trim();
    final dotted = RegExp(
      r'^(\d{1,2})[./](\d{1,2})[./](\d{2}|\d{4})(?:[ T,]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
    ).firstMatch(text);
    if (dotted != null) {
      int part(int group) => int.parse(dotted.group(group) ?? '0');
      var year = part(3);
      if (dotted.group(3)!.length == 2) year += 2000;
      return _checkedDate(year, part(2), part(1), part(4), part(5), part(6));
    }
    final iso = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$',
    ).firstMatch(text);
    if (iso != null) {
      if (iso.group(7) != null) {
        return DateTime.parse(text.replaceFirst(' ', 'T')).toLocal();
      }
      int part(int group) => int.parse(iso.group(group) ?? '0');
      return _checkedDate(part(1), part(2), part(3), part(4), part(5), part(6));
    }
    throw FormatException(text.isEmpty ? 'Нет даты' : 'Неверная дата «$text»');
  }

  static DateTime _checkedDate(int y, int mo, int d, int h, int mi, int s) {
    final date = DateTime(y, mo, d, h, mi, s);
    if (date.year != y ||
        date.month != mo ||
        date.day != d ||
        h > 23 ||
        mi > 59 ||
        s > 59) {
      throw const FormatException('Неверная дата');
    }
    return date;
  }

  static const _expenseRules = <String, List<String>>{
    'Продукты': [
      'супермаркет',
      'продукт',
      'гипермаркет',
      'grocery',
      'пятерочка',
      'перекресток',
      'магнит',
      'ашан',
      'вкусвилл',
      'дикси',
      'лента',
    ],
    'Здоровье': [
      'аптек',
      'медицин',
      'здоров',
      'клиник',
      'стоматолог',
      'больниц',
    ],
    'Транспорт': [
      'транспорт',
      'такси',
      'taxi',
      'метро',
      'автобус',
      'азс',
      'топлив',
      'бензин',
      'каршеринг',
      'парковк',
      'ржд',
      'авиабилет',
    ],
    'Подписки': [
      'подписк',
      'связь',
      'телеком',
      'мобильн',
      'spotify',
      'netflix',
      'apple.com',
    ],
    'Дом': ['жкх', 'коммунал', 'квартплат', 'аренда', 'ремонт', 'хозтовар'],
    'Развлечения': [
      'развлеч',
      'кино',
      'рестора',
      'кафе',
      'фастфуд',
      'театр',
      'концерт',
    ],
    'Образование': ['образован', 'обучен', 'курсы', 'университет', 'книг'],
    'Покупки': [
      'одежд',
      'обув',
      'маркетплейс',
      'ozon',
      'озон',
      'wildberries',
      'электроник',
      'бытов',
      'универмаг',
    ],
  };

  static const _incomeRules = <String, List<String>>{
    'Зарплата': ['зарплат', 'заработн', 'аванс', 'salary', 'payroll'],
    'Инвестиции': ['дивиденд', 'купон', 'инвест', 'процент', 'вклад'],
    'Подработка': ['фриланс', 'гонорар'],
    'Подарок': ['подарок'],
  };

  /// A category of the row's kind: the bank category if one has the same
  /// name, otherwise keyword rules over category and description, else «Другое».
  static CategoryRecord suggestCategory(
    StatementRow row,
    List<CategoryRecord> choices,
  ) {
    if (row.category != null) return row.category!;
    final bank = _norm(row.bankCategory);
    if (bank.isNotEmpty) {
      for (final choice in choices) {
        if (_norm(choice.name) == bank) return choice;
      }
    }
    final text = _norm('${row.bankCategory} ${row.description}');
    final rules = row.kind == TransactionKind.income
        ? _incomeRules
        : _expenseRules;
    for (final rule in rules.entries) {
      if (rule.value.any(text.contains)) {
        for (final choice in choices) {
          if (choice.name == rule.key) return choice;
        }
      }
    }
    return choices.firstWhere(
      (choice) => choice.name == 'Другое',
      orElse: () => BuiltInCategories.forKind(row.kind.name).last,
    );
  }

  static String transactionId(StatementRow row) =>
      row.id ?? _uuid.v5(_namespace, row.importKey);

  /// Same kind, amount and local calendar day as an existing operation, e.g.
  /// one the user already entered by hand.
  static bool likelyDuplicate(
    StatementRow row,
    Iterable<TransactionRecord> existing,
  ) {
    final day = DateTime(row.date.year, row.date.month, row.date.day);
    return existing.any((item) {
      final local = item.date.toLocal();
      return !item.isBalanceAdjustment &&
          item.kind == row.kind &&
          item.amountMinor == row.amountMinor &&
          DateTime(local.year, local.month, local.day) == day;
    });
  }

  static TransactionRecord toTransaction(
    StatementRow row,
    CategoryRecord category,
  ) => TransactionRecord(
    id: transactionId(row),
    amountMinor: row.amountMinor,
    date: row.date,
    categoryName: category.name,
    categoryIcon: category.icon,
    categoryEmoji: category.emoji,
    categoryColorName: category.colorName,
    note: row.description,
    isBalanceAdjustment: row.isBalanceAdjustment,
    kindRawValue: row.kind.name,
    updatedAt: DateTime.now().toUtc(),
  );
}
