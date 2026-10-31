import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Desktop processes share one ledger file. An exclusive OS lock on a file
/// next to it serializes their operations like the Android store lock;
/// together with `ledgerRevision` a second instance stays coherent.
class PlatformRuntimeLock {
  PlatformRuntimeLock({this.path, bool? desktop})
    : _desktop =
          desktop ??
          (defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.macOS);

  /// Lock file; defaults to `balance.lock` in the application support folder.
  final String? path;
  final bool _desktop;
  RandomAccessFile? _file;

  Future<void> acquire() async {
    if (!_desktop) return;
    if (_file != null) throw StateError('Ledger lock is already held');
    final file = File(
      path ?? '${(await getApplicationSupportDirectory()).path}/balance.lock',
    );
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    try {
      // Waits on the IO thread, not in the isolate.
      await handle.lock(FileLock.blockingExclusive);
    } catch (_) {
      await handle.close();
      rethrow;
    }
    _file = handle;
  }

  Future<void> release() async {
    if (!_desktop) return;
    final handle = _file;
    if (handle == null) throw StateError('Ledger lock is not held');
    _file = null;
    try {
      await handle.unlock();
    } finally {
      await handle.close();
    }
  }
}
