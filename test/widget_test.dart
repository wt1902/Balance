import 'dart:io';
import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:balance_flutter/ui/editors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const screenSizes = [Size(390, 844), Size(1280, 900), Size(320, 568)];
const pageIcons = [
  Icons.space_dashboard_outlined,
  Icons.receipt_long_outlined,
  Icons.insights_outlined,
  Icons.savings_outlined,
  Icons.settings_outlined,
];

void mockStorage() {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
}

Future<void> loadReadableFont() async {
  // Use the exact offline app fonts; Ahem changes Cyrillic button widths.
  final loader = FontLoader('BalanceRoboto');
  for (final weight in ['Regular', 'Medium', 'Bold']) {
    loader.addFont(rootBundle.load('assets/fonts/Roboto-$weight.ttf'));
  }
  await loader.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

Future<AppStore> createStore({bool seeded = true}) async {
  final store = AppStore(storage: MemorySnapshotStorage());
  await store.initialize();
  if (seeded) {
    final now = DateTime.now();
    await store.saveCategory(
      CategoryRecord(
        id: 'custom',
        name: 'Дом и повседневные покупки',
        icon: 'house.fill',
        colorName: 'teal',
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (var i = 0; i < 6; i++) {
      await store.saveTransaction(
        TransactionRecord(
          id: 'tx-$i',
          amountMinor: i == 0 ? 25000000 : 12345 + i * 1000,
          kindRawValue: i == 0 ? 'income' : 'expense',
          date: now,
          categoryName: i == 0 ? 'Зарплата' : 'Дом и повседневные покупки',
          categoryIcon: i == 0 ? 'banknote.fill' : 'house.fill',
          categoryColorName: 'teal',
          note: 'Проверка длинного описания операции',
          updatedAt: now,
        ),
      );
    }
    await store.saveBudget(
      BudgetRecord(
        id: 'budget',
        categoryName: 'Дом и повседневные покупки',
        categoryIcon: 'house.fill',
        limitMinor: 500000,
        monthStart: DateTime(now.year, now.month),
        updatedAt: now,
      ),
    );
  }
  return store;
}

Future<void> boot(
  WidgetTester tester,
  AppStore store,
  Size size, {
  Key? boundaryKey,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(store.dispose);
  await tester.pumpWidget(
    boundaryKey == null
        ? BalanceApp(store: store)
        : RepaintBoundary(
            key: boundaryKey,
            child: BalanceApp(store: store),
          ),
  );
  await tester.pumpAndSettle();
}

Future<void> navigate(WidgetTester tester, int page) async {
  final navigation = find.byType(NavigationBar).evaluate().isNotEmpty
      ? find.byType(NavigationBar)
      : find.byType(NavigationRail);
  await tester.tap(
    find
        .descendant(of: navigation, matching: find.byIcon(pageIcons[page]))
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

Finder field(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

Future<void> saveDialog(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  final save = find.widgetWithText(FilledButton, 'Сохранить');
  await reveal(tester, save);
  await tester.tap(save);
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadReadableFont);
  setUp(mockStorage);
  testWidgets('navigation and scrolling with large text on a small phone', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final store = (await tester.runAsync(() => createStore()))!;
    await boot(tester, store, const Size(320, 568));
    for (var page = 0; page < 5; page++) {
      await navigate(tester, page);
      expect(tester.takeException(), isNull, reason: 'large text page=$page');
      for (var step = 0; step < 6; step++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'large text page=$page scroll=$step',
        );
      }
    }
  });

  testWidgets('negative balance adjustment preserves analytics', (
    tester,
  ) async {
    final store = (await tester.runAsync(() => createStore()))!;
    final now = DateTime.now();
    final start = DateTime(now.year, now.month);
    final end = DateTime(now.year, now.month + 1);
    final before = FinanceMath.summary(store.transactions, start, end);
    final spending = FinanceMath.spending(
      store.transactions,
      start,
      end,
    ).map((e) => e.amountMinor).toList();
    await boot(tester, store, const Size(390, 844));
    await tester.tap(find.widgetWithText(TextButton, 'Изменить'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Фактический баланс, RUB'), '-150,25');
    await saveDialog(tester);
    await tester.pump(const Duration(milliseconds: 350));
    expect(FinanceMath.totalBalance(store.transactions), -15025);
    expect(
      store.transactions.where((t) => t.isBalanceAdjustment),
      hasLength(1),
    );
    final after = FinanceMath.summary(store.transactions, start, end);
    expect(after.incomeMinor, before.incomeMinor);
    expect(after.expensesMinor, before.expensesMinor);
    expect(
      FinanceMath.spending(
        store.transactions,
        start,
        end,
      ).map((e) => e.amountMinor).toList(),
      spending,
    );
    expect(tester.takeException(), isNull);
  });

  for (final desktop in [true, false]) {
    testWidgets(
      'CSV export reaches ${desktop ? 'save selector' : 'share sheet'}',
      (tester) async {
        debugDefaultTargetPlatformOverride = desktop
            ? TargetPlatform.linux
            : TargetPlatform.android;
        try {
          final store = (await tester.runAsync(
            () => createStore(seeded: false),
          ))!;
          await tester.runAsync(
            () => store.saveTransaction(
              TransactionRecord(
                id: 'csv',
                amountMinor: 12345,
                date: DateTime(2026, 10, 28),
                categoryName: 'Покупки, дом',
                note: 'Текст "в кавычках"\nНовая строка',
                updatedAt: DateTime.now(),
              ),
            ),
          );
          final expected = FinanceMath.exportCsv(store.transactions);
          final directory = Directory('/tmp/balance-export')
            ..createSync(recursive: true);
          final destination = File('${directory.path}/desktop.csv');
          if (destination.existsSync()) destination.deleteSync();
          Map<Object?, Object?>? selectorArguments;
          String? sharedCsv;
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/file_selector'),
            (call) async {
              expect(call.method, 'getSavePath');
              selectorArguments = call.arguments as Map;
              return destination.path;
            },
          );
          messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path,
          );
          messenger.setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/share'),
            (call) async {
              expect(call.method, 'share');
              final args = call.arguments as Map;
              expect(args['mimeTypes'], ['text/csv']);
              final path = (args['paths'] as List).single as String;
              expect(path.endsWith('balance-transactions.csv'), isTrue);
              sharedCsv = await File(path).readAsString();
              return 'test-share-target';
            },
          );
          await boot(tester, store, const Size(390, 844));
          await navigate(tester, 4);
          final export = find.text('Экспорт истории CSV');
          await tester.scrollUntilVisible(
            export,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await reveal(tester, export);
          await tester.tap(export);
          await tester.pumpAndSettle();
          // Drain real filesystem work and test-zone channel continuations.
          for (var i = 0; i < 50; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 10));
            if (desktop
                ? destination.existsSync() &&
                      destination.readAsStringSync() == expected
                : sharedCsv != null) {
              break;
            }
          }
          await tester.pumpAndSettle();
          if (desktop) {
            expect(
              selectorArguments?['suggestedName'],
              'balance-transactions.csv',
            );
            expect(destination.readAsStringSync(), expected);
          } else {
            expect(sharedCsv, expected);
          }
          expect(expected, contains('"Текст ""в кавычках""\nНовая строка"'));
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
  for (final size in screenSizes) {
    testWidgets('account and server form validation at $size', (tester) async {
      final store = (await tester.runAsync(() => createStore(seeded: false)))!;
      await tester.runAsync(() => store.setServerUrl('https://example.com'));
      await boot(tester, store, size);
      await navigate(tester, 4);
      for (final action in ['Войти', 'Регистрация']) {
        final button = find.widgetWithText(
          action == 'Войти' ? FilledButton : TextButton,
          action,
        );
        await tester.scrollUntilVisible(
          button,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await reveal(tester, button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        final submit = find
            .widgetWithText(
              FilledButton,
              action == 'Войти' ? 'Войти' : 'Зарегистрироваться',
            )
            .last;
        await reveal(tester, submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(find.text('Введите email'), findsOneWidget);
        expect(store.session, isNull);
        expect(tester.takeException(), isNull);
        await reveal(tester, find.text('Отмена'));
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
      }
      final server = find.widgetWithText(OutlinedButton, 'Адрес сервера');
      await reveal(tester, server);
      await tester.tap(server);
      await tester.pumpAndSettle();
      await tester.enterText(field('https://balance.example.com'), 'invalid');
      await saveDialog(tester);
      expect(find.text('Введите полный адрес сервера'), findsOneWidget);
      expect(store.serverUrl, 'https://example.com');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
    });
    for (final seeded in [false, true]) {
      testWidgets('all pages scroll without overflow $size seeded=$seeded', (
        tester,
      ) async {
        final store = (await tester.runAsync(
          () => createStore(seeded: seeded),
        ))!;
        await boot(tester, store, size);
        for (var page = 0; page < 5; page++) {
          await navigate(tester, page);
          expect(tester.takeException(), isNull, reason: 'page=$page at $size');
          // Exercise lazy children and the lower settings/categories sections.
          for (var step = 0; step < 8; step++) {
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, -350),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'page=$page scroll=$step at $size',
            );
          }
        }
      });
    }
    testWidgets('all editors are usable at $size', (tester) async {
      final store = (await tester.runAsync(() => createStore(seeded: false)))!;
      await boot(tester, store, size);
      final context = tester.element(find.byType(BalanceShell));
      final widgets = <Widget>[
        const TransactionEditor(categories: []),
        const CategoryEditor(categories: []),
        BudgetEditor(
          categories: BuiltInCategories.expense,
          month: DateTime.now(),
        ),
      ];
      for (final editor in widgets) {
        editDialog<void>(context, editor);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await saveDialog(tester);
        expect(
          find.byType(Form),
          findsOneWidget,
        ); // Invalid empty form stays open.
        expect(tester.takeException(), isNull);
        await reveal(tester, find.text('Отмена'));
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('transaction add, edit and delete through the interface', (
    tester,
  ) async {
    final store = (await tester.runAsync(() => createStore(seeded: false)))!;
    await boot(tester, store, screenSizes.first);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(field('Сумма'), '123,45');
    await tester.enterText(field('Заметка'), 'Покупка для теста');
    await saveDialog(tester);
    expect(store.transactions.single.amountMinor, 12345);
    expect(store.transactions.single.note, 'Покупка для теста');
    final id = store.transactions.single.id;
    await navigate(tester, 1);
    await reveal(tester, find.textContaining('Покупка для теста'));
    await tester.tap(find.textContaining('Покупка для теста'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Сумма'), '250.50');
    await saveDialog(tester);
    expect(store.transactions.single.id, id);
    expect(store.transactions.single.amountMinor, 25050);
    await reveal(tester, find.byTooltip('Действия с операцией'));
    await tester.tap(find.byTooltip('Действия с операцией'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();
    expect(store.transactions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom category and monthly budget CRUD through the interface', (
    tester,
  ) async {
    final store = (await tester.runAsync(() => createStore(seeded: false)))!;
    await boot(tester, store, screenSizes.first);
    await navigate(tester, 4);
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Добавить'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await reveal(tester, find.widgetWithText(FilledButton, 'Добавить'));
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Название'), 'Мой сад');
    await saveDialog(tester);
    expect(store.categories.single.name, 'Мой сад');
    final id = store.categories.single.id;
    await reveal(tester, find.text('Мой сад'));
    await tester.tap(find.text('Мой сад'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Название'), 'Мой дом');
    await saveDialog(tester);
    expect(store.categories.single.id, id);
    expect(store.categories.single.name, 'Мой дом');
    await navigate(tester, 3);
    await tester.tap(find.text('Добавить лимит'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Мой дом').last,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Мой дом').last);
    await tester.pumpAndSettle();
    await tester.enterText(field('Месячный лимит'), '5000');
    await saveDialog(tester);
    expect(store.budgets.single.categoryName, 'Мой дом');
    expect(store.budgets.single.limitMinor, 500000);
    await reveal(tester, find.byTooltip('Изменить лимит'));
    await tester.tap(find.byTooltip('Изменить лимит'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Месячный лимит'), '7500');
    await saveDialog(tester);
    expect(store.budgets.single.limitMinor, 750000);
    await reveal(tester, find.byTooltip('Удалить лимит'));
    await tester.tap(find.byTooltip('Удалить лимит'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();
    expect(store.budgets, isEmpty);
    await navigate(tester, 4);
    await tester.scrollUntilVisible(
      find.byTooltip('Удалить категорию'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await reveal(tester, find.byTooltip('Удалить категорию'));
    await tester.tap(find.byTooltip('Удалить категорию'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();
    expect(store.categories, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
