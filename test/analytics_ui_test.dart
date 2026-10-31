import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show loadReadableFont, navigate;

const sizes = [Size(320, 568), Size(390, 844), Size(1280, 900)];

TransactionRecord tx(
  String id,
  int minor,
  DateTime date, {
  String kind = 'expense',
  String category = 'Продукты',
}) => TransactionRecord(
  id: id,
  amountMinor: minor,
  date: date,
  categoryName: category,
  kindRawValue: kind,
  updatedAt: DateTime.now(),
);

Future<AppStore> seeded(WidgetTester tester) async {
  final store = AppStore(storage: MemorySnapshotStorage());
  await tester.runAsync(() async {
    await store.initialize();
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    await store.saveTransaction(tx('a', 120000, month));
    await store.saveTransaction(
      tx('b', 300000, month, kind: 'income', category: 'Зарплата'),
    );
    await store.saveTransaction(
      tx('c', 50000, DateTime(now.year, now.month - 1), category: 'Транспорт'),
    );
    await store.saveTransaction(
      tx('d', 70000, DateTime(now.year, now.month - 3)),
    );
    await store.saveBudget(
      BudgetRecord(
        id: 'budget',
        categoryName: 'Продукты',
        limitMinor: 100,
        monthStart: month,
        updatedAt: now,
      ),
    );
  });
  return store;
}

Future<void> boot(WidgetTester tester, AppStore store, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(store.dispose);
  await tester.pumpWidget(BalanceApp(store: store));
  await tester.pumpAndSettle();
  await navigate(tester, 2);
}

Future<void> scrollTo(
  WidgetTester tester,
  Finder finder, {
  double delta = 300,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadReadableFont);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final size in sizes) {
    testWidgets('month shows comparison and budget forecast at $size', (
      tester,
    ) async {
      final store = await seeded(tester);
      await boot(tester, store, size);
      await scrollTo(tester, find.text('Сравнение с прошлым периодом'));
      // 12.00 this month against 5.00 on the 1st of the previous one.
      await scrollTo(tester, find.textContaining('Расходы на 140% выше'));
      await scrollTo(tester, find.textContaining('Нет доходов'));
      await scrollTo(tester, find.text('Прогноз до конца месяца'));
      await scrollTo(
        tester,
        find.textContaining('Бюджеты месяца уже исчерпаны'),
      );
      await scrollTo(tester, find.text('Динамика категории'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('year report and every period at $size', (tester) async {
      final store = await seeded(tester);
      await boot(tester, store, size);
      for (final label in ['3 месяца', '12 месяцев', 'Год']) {
        await tester.tap(find.widgetWithText(ChoiceChip, label));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
      expect(find.text('${DateTime.now().year}'), findsOneWidget);
      await scrollTo(tester, find.text('Итоги года'));
      await scrollTo(tester, find.text('Самый затратный месяц'));
      await scrollTo(tester, find.byTooltip('Предыдущий год'), delta: -300);
      await tester.tap(find.byTooltip('Предыдущий год'));
      await tester.pumpAndSettle();
      expect(find.text('${DateTime.now().year - 1}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('custom range opens a date picker', (tester) async {
    final store = await seeded(tester);
    await boot(tester, store, const Size(390, 844));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Период'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
