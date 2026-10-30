import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/money_format.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:balance_flutter/ui/transactions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show loadReadableFont, navigate;

const sizes = [Size(320, 568), Size(390, 844), Size(1280, 900)];

TransactionRecord tx(
  String note,
  int minor,
  DateTime date, {
  String kind = 'expense',
  String category = 'Продукты',
  bool adjustment = false,
}) => TransactionRecord(
  id: note,
  amountMinor: minor,
  date: date,
  categoryName: category,
  note: note,
  kindRawValue: kind,
  isBalanceAdjustment: adjustment,
  updatedAt: DateTime.now(),
);

DateTime get today {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

DateTime get lastMonthDay {
  final n = DateTime.now();
  return DateTime(n.year, n.month - 1, 15, 12);
}

List<TransactionRecord> standardSeed() {
  final n = DateTime.now();
  return [
    tx('zz-obed', 150000, today.add(const Duration(hours: 12))),
    tx(
      'zz-taxi',
      30000,
      today.add(const Duration(hours: 11)),
      category: 'Транспорт',
    ),
    tx(
      'zz-pay',
      500000,
      DateTime(n.year, n.month, 1, 10),
      kind: 'income',
      category: 'Зарплата',
    ),
    tx('zz-old', 9990, lastMonthDay),
  ];
}

Future<AppStore> boot(
  WidgetTester tester,
  Size size,
  List<TransactionRecord> seed,
) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  late final AppStore store;
  await tester.runAsync(() async {
    store = AppStore(storage: MemorySnapshotStorage());
    await store.initialize();
    await store.importTransactions(seed);
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(BalanceApp(store: store));
  await tester.pumpAndSettle();
  await navigate(tester, 1);
  return store;
}

Future<void> finish(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox());
  store.dispose();
}

void noError(WidgetTester tester) => expect(tester.takeException(), isNull);

// Only list tiles: the search field also contains typed text.
Finder note(String n) =>
    find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(n));

Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> openSheet(WidgetTester tester) async {
  await tapVisible(tester, find.text('Фильтры'));
  expect(find.byType(TransactionFilterSheet), findsOneWidget);
}

Future<void> apply(WidgetTester tester) async {
  await tapVisible(tester, find.text('Применить'));
  expect(find.byType(TransactionFilterSheet), findsNothing);
}

Finder badge(String count) =>
    find.descendant(of: find.byType(Badge), matching: find.text(count));

Future<void> fill(WidgetTester tester, String label, String text) async {
  final f = find.widgetWithText(TextField, label);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.enterText(f, text);
  await tester.pump();
}

List<String> tileNotes(WidgetTester tester) => [
  for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
    if (t.subtitle is Text) (t.subtitle! as Text).data!,
];

void main() {
  setUpAll(loadReadableFont);

  for (final size in sizes) {
    testWidgets('category filter, badge and chip at $size', (tester) async {
      final store = await boot(tester, size, standardSeed());
      expect(note('zz-obed'), findsOneWidget);
      await openSheet(tester);
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Транспорт'));
      await apply(tester);
      expect(note('zz-taxi'), findsOneWidget);
      expect(note('zz-obed'), findsNothing);
      expect(note('zz-pay'), findsNothing);
      expect(badge('1'), findsOneWidget);
      final chip = find.widgetWithText(InputChip, 'Транспорт');
      expect(chip, findsOneWidget);
      expect(find.textContaining('Найдено: 1'), findsOneWidget);
      noError(tester);
      await tester.tap(
        find.descendant(of: chip, matching: find.byIcon(Icons.clear)),
      );
      await tester.pumpAndSettle();
      expect(chip, findsNothing);
      expect(badge('1'), findsNothing);
      expect(note('zz-obed'), findsOneWidget);
      expect(note('zz-taxi'), findsOneWidget);
      noError(tester);
      await finish(tester, store);
    });

    testWidgets('amount range is inclusive and validated at $size', (
      tester,
    ) async {
      final store = await boot(tester, size, standardSeed());
      await openSheet(tester);
      await fill(tester, 'От', '300');
      await fill(tester, 'До', '1500');
      await apply(tester);
      expect(note('zz-obed'), findsOneWidget);
      expect(note('zz-taxi'), findsOneWidget);
      expect(note('zz-pay'), findsNothing);
      expect(note('zz-old'), findsNothing);
      expect(badge('1'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Транспорт'), findsNothing);
      noError(tester);

      await openSheet(tester);
      await fill(tester, 'От', '2000');
      await fill(tester, 'До', '100');
      await tapVisible(tester, find.text('Применить'));
      expect(find.text('«От» больше, чем «до»'), findsOneWidget);
      expect(find.byType(TransactionFilterSheet), findsOneWidget);
      noError(tester);
      await fill(tester, 'От', '10');
      await fill(tester, 'До', '100');
      await apply(tester);
      expect(note('zz-old'), findsOneWidget);
      expect(note('zz-obed'), findsNothing);
      noError(tester);
      await finish(tester, store);
    });

    testWidgets('last month period at $size', (tester) async {
      final store = await boot(tester, size, standardSeed());
      await openSheet(tester);
      await tapVisible(
        tester,
        find.widgetWithText(ChoiceChip, 'Прошлый месяц'),
      );
      await apply(tester);
      expect(note('zz-old'), findsOneWidget);
      expect(note('zz-obed'), findsNothing);
      expect(note('zz-taxi'), findsNothing);
      expect(note('zz-pay'), findsNothing);
      expect(find.widgetWithText(InputChip, 'Прошлый месяц'), findsOneWidget);
      expect(badge('1'), findsOneWidget);
      noError(tester);
      await finish(tester, store);
    });

    testWidgets('largest-first sort has no day headers at $size', (
      tester,
    ) async {
      final store = await boot(tester, size, standardSeed());
      expect(find.byType(DayPanel), findsWidgets);
      await tester.tap(find.byTooltip('Сортировка'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сначала крупные').last);
      await tester.pumpAndSettle();
      expect(find.byType(DayPanel), findsNothing);
      expect(find.byType(PlainPanel), findsOneWidget);
      final order = tileNotes(tester);
      expect(order.length, 4);
      expect(order[0], contains('zz-pay'));
      expect(order[1], contains('zz-obed'));
      expect(order[2], contains('zz-taxi'));
      expect(order[3], contains('zz-old'));
      noError(tester);
      await finish(tester, store);
    });

    testWidgets('day totals exclude balance adjustments at $size', (
      tester,
    ) async {
      final day = lastMonthDay;
      final store = await boot(tester, size, [
        tx('zz-in', 200000, day, kind: 'income', category: 'Зарплата'),
        tx('zz-out', 50000, day.add(const Duration(hours: 1))),
        tx(
          'zz-adj',
          700000,
          day.add(const Duration(hours: 2)),
          kind: 'income',
          adjustment: true,
        ),
      ]);
      final header = DateFormat('d MMMM y, EEE', 'ru').format(day);
      expect(find.text(header), findsOneWidget);
      final plus = '+${money(200000, store.currency)}';
      final minus = '−${money(50000, store.currency)}';
      final adj = '+${money(700000, store.currency)}';
      // Header total plus the tile amount.
      expect(find.text(plus), findsNWidgets(2));
      expect(find.text(minus), findsNWidgets(2));
      // Only the adjustment tile: it never reaches the day total.
      expect(find.text(adj), findsOneWidget);
      noError(tester);
      await finish(tester, store);
    });

    testWidgets('empty result and reset at $size', (tester) async {
      final store = await boot(tester, size, standardSeed());
      await openSheet(tester);
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Транспорт'));
      await apply(tester);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'zz-obed');
      await tester.pumpAndSettle();
      expect(find.text('Ничего не найдено'), findsOneWidget);
      expect(find.byType(DayPanel), findsNothing);
      noError(tester);
      await tapVisible(tester, find.text('Сбросить фильтры'));
      expect(find.text('Ничего не найдено'), findsNothing);
      // The search box is cleared together with the filter.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        isEmpty,
      );
      expect(badge('1'), findsNothing);
      expect(note('zz-obed'), findsOneWidget);
      expect(note('zz-taxi'), findsOneWidget);
      noError(tester);
      await finish(tester, store);
    });
  }
}
