import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime_lock_stub.dart'
    if (dart.library.js_interop) 'runtime_lock_web.dart'
    as browser;

/// Native Android lock shared by the UI engine and WorkManager headless engines.
/// Callers must hold it over reloading preferences/session, ledger IO and sync.
class RuntimeLock {
  static const _channel = MethodChannel('balance/runtime');
  final _browserLock = browser.BrowserRuntimeLock();
  String? _token;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> acquire() async {
    if (kIsWeb) return _browserLock.acquire();
    if (!_android) return;
    if (_token != null) throw StateError('Ledger lock is already held');
    final token = await _channel.invokeMethod<String>('acquireLock');
    if (token == null || token.isEmpty) {
      throw StateError('Native ledger lock returned no ownership token');
    }
    _token = token;
  }

  Future<void> release() async {
    if (kIsWeb) return _browserLock.release();
    if (!_android) return;
    final token = _token;
    if (token == null) throw StateError('Ledger lock is not held');
    await _channel.invokeMethod<void>('releaseLock', {'token': token});
    _token = null;
  }
}
