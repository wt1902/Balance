import 'package:balance_flutter/services/app_lock.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:balance_flutter/ui/privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show loadReadableFont, navigate;

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
    Iterable<Object?> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async => result;
}

const sizes = [Size(320, 568), Size(390, 844), Size(1280, 900)];

class Env {
  Env(this.store, this.lock, this.auth);
  final AppStore store;
  final AppLock lock;
  final FakeAuth auth;
}

Future<Env> boot(
  WidgetTester tester,
  Size size, {
  bool enabled = false,
  bool biometrics = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final auth = FakeAuth();
  late final AppLock lock;
  late final AppStore store;
  // Created inside runAsync: AppStore's operation queue starts from a future
  // whose callbacks would otherwise wait for the fake-async zone.
  await tester.runAsync(() async {
    lock = AppLock(iterations: 1000, auth: auth);
    store = AppStore(storage: MemorySnapshotStorage());
    await lock.initialize();
    await store.initialize();
    if (enabled) {
      await lock.enable('1234');
      if (biometrics) await lock.setBiometrics(true);
    }
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(BalanceApp(store: store, lock: lock));
  await tester.pumpAndSettle();
  return Env(store, lock, auth);
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> pin(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(
      find.descendant(of: find.byType(PinPad), matching: find.text(d)).last,
    );
    await tester.pump();
  }
}

Future<void> done(WidgetTester tester) async {
  await tester.tap(
    find
        .descendant(of: find.byType(PinPad), matching: find.byIcon(Icons.check))
        .last,
  );
  await settle(tester);
}

Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  await navigate(tester, 4);
  await reveal(tester, find.text('Блокировка PIN-кодом'));
}

void noError(WidgetTester tester) => expect(tester.takeException(), isNull);

/// Disposes before the end of the test: a resumed AppStore starts its periodic
/// sync timer, which must not outlive the widget tree.
Future<void> finish(WidgetTester tester, Env env) async {
  await tester.pumpWidget(const SizedBox());
  env.lock.dispose();
  env.store.dispose();
}

void main() {
  setUpAll(loadReadableFont);

  for (final size in sizes) {
    testWidgets('enable PIN from settings at $size', (tester) async {
      final env = await boot(tester, size);
      await openSettings(tester);
      await tester.tap(find.text('Блокировка PIN-кодом'));
      await tester.pumpAndSettle();
      expect(find.text('Новый PIN-код'), findsOneWidget);
      noError(tester);
      await pin(tester, '1234');
      await done(tester);
      expect(find.text('Повторите PIN-код'), findsOneWidget);
      noError(tester);
      // Mismatch first.
      await pin(tester, '4321');
      await done(tester);
      expect(find.text('PIN-коды не совпадают'), findsOneWidget);
      expect(env.lock.enabled, isFalse);
      noError(tester);
      await pin(tester, '1234');
      await done(tester);
      expect(env.lock.enabled, isTrue);
      expect(find.text('Блокировка включена'), findsOneWidget);
      expect(env.lock.locked, isFalse);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('lock screen at $size', (tester) async {
      final env = await boot(tester, size);
      await tester.runAsync(() => env.lock.enable('1234'));
      env.lock.lockNow();
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.text('Введите PIN-код'), findsOneWidget);
      expect(find.text('Настройки', skipOffstage: false), findsWidgets);
      expect(find.text('Настройки'), findsNothing); // offstage
      noError(tester);

      await pin(tester, '9999');
      await done(tester);
      expect(find.text('Неверный PIN-код'), findsOneWidget);
      expect(env.lock.locked, isTrue);
      noError(tester);

      await pin(tester, '1234');
      await done(tester);
      expect(find.byType(LockScreen), findsNothing);
      expect(find.text('Настройки'), findsWidgets);
      noError(tester);

      // Physical keyboard.
      env.lock.lockNow();
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
      const keys = {
        '1': LogicalKeyboardKey.digit1,
        '2': LogicalKeyboardKey.digit2,
        '3': LogicalKeyboardKey.digit3,
        '4': LogicalKeyboardKey.digit4,
      };
      for (final e in keys.entries) {
        await tester.sendKeyDownEvent(e.value, character: e.key);
        await tester.sendKeyUpEvent(e.value);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byType(LockScreen), findsNothing);
      expect(env.lock.locked, isFalse);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('lifecycle at $size', (tester) async {
      final env = await boot(tester, size, enabled: true);
      expect(env.lock.locked, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(env.lock.locked, isTrue);
      expect(find.text('Введите PIN-код'), findsOneWidget);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('privacy cover at $size', (tester) async {
      final env = await boot(tester, size);
      await tester.runAsync(() => env.lock.setHideInRecents(true));
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyCover), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(PrivacyCover), findsOneWidget);
      noError(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyCover), findsNothing);
      expect(env.lock.locked, isFalse);
      expect(find.byType(LockScreen), findsNothing);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('biometrics at $size', (tester) async {
      final env = await boot(tester, size, enabled: true);
      await openSettings(tester);
      expect(find.text('Вход по биометрии'), findsOneWidget);
      await tester.tap(find.text('Вход по биометрии'));
      await settle(tester);
      expect(env.lock.biometrics, isTrue);
      noError(tester);

      // Lock; auto-prompt succeeds only if result true, so fail it first.
      env.auth.result = false;
      env.lock.lockNow();
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.text('По биометрии'), findsOneWidget);
      noError(tester);
      env.auth.result = true;
      await tester.tap(find.text('По биометрии'));
      await settle(tester);
      expect(env.lock.locked, isFalse);
      expect(find.byType(LockScreen), findsNothing);
      noError(tester);
      await finish(tester, env);
    });
  }
}
