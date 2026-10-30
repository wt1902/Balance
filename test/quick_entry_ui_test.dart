import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/templates.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:balance_flutter/ui/editors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sizes = [Size(320, 568), Size(390, 844), Size(1280, 900)];
const launchChannel = MethodChannel('balance/launch');

TransactionRecord record(String id, {DateTime? date, String note = 'Кофе'}) {
  final category = BuiltInCategories.expense.first;
  final when = date ?? DateTime.now();
  return TransactionRecord(
    id: id,
    amountMinor: 35000,
    kindRawValue: 'expense',
    date: when,
    categoryName: category.name,
    categoryIcon: category.icon,
    categoryColorName: category.colorName,
    note: note,
    updatedAt: when,
  );
}

Future<AppStore> createStore(
  WidgetTester tester,
  List<TransactionRecord> items,
) async {
  final store = (await tester.runAsync(() async {
    final store = AppStore(storage: MemorySnapshotStorage());
    await store.initialize();
    for (final item in items) {
      await store.saveTransaction(item);
    }
    return store;
  }))!;
  addTearDown(store.dispose);
  return store;
}

Future<void> boot(WidgetTester tester, AppStore store, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(BalanceApp(store: store));
  await tester.pumpAndSettle();
}

Future<void> openTransactions(WidgetTester tester) async {
  final navigation = find.byType(NavigationBar).evaluate().isNotEmpty
      ? find.byType(NavigationBar)
      : find.byType(NavigationRail);
  await tester.tap(
    find
        .descendant(
          of: navigation,
          matching: find.byIcon(Icons.receipt_long_outlined),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

/// Scrolls [finder] clear of the floating «Операция» button before tapping.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.2);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> openRowMenu(WidgetTester tester) async {
  // On 320px the floating «Операция» button covers the bottom row's menu.
  final menu = find.byTooltip('Действия с операцией').first;
  await Scrollable.ensureVisible(tester.element(menu), alignment: 0.2);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

Future<void> saveEditor(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  final save = find.widgetWithText(FilledButton, 'Сохранить');
  await Scrollable.ensureVisible(tester.element(save), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pumpAndSettle();
}

String amountText(WidgetTester tester) => tester
    .widget<TextFormField>(
      find.ancestor(
        of: find.text('Сумма'),
        matching: find.byType(TextFormField),
      ),
    )
    .controller!
    .text;

void mockLaunch({String? initial}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(launchChannel, (call) async {
        return call.method == 'initialAction' ? initial : null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launchChannel, null),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    mockLaunch();
  });

  for (final size in sizes) {
    final tag = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('repeat creates a new prefilled transaction $tag', (
      tester,
    ) async {
      final old = DateTime.now().subtract(const Duration(days: 5));
      final store = await createStore(tester, [record('orig', date: old)]);
      await boot(tester, store, size);
      await openTransactions(tester);
      await openRowMenu(tester);
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(amountText(tester), contains('350'));
      expect(find.text('Кофе'), findsWidgets);
      await saveEditor(tester);
      expect(store.transactions, hasLength(2));
      final created = store.transactions.firstWhere((t) => t.id != 'orig');
      expect(created.kindRawValue, 'expense');
      expect(created.amountMinor, 35000);
      expect(created.note, 'Кофе');
      expect(created.categoryName, BuiltInCategories.expense.first.name);
      expect(
        created.date.difference(DateTime.now()).abs(),
        lessThan(const Duration(minutes: 5)),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('save as template, use chip, delete $tag', (tester) async {
      final store = await createStore(tester, [record('orig')]);
      await boot(tester, store, size);
      expect(find.text('Быстрый ввод'), findsNothing);
      await openTransactions(tester);
      await openRowMenu(tester);
      await tester.tap(find.text('Сохранить как шаблон'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.templates, hasLength(1));
      expect(find.text('Шаблон сохранён в «Быстрый ввод»'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      final navigation = find.byType(NavigationBar).evaluate().isNotEmpty
          ? find.byType(NavigationBar)
          : find.byType(NavigationRail);
      await tester.tap(
        find
            .descendant(
              of: navigation,
              matching: find.byIcon(Icons.space_dashboard_outlined),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Быстрый ввод'), findsOneWidget);
      final chip = find.widgetWithText(ActionChip, 'Кофе · 350,00\u00a0₽');
      expect(chip, findsOneWidget);

      await tapVisible(tester, chip);
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(amountText(tester), contains('350'));
      await tapVisible(tester, find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsNothing);

      expect(tester.takeException(), isNull);
    });

    testWidgets('long press on a saved chip deletes the template $tag', (
      tester,
    ) async {
      final store = await createStore(tester, [record('orig')]);
      await tester.runAsync(
        () => store.saveTemplate(
          TransactionTemplate.fromTransaction('tpl', record('orig')),
        ),
      );
      await boot(tester, store, size);
      final chip = find.widgetWithText(ActionChip, 'Кофе · 350,00\u00a0₽');
      await Scrollable.ensureVisible(tester.element(chip), alignment: 0.2);
      await tester.pumpAndSettle();
      await tester.longPress(chip);
      await tester.pumpAndSettle();
      expect(find.text('Удалить шаблон «Кофе»?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(store.templates, isEmpty);
      expect(find.text('Быстрый ввод'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('frequent suggestion needs two identical operations $tag', (
      tester,
    ) async {
      final store = await createStore(tester, [record('a')]);
      await boot(tester, store, size);
      expect(find.text('Быстрый ввод'), findsNothing);
      await tester.runAsync(() => store.saveTransaction(record('b')));
      await tester.pumpAndSettle();
      expect(find.text('Быстрый ввод'), findsOneWidget);
      expect(find.byType(ActionChip), findsOneWidget);
      expect(store.templates, isEmpty);
      await tapVisible(tester, find.byType(ActionChip));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(amountText(tester), contains('350'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('initialAction expense opens the editor on start $tag', (
      tester,
    ) async {
      mockLaunch(initial: 'expense');
      final store = await createStore(tester, []);
      await boot(tester, store, size);
      expect(find.byType(TransactionEditor), findsOneWidget);
      final segment = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segment.selected, {'expense'});
      expect(tester.takeException(), isNull);
    });

    testWidgets('incoming income action preselects income $tag', (
      tester,
    ) async {
      final store = await createStore(tester, []);
      await boot(tester, store, size);
      expect(find.byType(TransactionEditor), findsNothing);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'balance/launch',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('action', 'income'),
            ),
            (_) {},
          );
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsOneWidget);
      final segment = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segment.selected, {'income'});
      expect(tester.takeException(), isNull);
    });
  }
}
