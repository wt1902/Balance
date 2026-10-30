import 'dart:convert';
import 'dart:math';

import 'package:balance_flutter/domain/pin_hash.dart';
import 'package:balance_flutter/services/app_lock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class FakeAuth extends LocalAuthentication {
  bool result = true;
  @override
  Future<bool> isDeviceSupported() async => true;
  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [
    BiometricType.fingerprint,
  ];
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async => result;
}

/// Secure storage that is unavailable, as on Linux without a keyring.
class BrokenSecureStorage extends FlutterSecureStorage {
  const BrokenSecureStorage();
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('no keyring');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('PBKDF2-HMAC-SHA256', () {
    test('matches published test vectors', () {
      List<int> derive(int c) =>
          PinHash.pbkdf2(utf8.encode('password'), utf8.encode('salt'), c);
      expect(
        hex(derive(1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        hex(derive(2)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
      expect(
        hex(derive(4096)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });
  });

  test('PIN format', () {
    for (final pin in ['1234', '12345678', '0000']) {
      expect(PinHash.isValid(pin), isTrue, reason: pin);
    }
    for (final pin in ['123', '123456789', '12a4', ' 1234', '']) {
      expect(PinHash.isValid(pin), isFalse, reason: pin);
    }
  });

  test('stored hash verifies only the same PIN and never keeps it', () {
    final stored = PinHash.create('2580', iterations: 1000, random: Random(1));
    expect(jsonEncode(stored), isNot(contains('2580')));
    expect(PinHash.verify('2580', stored), isTrue);
    expect(PinHash.verify('2581', stored), isFalse);
    final other = PinHash.create('2580', iterations: 1000, random: Random(2));
    expect(other['salt'], isNot(stored['salt']));
    expect(() => PinHash.verify('2580', {'salt': 1}), throwsFormatException);
  });

  group('AppLock', () {
    var now = DateTime(2026, 10, 30, 12);
    late FakeAuth auth;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      now = DateTime(2026, 10, 30, 12);
      auth = FakeAuth();
    });
    Future<AppLock> open() async {
      final lock = AppLock(auth: auth, clock: () => now, iterations: 500);
      await lock.initialize();
      return lock;
    }

    test('enable, lock on start, unlock, disable', () async {
      final lock = await open();
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
      await expectLater(lock.enable('12'), throwsA(isA<AppLockException>()));
      await lock.enable('2468');
      expect(lock.enabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      // Only the switch is a preference; the PIN hash is in secure storage.
      expect(prefs.getKeys().any((k) => k.contains('pin')), isFalse);
      expect(prefs.getKeys().map(prefs.get).join(), isNot(contains('2468')));
      lock.dispose();

      final restarted = await open();
      expect(restarted.locked, isTrue);
      expect(await restarted.unlock('1111'), isFalse);
      expect(restarted.locked, isTrue);
      expect(await restarted.unlock('2468'), isTrue);
      expect(restarted.locked, isFalse);
      await expectLater(
        restarted.disable('0000'),
        throwsA(isA<AppLockException>()),
      );
      await restarted.disable('2468');
      expect(restarted.enabled, isFalse);
      restarted.dispose();
      final third = await open();
      expect(third.locked, isFalse);
      third.dispose();
    });

    test('wrong PINs are throttled across restarts', () async {
      final lock = await open();
      await lock.enable('2468');
      lock.lockNow();
      for (var i = 0; i < 4; i++) {
        expect(await lock.unlock('0000'), isFalse);
      }
      expect(lock.waitSeconds, 0);
      expect(await lock.unlock('0000'), isFalse);
      expect(lock.waitSeconds, inInclusiveRange(30, 31));
      // Even the right PIN waits.
      await expectLater(lock.unlock('2468'), throwsA(isA<AppLockException>()));
      lock.dispose();

      final restarted = await open();
      expect(restarted.waitSeconds, greaterThan(0));
      now = now.add(const Duration(seconds: 31));
      expect(await restarted.unlock('0000'), isFalse);
      // The sixth failure doubles the wait.
      expect(restarted.waitSeconds, inInclusiveRange(60, 61));
      now = now.add(const Duration(seconds: 61));
      expect(await restarted.unlock('2468'), isTrue);
      expect(restarted.failures, 0);
      expect(restarted.waitSeconds, 0);
      restarted.dispose();
    });

    test('relocks after the chosen time in the background', () async {
      final lock = await open();
      await lock.enable('2468');
      await lock.setLockAfter(60);
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(lock.obscured, isTrue);
      now = now.add(const Duration(seconds: 30));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isFalse);
      expect(lock.obscured, isFalse);
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 60));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
      lock.dispose();
    });

    test(
      'biometrics need a successful scan to turn on and to unlock',
      () async {
        final lock = await open();
        expect(lock.biometricsAvailable, isTrue);
        await lock.enable('2468');
        auth.result = false;
        await expectLater(
          lock.setBiometrics(true),
          throwsA(isA<AppLockException>()),
        );
        expect(lock.biometrics, isFalse);
        auth.result = true;
        await lock.setBiometrics(true);
        lock.lockNow();
        auth.result = false;
        expect(await lock.unlockWithBiometrics(), isFalse);
        expect(lock.locked, isTrue);
        auth.result = true;
        expect(await lock.unlockWithBiometrics(), isTrue);
        expect(lock.locked, isFalse);
        lock.dispose();
      },
    );

    test('no secure storage means no lock, never a weaker fallback', () async {
      final lock = AppLock(
        auth: auth,
        clock: () => now,
        iterations: 500,
        secureStorage: const BrokenSecureStorage(),
      );
      await lock.initialize();
      await expectLater(
        lock.enable('2468'),
        throwsA(
          isA<AppLockException>().having(
            (e) => e.message,
            'message',
            contains('Защищённое хранилище недоступно'),
          ),
        ),
      );
      expect(lock.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('privacy.appLock'), isNot(true));
      lock.dispose();
    });
  });
}
