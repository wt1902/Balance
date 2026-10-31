import 'dart:convert';

import 'package:balance_flutter/domain/appearance.dart';
import 'package:balance_flutter/domain/backup.dart';
import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/statement_import.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app_theme.dart';
import 'package:balance_flutter/ui/data_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sizes = <String, Size>{
  '320x568': Size(320, 568),
  '390x844': Size(390, 844),
  '1280x900': Size(1280, 900),
};

Future<void> pumpHost(
  WidgetTester tester,
  Size size,
  Widget Function(BuildContext) home, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: BalanceThemes.build(brightness, ColorPreset.forest),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(builder: home),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens [page] on a pushed route and exposes what it pops.
class Host {
  Object? result;
  bool popped = false;
  Widget build(BuildContext context, Widget page) => Scaffold(
    body: Center(
      child: FilledButton(
        onPressed: () async {
          result = await Navigator.of(
            context,
          ).push<Object>(MaterialPageRoute(builder: (_) => page));
          popped = true;
        },
        child: const Text('open'),
      ),
    ),
  );
}

/// Scrolls the screen's main list to the top, then down to [finder].
Future<void> reveal(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(Scrollable).last;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  if (finder.hitTestable().evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(finder, 40, scrollable: scrollable);
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final entry in sizes.entries) {
    group('CsvMappingDialog ${entry.key}', () {
      testWidgets('shows preview, flips sign and pops mapping', (tester) async {
        final table = StatementImport.parseCsv(
          'Date,Description,Amount\n2026-02-01,Coffee,4.50\n2026-02-02,Refund,-10\n',
        );
        final host = Host();
        await pumpHost(
          tester,
          entry.value,
          (c) => host.build(c, CsvMappingDialog(table: table)),
        );
        await open(tester);

        expect(find.text('Колонки выписки'), findsOneWidget);
        await reveal(tester, find.textContaining('Refund'));
        expect(find.textContaining('Coffee'), findsOneWidget);
        expect(find.textContaining('Refund'), findsOneWidget);
        final before = tester
            .widgetList<Text>(find.textContaining(RegExp('^[+−]')))
            .map((t) => t.data)
            .toList();
        expect(before.length, 2);
        expect(before[0], startsWith('+'));
        expect(before[1], startsWith('−'));

        final toggle = find.text('Расходы указаны положительными числами');
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final after = tester
            .widgetList<Text>(find.textContaining(RegExp('^[+−]')))
            .map((t) => t.data)
            .toList();
        expect(after[0], startsWith('−'));
        expect(after[1], startsWith('+'));

        await tester.tap(find.text('Далее'));
        await tester.pumpAndSettle();
        expect(host.popped, isTrue);
        final mapping = host.result as CsvMapping;
        expect(mapping.invertSign, isTrue);
        expect(mapping.date, 0);
        expect(mapping.amount, 2);
        expect(mapping.description, 1);
      });
    });

    group('StatementPreviewDialog ${entry.key}', () {
      testWidgets('duplicates, known rows, toggling, category, import', (
        tester,
      ) async {
        final store = AppStore(storage: MemorySnapshotStorage());
        await store.initialize();

        StatementRow row(
          String key,
          int minor,
          TransactionKind kind,
          String d, {
          int day = 1,
        }) => StatementRow(
          date: DateTime(2026, 2, day, 14, 30),
          amountMinor: minor,
          kind: kind,
          description: d,
          importKey: key,
        );
        final dup = row('a', 45000, TransactionKind.expense, 'Кофейня');
        final shop = row(
          'b',
          100000,
          TransactionKind.expense,
          'Пятерочка',
          day: 2,
        );
        final pay = row(
          'c',
          500000,
          TransactionKind.income,
          'Зарплата',
          day: 3,
        );
        final known = row('d', 20000, TransactionKind.expense, 'Такси', day: 4);

        await store.saveTransaction(
          TransactionRecord(
            id: 'manual',
            amountMinor: 45000,
            date: DateTime(2026, 2, 1, 9),
            categoryName: 'Другое',
            updatedAt: DateTime.utc(2026, 2, 1),
          ),
        );
        final other = store.categoriesForKind(TransactionKind.expense).last;
        await store.importTransactions([
          StatementImport.toTransaction(known, other),
        ]);

        final host = Host();
        await pumpHost(
          tester,
          entry.value,
          (c) => host.build(
            c,
            StatementPreviewDialog(
              store: store,
              result: StatementParseResult(
                format: 'Т-Банк, CSV',
                rows: [dup, shop, pay, known],
              ),
            ),
          ),
        );
        await open(tester);

        expect(find.text('возможный дубль'), findsOneWidget);
        await reveal(tester, find.text('уже импортирована'));
        expect(find.text('уже импортирована'), findsOneWidget);
        expect(find.text('Импортировать (2)'), findsOneWidget);

        Future<Checkbox> boxFor(String description) async {
          final tile = find.widgetWithText(ListTile, description);
          await reveal(tester, tile);
          return tester.widget<Checkbox>(
            find.descendant(of: tile, matching: find.byType(Checkbox)),
          );
        }

        Future<void> tapRow(String description) async {
          await reveal(tester, find.text(description));
          await tester.tap(find.text(description));
          await tester.pumpAndSettle();
        }

        expect((await boxFor('Кофейня')).value, isFalse);
        expect((await boxFor('Такси')).onChanged, isNull);
        expect((await boxFor('Пятерочка')).value, isTrue);

        await tapRow('Пятерочка');
        expect(find.text('Импортировать (1)'), findsOneWidget);
        await tapRow('Кофейня');
        expect(find.text('Импортировать (2)'), findsOneWidget);
        await tapRow('Кофейня');
        await tapRow('Пятерочка');
        expect(find.text('Импортировать (2)'), findsOneWidget);

        // Category chip -> bottom sheet -> another category.
        final chip = find.descendant(
          of: find.widgetWithText(ListTile, 'Пятерочка'),
          matching: find.byType(ActionChip),
        );
        await reveal(tester, chip);
        final oldName = (tester.widget<ActionChip>(chip).label as Text).data!;
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        final choices = store.categoriesForKind(TransactionKind.expense);
        final pick = choices.firstWhere((c) => c.name != oldName);
        final tile = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.widgetWithText(ListTile, pick.name),
        );
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect((tester.widget<ActionChip>(chip).label as Text).data, pick.name);

        await tester.tap(find.text('Импортировать (2)'));
        await tester.pumpAndSettle();
        expect(host.popped, isTrue);
        final list = (host.result as List).cast<TransactionRecord>();
        expect(list.length, 2);
        expect(
          list.firstWhere((t) => t.amountMinor == 100000).categoryName,
          pick.name,
        );
        expect(list.any((t) => t.amountMinor == 500000), isTrue);
        expect(list.any((t) => t.amountMinor == 45000), isFalse);
        store.dispose();
      });
    });

    group('BackupPreviewDialog ${entry.key}', () {
      testWidgets('plan, selection, pop and restore', (tester) async {
        final store = AppStore(storage: MemorySnapshotStorage());
        await store.initialize();
        TransactionRecord tx(String id, DateTime updated) => TransactionRecord(
          id: id,
          amountMinor: 12300,
          date: DateTime.utc(2026, 2, 3, 10),
          categoryName: 'Другое',
          updatedAt: updated,
        );
        await store.saveTransaction(tx('keep', DateTime.utc(2026, 3, 1)));
        final stored = store.transactions.firstWhere((t) => t.id == 'keep');
        final old = TransactionRecord(
          id: 'keep',
          amountMinor: 999,
          date: stored.date,
          categoryName: 'Другое',
          updatedAt: DateTime.utc(2000, 1, 1),
        );
        final json =
            jsonDecode(
                  jsonEncode({
                    'format': 'balance-backup',
                    'version': 1,
                    'data': {
                      'transactions': [
                        tx('n1', DateTime.utc(2026, 4, 1)).toJson(),
                        tx('n2', DateTime.utc(2026, 4, 2)).toJson(),
                        old.toJson(),
                      ],
                      'categories': [
                        CategoryRecord(
                          id: 'cat-new',
                          name: 'Новая из копии',
                          icon: 'star.fill',
                          colorName: 'auto',
                          createdAt: DateTime.utc(2026, 4, 1),
                          updatedAt: DateTime.utc(2026, 4, 1),
                        ).toJson(),
                      ],
                      'budgets': [
                        BudgetRecord(
                          id: 'bud-new',
                          categoryName: 'Другое',
                          limitMinor: 500000,
                          monthStart: DateTime.utc(2026, 4, 1),
                          updatedAt: DateTime.utc(2026, 4, 1),
                        ).toJson(),
                      ],
                    },
                  }),
                )
                as Object;
        final plan = await store.previewBackup(json);

        final host = Host();
        await pumpHost(
          tester,
          entry.value,
          (c) => host.build(
            c,
            BackupPreviewDialog(
              plan: plan,
              fileName: 'copy-2026.json',
              currency: store.currency,
            ),
          ),
        );
        await open(tester);

        expect(find.text('Восстановление из копии'), findsOneWidget);
        expect(find.text('copy-2026.json'), findsOneWidget);
        expect(find.textContaining('добавится: 4'), findsOneWidget);
        expect(find.textContaining('без изменений: 1'), findsOneWidget);
        expect(find.text('Восстановить (4)'), findsOneWidget);

        final skipTile = find.ancestor(
          of: find.textContaining('На устройстве та же или более новая версия'),
          matching: find.byType(ListTile),
        );
        await reveal(tester, skipTile);
        expect(skipTile, findsOneWidget);
        final skipBox = tester.widget<Checkbox>(
          find.descendant(of: skipTile, matching: find.byType(Checkbox)),
        );
        expect(skipBox.onChanged, isNull);

        final addTiles = find.byWidgetPredicate(
          (w) =>
              w is ListTile &&
              w.subtitle is Text &&
              ((w.subtitle as Text).data ?? '').startsWith('Добавится'),
        );
        expect(addTiles, findsWidgets);
        await reveal(tester, addTiles.first);
        await tester.tap(addTiles.first);
        await tester.pumpAndSettle();
        expect(find.text('Восстановить (3)'), findsOneWidget);

        Future<bool?> allValue() async {
          final all = find.widgetWithText(CheckboxListTile, 'Выбрать все');
          await reveal(tester, all);
          return tester.widget<CheckboxListTile>(all).value;
        }

        expect(await allValue(), isFalse);
        await tester.tap(find.text('Выбрать все'));
        await tester.pumpAndSettle();
        expect(find.text('Восстановить (4)'), findsOneWidget);
        expect(await allValue(), isTrue);
        await tester.tap(find.text('Выбрать все'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Восстановить (0)'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Выбрать все'));
        await tester.pumpAndSettle();

        await reveal(tester, addTiles.first);
        await tester.tap(addTiles.first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Восстановить (3)'));
        await tester.pumpAndSettle();
        expect(host.popped, isTrue);
        final keys = (host.result as Set).cast<String>();
        expect(keys.length, 3);
        expect(keys.every((k) => plan.actionable.any((i) => i.key == k)), true);
        expect(keys.contains('transaction:keep'), isFalse);

        await store.restoreBackup(json, only: keys);
        final all = {
          ...store.transactions.map((t) => 'transaction:${t.id}'),
          ...store.categories.map((c) => 'category:${c.id}'),
          ...store.budgets.map((b) => 'budget:${b.id}'),
        };
        final wanted = plan.actionable.map((i) => i.key).toSet();
        for (final item in plan.actionable) {
          expect(
            all.contains(item.key),
            keys.contains(item.key),
            reason: item.key,
          );
        }
        expect(wanted.length, 4);
        expect(
          store.transactions.firstWhere((t) => t.id == 'keep').amountMinor,
          12300,
        );
        store.dispose();
      });
    });

    group('Balance CSV preview ${entry.key}', () {
      testWidgets('adjustment locked, ids and flags preserved', (tester) async {
        final store = AppStore(storage: MemorySnapshotStorage());
        await store.initialize();
        final csv = FinanceMath.exportCsv([
          TransactionRecord(
            id: 'csv-1',
            amountMinor: 15050,
            date: DateTime.utc(2026, 2, 5, 12),
            categoryName: 'Кафе',
            categoryIcon: 'cup.and.saucer.fill',
            categoryEmoji: '☕',
            categoryColorName: 'orange',
            note: 'Латте',
            updatedAt: DateTime.utc(2026, 2, 5),
          ),
          TransactionRecord(
            id: 'csv-adj',
            amountMinor: 7000,
            date: DateTime.utc(2026, 2, 4, 12),
            categoryName: 'Корректировка баланса',
            note: 'Сверка',
            isBalanceAdjustment: true,
            updatedAt: DateTime.utc(2026, 2, 4),
          ),
        ]);
        final result = StatementImport.readBalanceCsv(
          StatementImport.parseCsv(csv),
        );
        expect(result.rows.length, 2);

        final host = Host();
        await pumpHost(
          tester,
          entry.value,
          (c) => host.build(
            c,
            StatementPreviewDialog(store: store, result: result),
          ),
        );
        await open(tester);

        expect(find.textContaining('Баланс, CSV'), findsOneWidget);
        expect(find.text('Импортировать (2)'), findsOneWidget);

        final normal = find.descendant(
          of: find.widgetWithText(ListTile, 'Латте'),
          matching: find.byType(ActionChip),
        );
        final adj = find.descendant(
          of: find.widgetWithText(ListTile, 'Сверка'),
          matching: find.byType(ActionChip),
        );
        await reveal(tester, adj);
        expect(tester.widget<ActionChip>(adj).onPressed, isNull);
        await reveal(tester, normal);
        expect(tester.widget<ActionChip>(normal).onPressed, isNotNull);
        await tester.tap(normal);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);

        await tester.tap(find.text('Импортировать (2)'));
        await tester.pumpAndSettle();
        expect(host.popped, isTrue);
        final list = (host.result as List).cast<TransactionRecord>();
        final n = list.firstWhere((t) => t.id == 'csv-1');
        final a = list.firstWhere((t) => t.id == 'csv-adj');
        expect(n.isBalanceAdjustment, isFalse);
        expect(a.isBalanceAdjustment, isTrue);
        expect(n.categoryEmoji, '☕');
        expect(n.categoryColorName, 'orange');
        expect(n.amountMinor, 15050);
        expect(a.amountMinor, 7000);
        store.dispose();
      });
    });

    group('QuarantinePanel ${entry.key}', () {
      testWidgets('shows summary and calls callbacks', (tester) async {
        final entries = [
          for (var i = 0; i < 7; i++)
            QuarantineEntry(
              source: i.isEven ? 'local' : 'server',
              section: i.isEven ? 'transactions' : 'transaction',
              reason:
                  'Неверная сумма в записи номер $i, очень длинное описание причины',
              detectedAt: DateTime.utc(2026, 2, 1),
              raw: {'id': 'record-identifier-$i'},
            ),
        ];
        var saved = 0, cleared = 0;
        await pumpHost(
          tester,
          entry.value,
          (c) => Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: QuarantinePanel(
                  entries: entries,
                  onSave: () => saved++,
                  onClear: () => cleared++,
                ),
              ),
            ),
          ),
        );
        expect(find.text('Отложено записей с ошибками: 7'), findsOneWidget);
        expect(find.text('и ещё 2'), findsOneWidget);
        expect(find.textContaining('Полная синхронизация'), findsOneWidget);
        await tester.ensureVisible(find.text('Очистить'));
        await tester.tap(find.text('Сохранить отчёт'));
        await tester.tap(find.text('Очистить'));
        expect(saved, 1);
        expect(cleared, 1);
      });
    });
  }
}
