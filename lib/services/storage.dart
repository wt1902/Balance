import 'package:sembast/sembast.dart';

import 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as platform;

/// Record keys of a scope's ledger: `t:`, `c:`, `b:` + id for transactions,
/// categories and budgets, `d:`/`x:` + `entity:id` for queued changes and
/// tombstones. Cursor and last sync time live in a `meta` record.
const ledgerSections = {
  't': 'transactions',
  'c': 'categories',
  'b': 'budgets',
  'd': 'dirty',
  'x': 'tombstones',
};

/// Snapshot read back from per-record storage. [ledgerLayout] marks a
/// snapshot that [SnapshotStorage.writeLedger] deltas can be applied to.
const ledgerLayoutKey = 'storageLayout';
const ledgerLayout = 2;

/// Changes to one scope since the last write, committed in one transaction.
class LedgerDelta {
  const LedgerDelta({
    required this.upserts,
    required this.deletes,
    required this.meta,
    this.replace = false,
  });

  final Map<String, Map<String, dynamic>> upserts;
  final List<String> deletes;
  final Map<String, dynamic> meta;

  /// Drop every other stored record of the scope (first write, migration).
  final bool replace;

  /// A whole snapshot written as records, replacing what the scope had.
  factory LedgerDelta.fromSnapshot(Map<String, dynamic> snapshot) {
    final upserts = <String, Map<String, dynamic>>{};
    for (final entry in ledgerSections.entries) {
      for (final item in (snapshot[entry.value] as List? ?? const [])) {
        final json = Map<String, dynamic>.from(item as Map);
        final id = entry.key == 'd' || entry.key == 'x'
            ? '${json['entity']}:${json['id']}'
            : json['id'];
        upserts['${entry.key}:$id'] = json;
      }
    }
    return LedgerDelta(
      upserts: upserts,
      deletes: const [],
      meta: {
        'cursor': snapshot['cursor'] ?? 0,
        'lastSyncAt': snapshot['lastSyncAt'],
      },
      replace: true,
    );
  }
}

Map<String, dynamic> snapshotFromRecords(
  Map<String, Map<String, dynamic>> records,
  Map<String, dynamic>? meta,
) {
  final lists = {for (final name in ledgerSections.values) name: <Object>[]};
  for (final entry in records.entries) {
    final section = ledgerSections[entry.key.split(':').first];
    if (section != null) lists[section]!.add(entry.value);
  }
  return {
    ...lists,
    'cursor': meta?['cursor'] ?? 0,
    'lastSyncAt': meta?['lastSyncAt'],
    ledgerLayoutKey: ledgerLayout,
  };
}

/// A single transaction replaces the complete ledger, pending changes and cursor.
abstract class SnapshotStorage {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value);

  /// Applies [delta] to [scope] atomically: a pull page with its cursor is
  /// committed completely or not at all.
  Future<void> writeLedger(String scope, LedgerDelta delta);

  /// Drops any cached state after another engine changed the data.
  Future<void> invalidate();
  Future<void> close();
}

/// The connection stays open between operations: Sembast loads the whole file
/// on open. AppStore calls [invalidate] when another engine (background sync,
/// another tab) wrote since, so an old Sembast in-memory cache is never read.
/// Callers serialize complete operations with the shared runtime lock.
class LedgerStorage implements SnapshotStorage {
  LedgerStorage._(this._open);
  final Future<Database> Function() _open;
  final _store = stringMapStoreFactory.store('snapshots');
  StoreRef<String, Map<String, Object?>> _ledger(String scope) =>
      stringMapStoreFactory.store('ledger|$scope');
  Database? _db;
  Future<Database> _database() async => _db ??= await _open();

  /// [opener] replaces the platform database, e.g. a temporary file in tools.
  static Future<LedgerStorage> open({
    Future<Database> Function()? opener,
  }) async => LedgerStorage._(opener ?? platform.openLedgerDatabase);
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final db = await _database();
    final records = await _ledger(key).find(db);
    // Before the first per-record write a scope is still one legacy snapshot.
    if (records.isEmpty) return _store.record(key).get(db);
    final meta = <String, dynamic>{};
    final values = <String, Map<String, dynamic>>{};
    for (final record in records) {
      if (record.key == 'meta') {
        meta.addAll(record.value);
      } else {
        values[record.key] = record.value;
      }
    }
    return snapshotFromRecords(values, meta);
  }

  @override
  Future<void> writeLedger(String scope, LedgerDelta delta) async {
    final db = await _database();
    final ledger = _ledger(scope);
    try {
      await db.transaction((txn) async {
        if (delta.replace) {
          await ledger.delete(txn);
          await _store.record(scope).delete(txn);
        }
        // Batched: a sign-in or full resync can touch every record.
        if (delta.deletes.isNotEmpty) {
          await ledger.records(delta.deletes).delete(txn);
        }
        if (delta.upserts.isNotEmpty) {
          await ledger
              .records(delta.upserts.keys.toList())
              .put(txn, delta.upserts.values.toList());
        }
        await ledger.record('meta').put(txn, delta.meta);
      });
      await _flush(db);
    } catch (_) {
      await invalidate();
      rethrow;
    }
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    final db = await _database();
    try {
      await db.transaction((txn) async {
        // A whole snapshot supersedes any per-record ledger of the same key.
        await _ledger(key).delete(txn);
        await _store.record(key).put(txn, value);
      });
      await _flush(db);
    } catch (_) {
      // Reopen next time rather than trust a cache after a failed commit.
      await invalidate();
      rethrow;
    }
  }

  /// Sembast commits a transaction in memory and appends to the file lazily.
  /// Wait for the file write, so it is durable and another engine sees it
  /// once the runtime lock is released. `flush` is not in Sembast's public
  /// API; without it, closing the database waits for the write as well.
  Future<void> _flush(Database db) async {
    try {
      await (db as dynamic).flush();
    } on NoSuchMethodError {
      await invalidate();
    }
  }

  @override
  Future<void> invalidate() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  @override
  Future<void> close() => invalidate();
}

class MemorySnapshotStorage implements SnapshotStorage {
  /// Snapshots by key, as tests inspect them; ledgers are kept assembled.
  final Map<String, Map<String, dynamic>> values = {};
  final Map<String, Map<String, Map<String, dynamic>>> _records = {};

  @override
  Future<void> writeLedger(String scope, LedgerDelta delta) async {
    final current = <String, Map<String, dynamic>>{
      if (values[scope]?[ledgerLayoutKey] == ledgerLayout && !delta.replace)
        ...?_records[scope],
    };
    for (final key in delta.deletes) {
      current.remove(key);
    }
    current.addAll(delta.upserts);
    // Through write(), so test doubles that fail writes also fail deltas.
    await write(scope, snapshotFromRecords(current, delta.meta));
    _records[scope] = current;
  }

  @override
  Future<Map<String, dynamic>?> read(String key) async => values[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    values[key] = value;
  }

  @override
  Future<void> invalidate() async {}

  @override
  Future<void> close() async {}
}
