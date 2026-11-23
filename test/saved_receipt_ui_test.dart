import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/ui/saved_receipt_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart'
    show boot, createStore, loadReadableFont, mockStorage, navigate, reveal;

void main() {
  setUpAll(loadReadableFont);
  setUp(mockStorage);

  const note =
      'Оплата картой\n\nПозиции чека\n'
      'Помидоры — 0,68 × 269,98 ₽ = 183,59 ₽\n'
      'Кофе — тёмная обжарка — 1,0 × 10,51 ₽ = 10,51 ₽';

  for (final (size, theme) in [
    (const Size(320, 568), 'oled'),
    (const Size(390, 844), 'dark'),
    (const Size(1280, 900), 'light'),
  ]) {
    testWidgets('opens saved PDF positions at $size in $theme mode', (
      tester,
    ) async {
      final store = (await tester.runAsync(() => createStore(seeded: false)))!;
      final date = DateTime(2026, 11, 22, 22, 38);
      await tester.runAsync(() async {
        if (theme == 'oled') {
          await store.setThemePreset(theme);
        } else {
          await store.setTheme(theme);
        }
        await store.saveTransaction(
          TransactionRecord(
            id: 'receipt',
            amountMinor: 19410,
            date: date,
            categoryName: 'Продукты',
            updatedAt: date,
            note: note,
          ),
        );
        await store.saveTransaction(
          TransactionRecord(
            id: 'manual',
            amountMinor: 3000,
            date: date.subtract(const Duration(minutes: 1)),
            categoryName: 'Обычный расход',
            updatedAt: date,
            note: 'Обычная заметка',
          ),
        );
      });
      await boot(tester, store, size);
      await navigate(tester, 1);

      final receiptMenu = find.descendant(
        of: find.widgetWithText(ListTile, 'Продукты'),
        matching: find.byTooltip('Действия с операцией'),
      );
      await reveal(tester, receiptMenu);
      await tester.tap(receiptMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Позиции чека'));
      await tester.pumpAndSettle();

      expect(find.byType(SavedReceiptPage), findsOneWidget);
      expect(find.text('Помидоры'), findsOneWidget);
      expect(find.text('Кофе — тёмная обжарка'), findsOneWidget);
      expect(find.textContaining('Сумма позиций: 194,10'), findsOneWidget);
      if (size.width >= 620) {
        expect(find.byType(Table), findsOneWidget);
        expect(find.text('Количество'), findsOneWidget);
        expect(find.text('0,68'), findsOneWidget);
      } else {
        expect(find.text('Количество: 0,68'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      expect(
        store.transactions.firstWhere((t) => t.id == 'receipt').note,
        note,
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final manualMenu = find.descendant(
        of: find.widgetWithText(ListTile, 'Обычный расход'),
        matching: find.byTooltip('Действия с операцией'),
      );
      await reveal(tester, manualMenu);
      await tester.tap(manualMenu);
      await tester.pumpAndSettle();
      expect(find.text('Позиции чека'), findsNothing);
    });
  }
}
