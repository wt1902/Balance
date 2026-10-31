import 'dart:async';
import 'dart:js_interop';

@JS('isSecureContext')
external bool get _secureContext;

@JS('navigator.locks')
external JSObject? get _navigatorLocks;

extension type _LockManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(JSString name, JSFunction callback);
}

/// Holds the origin-wide Web Lock until release, including IndexedDB commits
/// and rotated refresh-token persistence. Browser teardown releases the lock.
class PlatformRuntimeLock {
  bool _waiting = false;
  Completer<JSAny?>? _release;
  Future<JSAny?>? _request;

  Future<void> acquire() async {
    if (_waiting || _release != null) {
      throw StateError('Browser ledger lock is already held or pending');
    }
    if (!_secureContext) {
      throw StateError(
        'Для безопасного хранения данных в нескольких вкладках требуется HTTPS '
        '(или localhost). Откройте приложение по защищённому адресу.',
      );
    }
    final manager = _navigatorLocks;
    if (manager == null) {
      throw StateError(
        'Браузер не поддерживает Web Locks API. Обновите браузер: '
        'без блокировки вкладок безопасная синхронизация недоступна.',
      );
    }
    final ready = Completer<void>();
    final release = Completer<JSAny?>();
    _waiting = true;
    try {
      final request = _LockManager(manager)
          .request(
            'balance-ledger-v1'.toJS,
            ((JSAny? lock) {
              _waiting = false;
              _release = release;
              ready.complete();
              return release.future.toJS;
            }).toJS,
          )
          .toDart;
      _request = request;
      // A rejected request must wake an acquiring caller, not leave it waiting
      // forever. Keep a rejection handler attached even before release awaits it.
      unawaited(
        request.then<void>(
          (_) {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('Browser ledger lock was not granted'),
              );
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('Не удалось получить блокировку данных браузера'),
                stack,
              );
            }
          },
        ),
      );
      await ready.future;
    } catch (_) {
      _waiting = false;
      _release = null;
      _request = null;
      rethrow;
    }
  }

  Future<void> release() async {
    final release = _release;
    if (release == null) throw StateError('Browser ledger lock is not held');
    release.complete(null);
    try {
      // Resolves only after navigator.locks has actually released ownership.
      await _request;
    } finally {
      _release = null;
      _request = null;
    }
  }
}
