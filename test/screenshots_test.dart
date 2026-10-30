import 'dart:io';
import 'dart:ui' as ui;
import 'package:balance_flutter/ui/app.dart';
import 'package:balance_flutter/ui/editors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' as fixtures;

Future<void> capture(
  WidgetTester tester,
  GlobalKey key,
  Size size,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('/tmp/balance-ui')..createSync(recursive: true);
    File(
      '${dir.path}/${size.width.toInt()}x${size.height.toInt()}-$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(fixtures.loadReadableFont);
  setUp(fixtures.mockStorage);
  testWidgets('capture dark phone overview', (tester) async {
    final store = (await tester.runAsync(() => fixtures.createStore()))!;
    await tester.runAsync(() => store.setTheme('dark'));
    final key = GlobalKey();
    const size = Size(390, 844);
    await fixtures.boot(tester, store, size, boundaryKey: key);
    await capture(tester, key, size, 'overview-dark');
    expect(tester.takeException(), isNull);
  });
  for (final size in fixtures.screenSizes) {
    testWidgets(
      'capture screens ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        final store = (await tester.runAsync(() => fixtures.createStore()))!;
        final key = GlobalKey();
        await fixtures.boot(tester, store, size, boundaryKey: key);
        final names = [
          'overview',
          'transactions',
          'analytics',
          'budgets',
          'settings',
        ];
        for (var page = 0; page < names.length; page++) {
          await fixtures.navigate(tester, page);
          expect(tester.takeException(), isNull);
          await capture(tester, key, size, names[page]);
        }
        final editors = <String, Widget>{
          'transaction-form': TransactionEditor(categories: store.categories),
          'category-form': CategoryEditor(categories: store.categories),
          'budget-form': BudgetEditor(
            categories: store.categoriesForKind('expense'),
            month: DateTime.now(),
          ),
        };
        for (final entry in editors.entries) {
          editDialog<void>(
            tester.element(find.byType(BalanceShell)),
            entry.value,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture(tester, key, size, entry.key);
          await fixtures.reveal(tester, find.text('Отмена'));
          await capture(tester, key, size, '${entry.key}-actions');
          await tester.tap(find.text('Отмена'));
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
