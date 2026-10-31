import 'dart:typed_data';

import 'package:sembast/blob.dart';
import 'package:sembast_web/sembast_web.dart';

import 'attachment_cache.dart';

Future<AttachmentCache> openAttachmentCache() async =>
    _WebAttachmentCache(await databaseFactoryWeb.openDatabase('balance-files'));

/// IndexedDB through Sembast, in a database of its own so the ledger
/// database stays small.
class _WebAttachmentCache extends VerifiedAttachmentCache {
  _WebAttachmentCache(this._db);
  final Database _db;
  final _store = StoreRef<String, Blob>('attachments');

  @override
  Future<Uint8List?> readRaw(String sha256) async =>
      (await _store.record(sha256).get(_db))?.bytes;

  @override
  Future<void> writeRaw(String sha256, Uint8List bytes) =>
      _store.record(sha256).put(_db, Blob(bytes));

  @override
  Future<void> delete(String sha256) => _store.record(sha256).delete(_db);
}
