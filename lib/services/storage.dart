import 'package:sembast/sembast.dart';

import 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as platform;

/// A single transaction replaces the complete ledger, pending changes and cursor.
abstract class SnapshotStorage {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> close();
}

/// Connections are opened lazily and closed after every operation, so another
/// Flutter engine never reads through an old Sembast in-memory cache. Android
/// callers serialize complete operations with the shared native store lock.
class LedgerStorage implements SnapshotStorage {
  LedgerStorage._();
  final _store = stringMapStoreFactory.store('snapshots');
  static Future<LedgerStorage> open() async => LedgerStorage._();
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final db = await platform.openLedgerDatabase();
    try {
      return await _store.record(key).get(db);
    } finally {
      await db.close();
    }
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    final db = await platform.openLedgerDatabase();
    try {
      await db.transaction((txn) async {
        await _store.record(key).put(txn, value);
      });
    } finally {
      await db.close();
    }
  }

  @override
  Future<void> close() async {}
}

class MemorySnapshotStorage implements SnapshotStorage {
  final Map<String, Map<String, dynamic>> values = {};
  @override
  Future<Map<String, dynamic>?> read(String key) async => values[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    values[key] = value;
  }

  @override
  Future<void> close() async {}
}
