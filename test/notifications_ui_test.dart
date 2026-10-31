import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/notifications.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app.dart';
import 'package:balance_flutter/ui/editors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show loadReadableFont, navigate;

class FakeSink implements NotificationSink {
  bool permission = true;
  String? launch;
  final shown = <String>[];
  final scheduled = <DateTime>[];
  final cancels = <int>[];

  @override
  Future<void> initialize(void Function(String payload) onTap) async {}
  @override
  Future<String?> launchPayload() async => launch;
  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<void> show(int id, String title, String body, String payload) async =>
      shown.add(payload);
  @override
  Future<void> scheduleDaily(
    int id,
    String title,
    String body,
    DateTime first,
    String payload,
  ) async => scheduled.add(first);
  @override
  Future<void> cancel(int id) async => cancels.add(id);
}

const sizes = [Size(320, 568), Size(390, 844), Size(1280, 900)];

class Env {
  Env(this.store, this.notifications, this.sink);
  final AppStore store;
  final Notifications notifications;
  final FakeSink sink;
}

Future<Env> boot(
  WidgetTester tester,
  Size size, {
  bool permission = true,
  String? launch,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final sink = FakeSink()
    ..permission = permission
    ..launch = launch;
  late final AppStore store;
  late final Notifications notifications;
  await tester.runAsync(() async {
    store = AppStore(storage: MemorySnapshotStorage());
    notifications = Notifications(
      sink: sink,
      clock: () => DateTime(2026, 5, 10, 12),
    );
    await store.initialize();
    await notifications.initialize();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    BalanceApp(store: store, notifications: notifications),
  );
  await tester.pumpAndSettle();
  return Env(store, notifications, sink);
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  await navigate(tester, 4);
  await tester.scrollUntilVisible(
    find.text('Напоминать внести траты'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void noError(WidgetTester tester) => expect(tester.takeException(), isNull);

Future<void> finish(WidgetTester tester, Env env) async {
  await tester.pumpWidget(const SizedBox());
  env.notifications.dispose();
  env.store.dispose();
}

void main() {
  setUpAll(loadReadableFont);

  for (final size in sizes) {
    testWidgets('budget alerts permission at $size', (tester) async {
      final env = await boot(tester, size);
      await openSettings(tester);
      expect(find.text('Уведомления'), findsWidgets);
      expect(find.text('Предупреждать о бюджете'), findsOneWidget);
      await tester.ensureVisible(find.text('Предупреждать о бюджете'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предупреждать о бюджете'));
      await settle(tester);
      expect(env.notifications.budgetAlerts, isTrue);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('budget alerts denied at $size', (tester) async {
      final env = await boot(tester, size, permission: false);
      await openSettings(tester);
      await tester.ensureVisible(find.text('Предупреждать о бюджете'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предупреждать о бюджете'));
      await settle(tester);
      expect(env.notifications.budgetAlerts, isFalse);
      expect(
        find.text('Уведомления запрещены. Разрешите их в настройках системы.'),
        findsOneWidget,
      );
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('reminder schedules at 20:00 at $size', (tester) async {
      final env = await boot(tester, size);
      await openSettings(tester);
      expect(find.text('Время напоминания'), findsNothing);
      await tester.tap(find.text('Напоминать внести траты'));
      await settle(tester);
      expect(env.notifications.reminder, isTrue);
      expect(env.sink.scheduled, hasLength(1));
      final first = env.sink.scheduled.single;
      expect([first.hour, first.minute], [20, 0]);
      expect(
        first.difference(DateTime(2026, 5, 10)).inDays,
        lessThanOrEqualTo(1),
      );
      await tester.scrollUntilVisible(
        find.text('Время напоминания'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Время напоминания'), findsOneWidget);
      expect(find.text('20:00'), findsOneWidget);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('launch payload reminder opens editor at $size', (
      tester,
    ) async {
      final env = await boot(tester, size, launch: 'reminder');
      await settle(tester);
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(find.text('Новая операция'), findsWidgets);
      noError(tester);
      await finish(tester, env);
    });

    testWidgets('tap budget opens budgets page at $size', (tester) async {
      final env = await boot(tester, size);
      env.notifications.onTap!('budget');
      await tester.pumpAndSettle();
      expect(find.text('Бюджеты'), findsWidgets);
      expect(find.byType(TransactionEditor), findsNothing);
      noError(tester);
      await finish(tester, env);
    });
  }
}
