// ignore_for_file: avoid_print
// Compile with `dart compile js scripts/probe_web_lock.dart -o /tmp/web-lock.js`.
// Run with Node 24.5+ (native navigator.locks) and isSecureContext=true.
// This tests JS Promise/ownership behavior, not browser/IndexedDB integration.
import 'dart:async';
import 'dart:js_interop';

import 'package:balance_flutter/services/runtime_lock_web.dart';

@JS('isSecureContext')
external set secureContext(bool value);

@JS('navigator')
external JSObject get navigatorObject;

@JS('navigator.locks')
external JSObject get lockManager;

@JS('Object.defineProperty')
external JSObject defineProperty(
  JSObject target,
  JSString property,
  JSObject descriptor,
);

Future<void> expectFailure(
  Future<void> Function() action,
  String message,
) async {
  try {
    await action();
  } on StateError catch (error) {
    if (error.message.toString().contains(message)) return;
    rethrow;
  }
  throw StateError('Expected failure containing $message');
}

Future<void> main() async {
  secureContext = true;
  final first = BrowserRuntimeLock();
  final second = BrowserRuntimeLock();
  await first.acquire();
  await expectFailure(first.acquire, 'already held');
  var acquired = false;
  final next = second.acquire().then((_) => acquired = true);
  await Future<void>.delayed(const Duration(milliseconds: 25));
  if (acquired) throw StateError('Second owner bypassed the origin lock');
  await first.release();
  await next;
  await second.release();
  await expectFailure(second.release, 'not held');

  secureContext = false;
  await expectFailure(BrowserRuntimeLock().acquire, 'HTTPS');
  secureContext = true;
  final original = lockManager;
  defineProperty(
    navigatorObject,
    'locks'.toJS,
    {'value': null, 'configurable': true}.jsify() as JSObject,
  );
  await expectFailure(BrowserRuntimeLock().acquire, 'Web Locks API');
  defineProperty(
    navigatorObject,
    'locks'.toJS,
    {'value': original, 'configurable': true}.jsify() as JSObject,
  );
  final restored = BrowserRuntimeLock();
  await restored.acquire();
  await restored.release();
  print('Web lock probe passed');
}
