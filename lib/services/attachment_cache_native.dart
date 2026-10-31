import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'attachment_cache.dart';

Future<AttachmentCache> openAttachmentCache() async {
  final support = await getApplicationSupportDirectory();
  return FileAttachmentCache(Directory('${support.path}/attachments'));
}

/// One file per SHA-256, written to a temporary name and renamed, so a
/// crash never leaves a partial file under the final name.
class FileAttachmentCache extends VerifiedAttachmentCache {
  FileAttachmentCache(this.directory);
  final Directory directory;

  File _file(String sha256) => File('${directory.path}/$sha256');

  @override
  Future<Uint8List?> readRaw(String sha256) async {
    final file = _file(sha256);
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<void> writeRaw(String sha256, Uint8List bytes) async {
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/$sha256.part');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(_file(sha256).path);
  }

  @override
  Future<void> delete(String sha256) async {
    final file = _file(sha256);
    if (await file.exists()) await file.delete();
  }
}
