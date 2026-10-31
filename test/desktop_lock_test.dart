import 'dart:convert';
import 'dart:io';

import 'package:balance_flutter/services/runtime_lock_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two desktop instances share one ledger file; the OS file lock must make
/// the second wait until the first releases it.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('lock'));
  tearDown(() => dir.delete(recursive: true));

  test('acquire and release, and misuse fails', () async {
    final lock = PlatformRuntimeLock(
      path: '${dir.path}/balance.lock',
      desktop: true,
    );
    await lock.acquire();
    await expectLater(lock.acquire(), throwsStateError);
    await lock.release();
    await expectLater(lock.release(), throwsStateError);
    await lock.acquire();
    await lock.release();
  });

  test('another process holding the lock blocks until it lets go', () async {
    final path = '${dir.path}/balance.lock';
    final other = await Process.start('dart', [
      'run',
      'test/fixtures/hold_lock.dart',
      path,
    ]);
    final lines = other.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await lines.firstWhere((line) => line == 'locked');

    final lock = PlatformRuntimeLock(path: path, desktop: true);
    var acquired = false;
    final waiting = lock.acquire().then((_) => acquired = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(acquired, isFalse, reason: 'the other process still holds it');

    other.stdin.writeln('release');
    await other.exitCode;
    await waiting.timeout(const Duration(seconds: 10));
    expect(acquired, isTrue);
    await lock.release();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('mobile platforms do nothing', () async {
    final lock = PlatformRuntimeLock(
      path: '${dir.path}/x.lock',
      desktop: false,
    );
    await lock.acquire();
    await lock.release();
    expect(File('${dir.path}/x.lock').existsSync(), isFalse);
  });
}
