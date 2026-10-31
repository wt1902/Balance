import 'dart:convert';

import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/statement_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('amounts', () {
    test('parses bank formats into signed hundredths', () {
      final cases = {
        '-1 234,56': -123456,
        '1 234,5': 123450,
        '−5,00': -500,
        '1,234.56': 123456,
        '1.234,56': 123456,
        '1.234': 123400,
        '1,234,567': 123456700,
        '99.90': 9990,
        '(150.00)': -15000,
        '+42 ₽': 4200,
        '-300.00 RUB': -30000,
        '0,005': 1,
        '12,3': 1230,
      };
      for (final entry in cases.entries) {
        expect(
          StatementImport.parseSignedAmount(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('rejects text without a number', () {
      for (final value in ['', 'abc', '-', '1-2']) {
        expect(
          () => StatementImport.parseSignedAmount(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('dates', () {
    test('reads local calendar dates', () {
      expect(
        StatementImport.parseDate('05.03.2026 14:07:09'),
        DateTime(2026, 3, 5, 14, 7, 9),
      );
      expect(StatementImport.parseDate('5.3.26'), DateTime(2026, 3, 5));
      expect(StatementImport.parseDate('31/12/2025'), DateTime(2025, 12, 31));
      expect(
        StatementImport.parseDate('2026-01-02 08:30'),
        DateTime(2026, 1, 2, 8, 30),
      );
      expect(
        StatementImport.parseDate('2026-01-02T08:30:00Z'),
        DateTime.utc(2026, 1, 2, 8, 30).toLocal(),
      );
    });

    test('rejects impossible dates', () {
      for (final value in ['31.02.2026', '2026-13-01', '', 'вчера']) {
        expect(
          () => StatementImport.parseDate(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  test('CSV parser handles quotes, delimiters and line breaks', () {
    final table = StatementImport.parseCsv(
      '﻿"a";"b ""x""";c\r\n1;"line\nbreak";3\n\n',
    );
    expect(table, [
      ['a', 'b "x"', 'c'],
      ['1', 'line\nbreak', '3'],
    ]);
    expect(StatementImport.parseCsv('a,b\n1,2'), [
      ['a', 'b'],
      ['1', '2'],
    ]);
  });

  test('Windows-1251 and UTF-8 are both decoded', () {
    final cp1251 = [0xC4, 0xE0, 0xF2, 0xE0, 0x3B, 0xA8, 0xB8]; // Дата;Ёё
    expect(StatementImport.decode(cp1251), 'Дата;Ёё');
    expect(StatementImport.decode(utf8.encode('Дата')), 'Дата');
    expect(
      StatementImport.decode([0xEF, 0xBB, 0xBF, ...utf8.encode('x')]),
      'x',
    );
    // UTF-16 LE and BE with BOM, as some spreadsheet exports write CSV.
    expect(StatementImport.decode([0xFF, 0xFE, 0x14, 0x04, 0x3B, 0x00]), 'Д;');
    expect(StatementImport.decode([0xFE, 0xFF, 0x04, 0x14, 0x00, 0x3B]), 'Д;');
  });

  test('Т-Банк statement: header, declined rows, kinds and categories', () {
    const csv =
        '"Дата операции";"Дата платежа";"Номер карты";"Статус";"Сумма операции";'
        '"Валюта операции";"Сумма платежа";"Валюта платежа";"Кэшбэк";"Категория";'
        '"MCC";"Описание";"Бонусы (включая кэшбэк)"\n'
        '"05.03.2026 14:07:09";"06.03.2026";"*1234";"OK";"-1 250,00";"RUB";'
        '"-1 250,00";"RUB";"";"Супермаркеты";"5411";"Пятёрочка";"12,00"\n'
        '"05.03.2026 18:00:00";"";"*1234";"FAILED";"-99,00";"RUB";"-99,00";'
        '"RUB";"";"Такси";"4121";"Яндекс Такси";"0"\n'
        '"06.03.2026 09:00:00";"06.03.2026";"";"OK";"85 000,00";"RUB";'
        '"85 000,00";"RUB";"";"Пополнения";"";"Зарплата ООО Ромашка";"0"\n'
        '"07.03.2026 10:00:00";"07.03.2026";"*1234";"OK";"-10,00";"EUR";'
        '"-1 020,50";"RUB";"";"Аптеки";"5912";"Pharmacy";"0"\n';
    final table = StatementImport.parseCsv(csv);
    final mapping = StatementImport.tbankMapping(table.first)!;
    final result = StatementImport.readCsv(table, mapping);
    expect(result.skipped, 1);
    expect(result.problems, isEmpty);
    expect(result.rows, hasLength(3));
    final food = result.rows[0];
    expect(food.kind, TransactionKind.expense);
    expect(food.amountMinor, 125000);
    expect(food.date, DateTime(2026, 3, 5, 14, 7, 9));
    expect(result.rows[1].kind, TransactionKind.income);
    // Card-currency payment amount, not the foreign operation amount.
    expect(result.rows[2].amountMinor, 102050);
    String category(StatementRow row) => StatementImport.suggestCategory(
      row,
      BuiltInCategories.forKind(row.kind.name),
    ).name;
    expect(result.rows.map(category), ['Продукты', 'Зарплата', 'Здоровье']);
  });

  test('generic mapping guess, inverted sign and row problems', () {
    final table = StatementImport.parseCsv(
      'Date,Description,Amount\n'
      '2026-02-01,Coffee,4.50\n'
      'oops,Broken,1\n'
      '2026-02-02,Refund,-10\n',
    );
    final mapping = StatementImport.guessMapping(table.first);
    expect(mapping.date, 0);
    expect(mapping.amount, 2);
    expect(mapping.description, 1);
    final result = StatementImport.readCsv(
      table,
      mapping.copyWith(invertSign: true),
    );
    expect(result.rows.map((r) => r.kind), [
      TransactionKind.expense,
      TransactionKind.income,
    ]);
    expect(result.problems.single, startsWith('Строка 3:'));
  });

  test('OFX SGML and XML transactions', () {
    const sgml =
        'OFXHEADER:100\nDATA:OFXSGML\n<OFX><BANKTRANLIST>\n'
        '<STMTTRN>\n<TRNTYPE>DEBIT\n<DTPOSTED>20260310120000[+3:MSK]\n'
        '<TRNAMT>-450.00\n<FITID>A1\n<NAME>Аптека\n<MEMO>Аптека\n'
        '<STMTTRN>\n<TRNTYPE>CREDIT\n<DTPOSTED>20260311\n<TRNAMT>1000\n'
        '<FITID>A2\n<NAME>Перевод\n<MEMO>от друга &amp; коллеги\n'
        '</BANKTRANLIST></OFX>';
    expect(StatementImport.looksLikeOfx(sgml), isTrue);
    final result = StatementImport.readOfx(sgml);
    expect(result.rows, hasLength(2));
    expect(result.rows[0].date, DateTime(2026, 3, 10, 12));
    expect(result.rows[0].description, 'Аптека');
    expect(result.rows[1].description, 'Перевод · от друга & коллеги');
    expect(result.rows[1].importKey, 'ofx|A2');

    const xml =
        '<?xml version="1.0"?><OFX><STMTTRN><DTPOSTED>20260312</DTPOSTED>'
        '<TRNAMT>-1.5</TRNAMT><FITID>X</FITID><NAME>Bus</NAME></STMTTRN></OFX>';
    final xmlResult = StatementImport.readOfx(xml);
    expect(xmlResult.rows.single.amountMinor, 150);
    expect(xmlResult.rows.single.description, 'Bus');
  });

  test('stable ids keep identical rows apart and re-imports equal', () {
    const csv =
        'Дата;Сумма;Описание\n01.02.2026;-100;Кофе\n01.02.2026;-100;Кофе\n';
    List<String> ids() {
      final table = StatementImport.parseCsv(csv);
      return StatementImport.readCsv(
        table,
        StatementImport.guessMapping(table.first),
      ).rows.map(StatementImport.transactionId).toList();
    }

    final first = ids();
    expect(first.toSet(), hasLength(2));
    expect(ids(), first);
  });

  test('likely duplicate matches kind, amount and local day', () {
    final row = StatementRow(
      date: DateTime(2026, 2, 1, 23, 30),
      amountMinor: 10000,
      kind: TransactionKind.expense,
      description: 'Кофе',
      importKey: 'k',
    );
    TransactionRecord existing(DateTime date, {String kind = 'expense'}) =>
        TransactionRecord(
          id: 'x',
          amountMinor: 10000,
          date: date,
          categoryName: 'Продукты',
          updatedAt: date,
          kindRawValue: kind,
        );
    expect(
      StatementImport.likelyDuplicate(row, [existing(DateTime(2026, 2, 1, 9))]),
      isTrue,
    );
    expect(
      StatementImport.likelyDuplicate(row, [existing(DateTime(2026, 2, 2))]),
      isFalse,
    );
    expect(
      StatementImport.likelyDuplicate(row, [
        existing(DateTime(2026, 2, 1), kind: 'income'),
      ]),
      isFalse,
    );
  });

  test('custom category with the bank category name wins', () {
    final custom = CategoryRecord(
      id: 'c',
      name: 'Супермаркеты',
      icon: 'cart.fill',
      colorName: 'green',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    final row = StatementRow(
      date: DateTime(2026),
      amountMinor: 1,
      kind: TransactionKind.expense,
      description: 'Магнит',
      bankCategory: 'супермаркеты',
      importKey: 'k',
    );
    expect(
      StatementImport.suggestCategory(row, [
        ...BuiltInCategories.expense,
        custom,
      ]).id,
      'c',
    );
  });

  test('own CSV export round-trips every transaction field', () {
    final updated = DateTime.utc(2026, 3, 1, 12);
    final records = [
      TransactionRecord(
        id: 'a1',
        amountMinor: 123456,
        date: DateTime.utc(2026, 2, 28, 21, 15, 30, 123),
        categoryName: 'Кафе, бары',
        categoryIcon: 'cup.and.saucer.fill',
        categoryEmoji: '☕️',
        categoryColorName: 'brown',
        note: '=SUM(A1) "ужин"\nс друзьями',
        updatedAt: updated,
      ),
      TransactionRecord(
        id: 'adj',
        amountMinor: 50,
        date: DateTime.utc(2026, 2, 1),
        categoryName: 'Корректировка',
        note: '-сверка',
        isBalanceAdjustment: true,
        updatedAt: updated,
      ),
      TransactionRecord(
        id: 'inc',
        amountMinor: 1,
        date: DateTime.utc(2026, 1, 1),
        categoryName: 'Зарплата',
        kindRawValue: 'income',
        note: "'@важно",
        updatedAt: updated,
      ),
    ];
    final bytes = utf8.encode(FinanceMath.exportCsv(records));
    final table = StatementImport.parseCsv(StatementImport.decode(bytes));
    expect(StatementImport.isBalanceExport(table.first), isTrue);
    expect(StatementImport.tbankMapping(table.first), isNull);
    final result = StatementImport.readBalanceCsv(table);
    expect(result.problems, isEmpty);
    expect(result.format, 'Баланс, CSV');
    final restored = {
      for (final row in result.rows)
        StatementImport.transactionId(row): StatementImport.toTransaction(
          row,
          StatementImport.suggestCategory(row, BuiltInCategories.expense),
        ),
    };
    for (final original in records) {
      final copy = restored[original.id]!;
      expect(copy.payload(), original.payload(), reason: original.id);
    }
  });
}
