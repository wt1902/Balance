import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/transaction_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TransactionRecord tx(
    String id,
    int amount,
    DateTime date, {
    String category = 'Продукты',
    String note = '',
    String kind = 'expense',
    bool adjustment = false,
  }) => TransactionRecord(
    id: id,
    amountMinor: amount,
    date: date,
    categoryName: category,
    note: note,
    kindRawValue: kind,
    isBalanceAdjustment: adjustment,
    updatedAt: date,
  );
  final items = [
    tx('a', 1500, DateTime(2026, 10, 30, 9), note: 'Пятёрочка'),
    tx(
      'b',
      300000,
      DateTime(2026, 10, 30, 12),
      category: 'Зарплата',
      kind: 'income',
    ),
    tx(
      'c',
      50000,
      DateTime(2026, 10, 1),
      category: 'Транспорт',
      note: 'Каршеринг',
    ),
    tx('d', 1500, DateTime(2026, 9, 30, 23, 59), category: 'Транспорт'),
    tx('e', 9900, DateTime(2026, 11, 1), category: 'Кафе'),
    tx(
      'adj',
      700,
      DateTime(2026, 10, 30, 18),
      category: 'Корректировка',
      adjustment: true,
    ),
  ];
  List<String> ids(TransactionFilter f) =>
      f.apply(items).map((t) => t.id).toList();

  test('default shows everything newest first', () {
    expect(ids(const TransactionFilter()), ['e', 'adj', 'b', 'a', 'c', 'd']);
    expect(const TransactionFilter().activeCount, 0);
  });

  test('period is half-open [start, end)', () {
    final october = TransactionFilter(
      start: DateTime(2026, 10),
      endExclusive: DateTime(2026, 11),
    );
    expect(ids(october), ['adj', 'b', 'a', 'c']);
    expect(october.activeCount, 1);
    expect(ids(october.withoutPeriod()), hasLength(items.length));
  });

  test('amount bounds are inclusive and combine with other filters', () {
    final f = const TransactionFilter(minMinor: 1500, maxMinor: 9900);
    expect(ids(f), ['e', 'a', 'd']);
    expect(ids(f.copyWith(categories: {'Транспорт'}, kind: 'expense')), ['d']);
    expect(f.copyWith(categories: {'Транспорт'}).activeCount, 2);
    expect(ids(f.withoutAmount()), hasLength(items.length));
  });

  test('search ignores case and looks at category and note', () {
    expect(ids(const TransactionFilter(query: 'пятёр')), ['a']);
    expect(ids(const TransactionFilter(query: 'ТРАНСПОРТ')), ['c', 'd']);
    expect(ids(const TransactionFilter(query: '  каршеринг ')), ['c']);
    expect(ids(const TransactionFilter(kind: 'income')), ['b']);
  });

  test('amount sorts break ties newest first', () {
    expect(ids(const TransactionFilter(sort: TransactionSort.largest)), [
      'b',
      'c',
      'e',
      'a',
      'd',
      'adj',
    ]);
    expect(ids(const TransactionFilter(sort: TransactionSort.smallest)), [
      'adj',
      'a',
      'd',
      'e',
      'c',
      'b',
    ]);
    expect(
      ids(const TransactionFilter(sort: TransactionSort.oldest)).first,
      'd',
    );
    expect(TransactionSort.largest.byDate, isFalse);
  });

  test('day groups and totals leave adjustments out', () {
    final groups = DayGroup.group(const TransactionFilter().apply(items));
    expect(groups.map((g) => g.day), [
      DateTime(2026, 11, 1),
      DateTime(2026, 10, 30),
      DateTime(2026, 10, 1),
      DateTime(2026, 9, 30),
    ]);
    final day = groups[1];
    expect(day.items.map((t) => t.id), ['adj', 'b', 'a']);
    expect(day.incomeMinor, 300000);
    expect(day.expenseMinor, 1500);
    expect(day.netMinor, 298500);
    final totals = DayGroup.totals(items);
    expect(totals.incomeMinor, 300000);
    expect(totals.expensesMinor, 1500 + 50000 + 1500 + 9900);
  });

  test('period presets', () {
    final now = DateTime(2026, 1, 15, 10);
    expect(PeriodPreset.thisMonth.range(now), (
      DateTime(2026, 1),
      DateTime(2026, 2),
    ));
    expect(PeriodPreset.lastMonth.range(now), (
      DateTime(2025, 12),
      DateTime(2026, 1),
    ));
    expect(PeriodPreset.threeMonths.range(now), (
      DateTime(2025, 11),
      DateTime(2026, 2),
    ));
    expect(PeriodPreset.thisYear.range(now), (DateTime(2026), DateTime(2027)));
  });
}
