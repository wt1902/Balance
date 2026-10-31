import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The operations page must build only what is on screen, not the ledger.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('20 000 operations open lazily at ${size.width}', (
      tester,
    ) async {
      final store = (await tester.runAsync(() async {
        final store = AppStore(storage: MemorySnapshotStorage());
        await store.initialize();
        final start = DateTime(2026, 10, 30, 12);
        await store.importTransactions([
          for (var i = 0; i < 20000; i++)
            TransactionRecord(
              id: 'big-$i',
              amountMinor: 100 + i,
              date: start.subtract(Duration(hours: i * 2)),
              categoryName: 'Продукты',
              note: 'Покупка $i',
              updatedAt: start,
            ),
        ]);
        return store;
      }))!;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(store.dispose);
      await tester.pumpWidget(BalanceApp(store: store));
      await tester.pumpAndSettle();

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
      expect(find.textContaining(RegExp(r'· Покупка 0$')), findsOneWidget);
      expect(find.byType(ListTile).evaluate().length, lessThan(200));

      // Searching still filters the whole ledger.
      await tester.enterText(find.byType(TextField).first, 'Покупка 19999');
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'· Покупка 19999$')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
