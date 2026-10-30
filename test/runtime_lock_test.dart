import 'package:balance_flutter/services/runtime_lock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('balance/runtime');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android release carries the acquired engine token', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'acquireLock' ? 'owner-token' : null;
    });
    final lock = RuntimeLock();
    await lock.acquire();
    await expectLater(lock.acquire(), throwsStateError);
    await lock.release();
    expect(calls.map((call) => call.method), ['acquireLock', 'releaseLock']);
    expect(calls.last.arguments, {'token': 'owner-token'});
    await expectLater(lock.release(), throwsStateError);
  });

  test('missing native ownership token fails closed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await expectLater(RuntimeLock().acquire(), throwsStateError);
  });

  test('iOS never invokes the native lock channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('Unexpected native channel call'),
    );
    final lock = RuntimeLock();
    await lock.acquire();
    await lock.release();
  });
}
