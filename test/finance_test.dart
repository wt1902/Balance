import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:balance_flutter/domain/finance.dart';

void main() {
  final january = DateTime.utc(2026, 1);
  final february = DateTime.utc(2026, 2);
  TransactionRecord record(
    String id,
    int amount, {
    String kind = 'expense',
    DateTime? date,
    bool adjustment = false,
    String category = 'Продукты',
    String note = '',
  }) => TransactionRecord(
    id: id,
    amountMinor: amount,
    date: date ?? january,
    categoryName: category,
    updatedAt: january,
    kindRawValue: kind,
    isBalanceAdjustment: adjustment,
    note: note,
  );

  test('money input is exact and rejects invalid precision', () {
    expect(parseMoney(' 123,45 '), 12345);
    expect(parseMoney('0.1'), 10);
    expect(parseMoney('10'), 1000);
    expect(formatMinor(-101), '-1.01');
    for (final invalid in ['-1', 'NaN', '1.001', '1e3', '']) {
      expect(() => parseMoney(invalid), throwsFormatException);
    }
    expect(() => moneyToMinor(double.infinity), throwsFormatException);
  });

  test(
    'wire payload preserves native keys, double money and UTC timestamps',
    () {
      final original = record('test', 12345, note: 'Кофе');
      final payload = original.payload();
      expect(payload['amount'], 123.45);
      expect(payload['kindRawValue'], 'expense');
      expect(payload.containsKey('id'), isFalse);
      expect(payload['date'], '2026-01-01T00:00:00.000Z');
      final roundTrip = TransactionRecord.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.amountMinor, 12345);
      expect(roundTrip.note, 'Кофе');
      expect(roundTrip.updatedAt, january);
      expect(roundTrip.copyWith(amountMinor: 10).id, 'test');
      expect(original.amountMinor, 12345);
    },
  );

  test('local JSON keeps exact minor integers independent of wire doubles', () {
    const largeMinor = 9007199254740901;
    final transaction = record('large', largeMinor);
    final restored = TransactionRecord.fromJson(
      jsonDecode(jsonEncode(transaction.toJson())) as Map<String, dynamic>,
    );
    expect(restored.amountMinor, largeMinor);
    expect(transaction.payload().containsKey('amountMinor'), isFalse);
    final budget = BudgetRecord(
      id: 'large-budget',
      categoryName: 'Дом',
      limitMinor: largeMinor,
      monthStart: january,
      updatedAt: january,
    );
    expect(
      BudgetRecord.fromJson(
        jsonDecode(jsonEncode(budget.toJson())) as Map<String, dynamic>,
      ).limitMinor,
      largeMinor,
    );
    expect(budget.payload().containsKey('limitMinor'), isFalse);
  });

  test('native fractional RFC3339 with timezone is supported', () {
    final payload = record('test', 10).payload()
      ..['date'] = '2026-01-01T03:00:00.123456789+03:00';
    final item = TransactionRecord.fromPayload(
      id: 'test',
      updatedAt: january,
      payload: payload,
    );
    expect(item.date.toUtc(), DateTime.utc(2026, 1, 1, 0, 0, 0, 123, 456));
  });

  test(
    'summary uses half-open period and excludes adjustments; balance includes them',
    () {
      final items = [
        record('a', 10),
        record('b', 20),
        record('c', 100, kind: 'income'),
        record('d', 200, kind: 'income', adjustment: true),
        record('e', 1000, date: february),
        record(
          'f',
          500,
          date: january.subtract(const Duration(microseconds: 1)),
        ),
      ];
      expect(FinanceMath.totalBalance(items), -1230);
      final summary = FinanceMath.summary(items, january, february);
      expect(summary.incomeMinor, 100);
      expect(summary.expensesMinor, 30);
      expect(summary.balanceMinor, 70);
    },
  );

  test('decimal accumulation is exact for repeated hundredths', () {
    final items = List.generate(100, (i) => record('$i', 10));
    expect(FinanceMath.summary(items, january, february).expensesMinor, 1000);
    expect(FinanceMath.totalBalance(items), -1000);
  });

  test(
    'category spending groups names, orders amounts, excludes adjustments',
    () {
      final items = [
        record('a', 100, category: 'Дом'),
        record('b', 150),
        record('c', 100, category: 'Дом'),
        record('d', 999, adjustment: true),
        record('e', 999, kind: 'income'),
      ];
      final totals = FinanceMath.spending(items, january, february);
      expect(totals.map((x) => x.name), ['Дом', 'Продукты']);
      expect(totals.map((x) => x.amountMinor), [200, 150]);
    },
  );

  test('monthly trend fills empty months and handles year boundary', () {
    final trend = FinanceMath.monthlyTrend(
      [record('a', 300)],
      february,
      months: 3,
    );
    expect(trend.map((x) => x.month), [
      DateTime.utc(2025, 12),
      january,
      february,
    ]);
    expect(trend.map((x) => x.summary.expensesMinor), [0, 300, 0]);
    expect(
      FinanceMath.nextMonth(DateTime.utc(2024, 12)),
      DateTime.utc(2025, 1),
    );
  });

  test('budget uses matching category expenses in its own calendar month', () {
    final budget = BudgetRecord(
      id: 'budget',
      categoryName: 'Продукты',
      limitMinor: 1000,
      monthStart: DateTime.utc(2026, 1, 12),
      updatedAt: january,
    );
    final items = [
      record('a', 300),
      record('b', 800, category: 'Дом'),
      record('c', 999, kind: 'income'),
      record('d', 999, date: february),
      record('e', 999, adjustment: true),
    ];
    expect(FinanceMath.budgetUsed(budget, items), 300);
    expect(BudgetRecord.fromJson(budget.toJson()).limitMinor, 1000);
    expect(budget.payload()['limit'], 10.0);
  });

  test('wire budget month is interpreted in the local calendar', () {
    final localJanuary = DateTime(2026, 1);
    final localExpense = DateTime(2026, 1, 15);
    final localDecember = DateTime(2025, 12, 15);
    final original = BudgetRecord(
      id: 'wire-budget',
      categoryName: 'Продукты',
      limitMinor: 10000,
      monthStart: localJanuary,
      updatedAt: january,
    );
    final imported = BudgetRecord.fromJson(original.toJson());
    expect(imported.monthStart.isUtc, isTrue);
    final items = [
      record('jan', 300, date: localExpense.toUtc()),
      record('dec', 900, date: localDecember.toUtc()),
    ];
    expect(FinanceMath.budgetUsed(imported, items), 300);
  });

  test('category and tombstone round trip with protocol fields', () {
    final category = BuiltInCategories.income.first;
    expect(
      CategoryRecord.fromJson(category.toJson()).kind,
      TransactionKind.income,
    );
    final tombstone = Tombstone(
      entity: 'transaction',
      id: 'deleted',
      updatedAt: january,
    );
    expect(tombstone.toJson()['deleted'], isTrue);
    expect(tombstone.toJson().containsKey('payload'), isFalse);
    expect(Tombstone.fromJson(tombstone.toJson()).recordID, 'deleted');
  });

  test('design catalog matches native apps', () {
    expect(CategoryDesignOptions.icons.length, 50);
    expect(CategoryDesignOptions.colors.length, 24);
    expect(CategoryDesignOptions.emojis.length, 30);
    expect(BuiltInCategories.expense.length, 9);
    expect(BuiltInCategories.income.length, 5);
  });

  test('CSV quotes commas, double quotes, newlines and includes adjustments', () {
    final csv = FinanceMath.exportCsv([
      record('a', 123, note: 'кофе, "чай"\nеда'),
      record(
        'b',
        400,
        date: january.add(const Duration(days: 1)),
        adjustment: true,
      ),
    ]);
    expect(
      csv,
      startsWith(
        '\uFEFFДата,Тип,Категория,Сумма,Заметка,ID,Вид,Иконка,Эмодзи,Цвет,Изменено\n',
      ),
    );
    expect(csv, contains('"кофе, ""чай""\nеда"'));
    expect(csv, contains('"1.23"'));
    expect(csv.indexOf('Корректировка'), lessThan(csv.indexOf('кофе')));
    expect(FinanceMath.escapeCsv('a\rb'), '"a\rb"');
  });

  test('CSV disarms formulas reversibly', () {
    for (final value in [
      '=SUM(A1)',
      '+7',
      '-5',
      '@x',
      '\tx',
      "'quoted",
      "'=x",
    ]) {
      final cell = FinanceMath.csvCell(value);
      expect(cell, startsWith("'"), reason: value);
      expect(FinanceMath.csvValue(cell), value, reason: value);
    }
    for (final value in ['кофе', '12.50', '', "it's"]) {
      expect(FinanceMath.csvCell(value), value);
      expect(FinanceMath.csvValue(value), value);
    }
  });
}
