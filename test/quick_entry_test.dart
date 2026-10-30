import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/templates.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/services/widget_summary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  final now = DateTime(2026, 10, 30, 12);
  TransactionRecord tx(
    String id,
    int amount, {
    DateTime? date,
    String category = 'Продукты',
    String note = '',
    String kind = 'expense',
    bool adjustment = false,
  }) => TransactionRecord(
    id: id,
    amountMinor: amount,
    date: date ?? now,
    categoryName: category,
    note: note,
    kindRawValue: kind,
    isBalanceAdjustment: adjustment,
    updatedAt: now,
  );

  group('frequent', () {
    test('needs two repeats in 90 days and ranks by count, then recency', () {
      final items = [
        tx(
          'c1',
          25000,
          note: 'Кофе',
          date: now.subtract(const Duration(days: 1)),
        ),
        tx(
          'c2',
          25000,
          note: 'Кофе',
          date: now.subtract(const Duration(days: 2)),
        ),
        tx(
          'c3',
          25000,
          note: 'Кофе',
          date: now.subtract(const Duration(days: 3)),
        ),
        tx('m1', 6000, category: 'Транспорт', date: now),
        tx('m2', 6000, category: 'Транспорт', date: now),
        tx('o1', 99, note: 'Однажды'),
        // Too old to count.
        tx(
          'x1',
          500,
          note: 'Старое',
          date: now.subtract(const Duration(days: 120)),
        ),
        tx(
          'x2',
          500,
          note: 'Старое',
          date: now.subtract(const Duration(days: 121)),
        ),
        // Adjustments are not spending.
        tx('a1', 100, adjustment: true),
        tx('a2', 100, adjustment: true),
      ];
      final result = TransactionTemplate.frequent(items, now);
      expect(result.map((t) => t.title), ['Кофе', 'Транспорт']);
      expect(result.first.amountMinor, 25000);
      expect(result.first.kind, TransactionKind.expense);
      expect(TransactionTemplate.frequent(items, now, limit: 1), hasLength(1));
    });

    test('kind is part of the preset', () {
      final items = [
        tx('e', 1000, note: 'Перевод'),
        tx('i', 1000, note: 'Перевод', kind: 'income'),
      ];
      expect(TransactionTemplate.frequent(items, now), isEmpty);
    });
  });

  test('template json round trip and repeat copy', () {
    final source = TransactionRecord(
      id: 'src',
      amountMinor: 12345,
      date: now,
      categoryName: 'Кафе',
      categoryIcon: 'cup.and.saucer.fill',
      categoryEmoji: '☕️',
      categoryColorName: 'brown',
      note: 'Обед',
      kindRawValue: 'expense',
      updatedAt: now,
    );
    final template = TransactionTemplate.fromTransaction('t', source);
    final copy = TransactionTemplate.fromJson(template.toJson());
    expect(copy.toJson(), template.toJson());
    expect(copy.signature, 'expense|Кафе|12345|Обед');
    expect(
      () => TransactionTemplate.fromJson({'id': 'x', 'amountMinor': -1}),
      throwsFormatException,
    );
    final blank = TransactionTemplate.blank(TransactionKind.income);
    expect(blank.kindRawValue, 'income');
    expect(blank.amountMinor, 0);
    expect(blank.categoryName, BuiltInCategories.income.first.name);
  });

  test('templates are device preferences, deduplicated and capped', () async {
    final store = AppStore(storage: MemorySnapshotStorage());
    await store.initialize();
    TransactionTemplate template(String id, int amount) =>
        TransactionTemplate.fromTransaction(id, tx(id, amount));
    await store.saveTemplate(template('a', 100));
    await store.saveTemplate(template('b', 200));
    // Same preset under a new id replaces the old one and moves to the front.
    await store.saveTemplate(template('a2', 100));
    expect(store.templates.map((t) => t.id), ['a2', 'b']);
    for (var i = 0; i < 15; i++) {
      await store.saveTemplate(template('n$i', 1000 + i));
    }
    expect(store.templates, hasLength(12));
    expect(store.templates.first.id, 'n14');
    await store.deleteTemplate('n14');
    expect(store.templates.first.id, 'n13');
    // Templates never enter the synced ledger.
    expect(store.pendingChangeCount, 0);
    final reopened = AppStore(storage: MemorySnapshotStorage());
    await reopened.initialize();
    expect(reopened.templates, hasLength(11));
    store.dispose();
    reopened.dispose();
  });

  group('widget summary', () {
    test('balance, month expenses and current month budgets', () {
      final summary = widgetSummary(
        transactions: [
          tx('i', 10000000, kind: 'income'),
          tx('e', 1500000),
          tx('old', 500000, date: DateTime(2026, 9, 15)),
          // Adjustments count in the balance only.
          tx('adj', 100000, adjustment: true),
        ],
        budgets: [
          BudgetRecord(
            id: 'b',
            categoryName: 'Продукты',
            limitMinor: 2000000,
            monthStart: DateTime(2026, 10),
            updatedAt: now,
          ),
          BudgetRecord(
            id: 'other-month',
            categoryName: 'Продукты',
            limitMinor: 1,
            monthStart: DateTime(2026, 9),
            updatedAt: now,
          ),
        ],
        currency: 'RUB',
        now: now,
      );
      String plain(String key) => summary[key]!.replaceAll(' ', ' ');
      expect(plain('widget.balance'), '79 000,00 ₽');
      expect(plain('widget.monthExpenses'), '15 000,00 ₽');
      expect(
        plain('widget.budget'),
        'Остаток бюджета: 5 000,00 ₽ из 20 000,00 ₽',
      );
    });

    test('over budget and no budgets', () {
      String budget(List<BudgetRecord> budgets) => widgetSummary(
        transactions: [tx('e', 30000)],
        budgets: budgets,
        currency: 'EUR',
        now: now,
      )['widget.budget']!.replaceAll(' ', ' ');
      expect(budget(const []), 'Бюджеты на месяц не заданы');
      expect(
        budget([
          BudgetRecord(
            id: 'b',
            categoryName: 'Продукты',
            limitMinor: 10000,
            monthStart: DateTime(2026, 10),
            updatedAt: now,
          ),
        ]),
        'Бюджет превышен на 200,00 €',
      );
    });

    test('store publishes the summary to shared preferences', () async {
      final store = AppStore(storage: MemorySnapshotStorage());
      await store.initialize();
      await store.saveTransaction(tx('e', 4200, date: DateTime.now()));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('widget.monthExpenses'), contains('42,00'));
      expect(prefs.getString('widget.balance'), contains('-42,00'));
      store.dispose();
    });
  });
}
