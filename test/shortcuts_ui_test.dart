import 'package:balance_flutter/ui/editors.dart';
import 'package:balance_flutter/ui/privacy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'privacy_ui_test.dart' show Env, boot, finish, settle;
import 'widget_test.dart' show loadReadableFont;

const wide = Size(1280, 900);
const phone = Size(390, 844);

Future<void> combo(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey modifier = LogicalKeyboardKey.controlLeft,
}) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

int selectedPage(WidgetTester tester) {
  final bar = find.byType(NavigationBar);
  if (bar.evaluate().isNotEmpty) {
    return tester.widget<NavigationBar>(bar).selectedIndex;
  }
  return tester
      .widget<NavigationRail>(find.byType(NavigationRail))
      .selectedIndex!;
}

final search = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == 'Поиск по категории или заметке',
);

bool searchFocused(WidgetTester tester) =>
    tester.widget<TextField>(search).focusNode?.hasFocus ?? false;

Future<Env> bootOn(
  WidgetTester tester,
  TargetPlatform platform,
  Size size, {
  bool enabled = false,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  return boot(tester, size, enabled: enabled);
}

void main() {
  setUpAll(loadReadableFont);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  final digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
  ];

  for (final size in [wide, phone]) {
    testWidgets('Ctrl+1..5, Ctrl+N and Ctrl+F at $size', (tester) async {
      final env = await bootOn(tester, TargetPlatform.linux, size);
      for (final i in [4, 2, 3, 1, 0]) {
        await combo(tester, digits[i]);
        expect(selectedPage(tester), i, reason: 'Ctrl+${i + 1}');
      }
      await combo(tester, LogicalKeyboardKey.keyF);
      expect(selectedPage(tester), 1);
      expect(search, findsOneWidget);
      expect(searchFocused(tester), isTrue);

      await combo(tester, LogicalKeyboardKey.keyN);
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(find.text('Новая операция'), findsWidgets);
      // A second Ctrl+N over the open editor does not stack another one.
      await combo(tester, LogicalKeyboardKey.keyN);
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
      await finish(tester, env);
    });
  }

  testWidgets('Ctrl+F from another page focuses search', (tester) async {
    final env = await bootOn(tester, TargetPlatform.linux, wide);
    await combo(tester, digits[3]);
    await combo(tester, LogicalKeyboardKey.keyF);
    expect(selectedPage(tester), 1);
    expect(searchFocused(tester), isTrue);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });

  testWidgets('Cmd+N on macOS opens editor, Ctrl+N does not', (tester) async {
    final env = await bootOn(tester, TargetPlatform.macOS, wide);
    await combo(tester, LogicalKeyboardKey.keyN);
    expect(find.byType(TransactionEditor), findsNothing);
    await combo(
      tester,
      LogicalKeyboardKey.keyN,
      modifier: LogicalKeyboardKey.metaLeft,
    );
    expect(find.byType(TransactionEditor), findsOneWidget);
    await combo(tester, digits[2], modifier: LogicalKeyboardKey.metaLeft);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });

  testWidgets('Ctrl+L locks and shortcuts are ignored while locked', (
    tester,
  ) async {
    final env = await bootOn(tester, TargetPlatform.linux, wide, enabled: true);
    expect(env.lock.locked, isFalse);
    await combo(tester, digits[2]);
    expect(selectedPage(tester), 2);
    await combo(tester, LogicalKeyboardKey.keyL);
    await settle(tester);
    expect(env.lock.locked, isTrue);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(find.text('Введите PIN-код'), findsWidgets);
    await combo(tester, LogicalKeyboardKey.keyN);
    await combo(tester, digits[0]);
    expect(find.byType(TransactionEditor), findsNothing);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });

  testWidgets('Ctrl+L does nothing without an app lock', (tester) async {
    final env = await bootOn(tester, TargetPlatform.linux, wide);
    await combo(tester, LogicalKeyboardKey.keyL);
    expect(env.lock.locked, isFalse);
    expect(find.byType(LockScreen), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });

  Future<void> openSettings(WidgetTester tester) async {
    await combo(tester, digits[4]);
  }

  testWidgets('hotkeys panel on desktop', (tester) async {
    final env = await bootOn(tester, TargetPlatform.linux, wide);
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Горячие клавиши'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Горячие клавиши'), findsOneWidget);
    expect(find.text('Ctrl+N'), findsOneWidget);
    expect(find.text('Новая операция'), findsWidgets);
    expect(find.text('Ctrl+L'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });

  testWidgets('hotkeys panel shows Ctrl+L when lock enabled', (tester) async {
    final env = await bootOn(tester, TargetPlatform.linux, wide, enabled: true);
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Ctrl+L'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Ctrl+L'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });

  testWidgets('hotkeys panel absent on Android', (tester) async {
    final env = await bootOn(tester, TargetPlatform.android, phone);
    final bar = find.byType(NavigationBar);
    await tester.tap(
      find
          .descendant(of: bar, matching: find.byIcon(Icons.settings_outlined))
          .first,
    );
    await tester.pumpAndSettle();
    expect(selectedPage(tester), 4);
    await tester.dragUntilVisible(
      find.text('Приватность'),
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    expect(find.text('Горячие клавиши'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    await finish(tester, env);
  });
}
