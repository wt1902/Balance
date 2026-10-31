import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime_lock_stub.dart'
    if (dart.library.js_interop) 'runtime_lock_web.dart'
    if (dart.library.io) 'runtime_lock_io.dart'
    as platform;

/// One ledger operation at a time across everything that opens the ledger:
/// the native Android lock (UI and WorkManager engines), Web Locks across
/// tabs, and an OS file lock across desktop processes. Callers must hold it
/// over reloading preferences/session, ledger IO and sync.
class RuntimeLock {
  static const _channel = MethodChannel('balance/runtime');
  final _platformLock = platform.PlatformRuntimeLock();
  String? _token;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> acquire() async {
    if (!_android) return _platformLock.acquire();
    if (_token != null) throw StateError('Ledger lock is already held');
    final token = await _channel.invokeMethod<String>('acquireLock');
    if (token == null || token.isEmpty) {
      throw StateError('Native ledger lock returned no ownership token');
    }
    _token = token;
  }

  Future<void> release() async {
    if (!_android) return _platformLock.release();
    final token = _token;
    if (token == null) throw StateError('Ledger lock is not held');
    await _channel.invokeMethod<void>('releaseLock', {'token': token});
    _token = null;
  }
}
