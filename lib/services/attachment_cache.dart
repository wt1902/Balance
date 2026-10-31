import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_cache_native.dart'
    if (dart.library.js_interop) 'attachment_cache_web.dart'
    as platform;

/// Local copies of attachment files by SHA-256 (contract v2 §8). Files are
/// content-addressed, so one copy serves every ledger. A file whose bytes no
/// longer match its hash is dropped and downloaded again.
abstract class AttachmentCache {
  Future<Uint8List?> read(String sha256);
  Future<void> write(String sha256, Uint8List bytes);
  Future<void> delete(String sha256);

  static Future<AttachmentCache> open() => platform.openAttachmentCache();

  static String hash(List<int> bytes) => sha256.convert(bytes).toString();
}

/// Verifies bytes against their name on the way in and out.
abstract class VerifiedAttachmentCache implements AttachmentCache {
  Future<Uint8List?> readRaw(String sha256);
  Future<void> writeRaw(String sha256, Uint8List bytes);

  @override
  Future<Uint8List?> read(String sha256) async {
    final bytes = await readRaw(sha256);
    if (bytes == null) return null;
    if (AttachmentCache.hash(bytes) == sha256) return bytes;
    await delete(sha256);
    return null;
  }

  @override
  Future<void> write(String sha256, Uint8List bytes) {
    if (AttachmentCache.hash(bytes) != sha256) {
      throw ArgumentError('SHA-256 не совпадает с содержимым файла');
    }
    return writeRaw(sha256, bytes);
  }
}

class MemoryAttachmentCache extends VerifiedAttachmentCache {
  final Map<String, Uint8List> files = {};

  @override
  Future<Uint8List?> readRaw(String sha256) async => files[sha256];
  @override
  Future<void> writeRaw(String sha256, Uint8List bytes) async =>
      files[sha256] = Uint8List.fromList(bytes);
  @override
  Future<void> delete(String sha256) async => files.remove(sha256);
}
