import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

import 'widget_test.dart'
    show
        boot,
        createStore,
        field,
        loadReadableFont,
        mockStorage,
        reveal,
        saveDialog;

void main() {
  setUpAll(loadReadableFont);
  setUp(mockStorage);

  testWidgets(
    'PDF preview applies one editable draft and saves on confirmation',
    (tester) async {
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      final fixture = File('test/fixtures/receipt_table.pdf').absolute.path;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'openFile');
        return [fixture];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final store = (await tester.runAsync(() => createStore(seeded: false)))!;
      await boot(tester, store, const Size(320, 568));
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      final import = find.text('Импортировать PDF-чек');
      await reveal(tester, import);
      await tester.runAsync(() => tester.tap(import));
      for (var i = 0; i < 100; i++) {
        await tester.pumpAndSettle();
        if (find.text('Позиции чека').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(find.text('Позиции чека'), findsOneWidget);
      expect(store.transactions, isEmpty);

      final item = find.text('Помидоры тепличные, вес');
      await reveal(tester, item);
      await tester.tap(item);
      await tester.pumpAndSettle();
      await tester.enterText(field('Сумма, ₽'), '183,58');
      final done = find.text('Готово');
      await reveal(tester, done);
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(find.textContaining('Расхождение:'), findsOneWidget);

      final apply = find.text('Использовать чек');
      await tester.scrollUntilVisible(
        apply,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(apply);
      final draft = find.text('Предпросмотр операции');
      for (var i = 0; i < 100; i++) {
        await tester.pumpAndSettle();
        if (draft.evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(draft, findsOneWidget);
      expect(store.transactions, isEmpty);
      await saveDialog(tester);

      final saved = store.transactions.single;
      expect(saved.amountMinor, 100734);
      expect(saved.currency, 'RUB');
      expect(
        saved.note,
        contains('Помидоры тепличные, вес — 0,68 × 269,98 ₽ = 183,58 ₽'),
      );
    },
  );
}
