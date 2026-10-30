import 'dart:io';

import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two engines (UI and background sync) keep their own open Sembast
/// connection to one file; the shared `ledgerRevision` keeps them coherent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('balance-cache');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<AppStore> engine() async {
    final path = '${dir.path}/balance.sembast';
    final store = AppStore(
      storage: await LedgerStorage.open(
        opener: () => databaseFactoryIo.openDatabase(path),
      ),
      background: true,
    );
    await store.initialize();
    return store;
  }

  TransactionRecord tx(String id, int amount) => TransactionRecord(
    id: id,
    amountMinor: amount,
    date: DateTime.utc(2026, 1, 1),
    categoryName: 'Продукты',
    updatedAt: DateTime.utc(2026, 1, 1),
  );

  test('a write by one engine is seen and kept by the other', () async {
    final ui = await engine();
    final background = await engine();
    await ui.saveTransaction(tx('ui-1', 100));
    // The background engine's open connection predates that write.
    await background.saveTransaction(tx('bg-1', 200));
    expect(background.transactions.map((t) => t.id).toSet(), {'ui-1', 'bg-1'});
    await ui.saveTransaction(tx('ui-2', 300));
    expect(ui.transactions.map((t) => t.id).toSet(), {'ui-1', 'bg-1', 'ui-2'});
    await ui.deleteTransaction('bg-1');
    await background.sync(); // signed out: only reloads shared state
    expect(background.transactions.map((t) => t.id).toSet(), {'ui-1', 'ui-2'});
    await ui.close();
    await background.close();

    final reopened = await engine();
    expect(reopened.transactions.map((t) => t.id).toSet(), {'ui-1', 'ui-2'});
    expect(reopened.balanceMinor, -400);
    // bg-1's deletion replaces its own queued insert.
    expect(reopened.pendingChangeCount, 3);
    await reopened.close();
    for (final s in [ui, background, reopened]) {
      s.dispose();
    }
  });

  test('a saved record is in the file before the call returns', () async {
    final store = await engine();
    await store.saveTransaction(tx('durable', 100));
    // Another engine opening the file right away, with this one still open.
    final db = await databaseFactoryIo.openDatabase(
      '${dir.path}/balance.sembast',
    );
    final ledger = stringMapStoreFactory.store('ledger||guest');
    expect(await ledger.record('t:durable').get(db), isNotNull);
    await db.close();
    await store.close();
    store.dispose();
  });

  test('legacy snapshot migrates to per-record storage losslessly', () async {
    final path = '${dir.path}/balance.sembast';
    final legacy = stringMapStoreFactory.store('snapshots');
    var db = await databaseFactoryIo.openDatabase(path);
    await legacy.record('|guest').put(db, {
      'transactions': [tx('old-1', 100).toJson(), tx('old-2', 200).toJson()],
      'categories': [],
      'budgets': [],
      'dirty': [],
      'tombstones': [],
      'cursor': 7,
    });
    await db.close();

    final store = await engine();
    expect(store.transactions, hasLength(2));
    expect(store.cursor, 7);
    await store.saveTransaction(tx('new', 300));
    await store.close();
    store.dispose();

    db = await databaseFactoryIo.openDatabase(path);
    expect(await legacy.record('|guest').get(db), isNull);
    final keys = await stringMapStoreFactory
        .store('ledger||guest')
        .findKeys(db);
    expect(keys, containsAll(['t:old-1', 't:old-2', 't:new', 'meta']));
    await db.close();
    final reopened = await engine();
    expect(reopened.transactions.map((t) => t.id).toSet(), {
      'old-1',
      'old-2',
      'new',
    });
    expect(reopened.cursor, 7);
    await reopened.close();
    reopened.dispose();
  });

  test('a damaged per-record entry is quarantined and removed', () async {
    final store = await engine();
    await store.saveTransaction(tx('good', 100));
    await store.close();
    store.dispose();
    final path = '${dir.path}/balance.sembast';
    var db = await databaseFactoryIo.openDatabase(path);
    final ledger = stringMapStoreFactory.store('ledger||guest');
    await ledger.record('t:broken').put(db, {'id': 'broken', 'amount': 'x'});
    await db.close();

    final reopened = await engine();
    expect(reopened.transactions.map((t) => t.id), ['good']);
    expect(reopened.quarantine.single.recordId, 'broken');
    await reopened.close();
    reopened.dispose();
    db = await databaseFactoryIo.openDatabase(path);
    expect(await ledger.record('t:broken').get(db), isNull);
    expect(await ledger.record('t:good').get(db), isNotNull);
    await db.close();
  });

  test('small edits do not rewrite the whole ledger', () async {
    final store = await engine();
    await store.importTransactions([
      for (var i = 0; i < 2000; i++) tx('bulk-$i', 100 + i),
    ]);
    final path = '${dir.path}/balance.sembast';
    final before = File(path).lengthSync();
    for (var i = 0; i < 20; i++) {
      await store.saveTransaction(tx('edit-$i', 100));
    }
    // 20 single-record edits append kilobytes, not 20 copies of the ledger.
    expect(File(path).lengthSync() - before, lessThan(before ~/ 4));
    await store.close();
    store.dispose();
  });

  test('without foreign writes the ledger is not read again', () async {
    final storage = CountingStorage();
    final store = AppStore(storage: storage, background: true);
    await store.initialize();
    // Until the first write there is no revision yet, so it reloads once.
    await store.saveTransaction(tx('first', 100));
    final readsAfterOpen = storage.reads;
    final invalidationsAfterOpen = storage.invalidations;
    for (var i = 0; i < 5; i++) {
      await store.saveTransaction(tx('t$i', 100));
    }
    expect(storage.reads, readsAfterOpen);
    expect(storage.invalidations, invalidationsAfterOpen);
    // Another engine announces a new revision: the next operation reloads.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ledgerRevision', 'foreign');
    await store.saveTransaction(tx('t5', 100));
    expect(storage.reads, greaterThan(readsAfterOpen));
    expect(storage.invalidations, invalidationsAfterOpen + 1);
    expect(store.transactions, hasLength(7));
    store.dispose();
  });

  test(
    'timestamps stay strictly increasing without scanning the queue',
    () async {
      final store = AppStore(
        storage: MemorySnapshotStorage(),
        background: true,
      );
      await store.initialize();
      for (var i = 0; i < 50; i++) {
        await store.saveTransaction(tx('t$i', 100));
      }
      final times = store.transactions.map((t) => t.updatedAt).toList()..sort();
      for (var i = 1; i < times.length; i++) {
        expect(times[i].isAfter(times[i - 1]), isTrue);
      }
      store.dispose();
    },
  );
}

class CountingStorage extends MemorySnapshotStorage {
  int reads = 0, invalidations = 0;
  @override
  Future<Map<String, dynamic>?> read(String key) {
    reads++;
    return super.read(key);
  }

  @override
  Future<void> invalidate() async => invalidations++;
}
