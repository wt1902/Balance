import 'package:balance_flutter/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart'
    show boot, createStore, loadReadableFont, mockStorage, navigate, reveal;

const _phone = Size(390, 844);

void main() {
  setUpAll(loadReadableFont);
  setUp(mockStorage);

  testWidgets('system mode follows Russian and falls back to English', (
    tester,
  ) async {
    final dispatcher = tester.binding.platformDispatcher;
    dispatcher.localesTestValue = const [Locale('ru', 'RU')];
    final store = (await tester.runAsync(() => createStore(seeded: false)))!;
    await boot(tester, store, _phone);
    expect(find.text('Общий баланс'), findsOneWidget);

    await tester.runAsync(() => store.setAppLanguage('en'));
    await tester.pumpAndSettle();
    expect(find.text('Total balance'), findsOneWidget);
    await tester.runAsync(() => store.setAppLanguage('system'));
    await tester.pumpAndSettle();
    expect(find.text('Общий баланс'), findsOneWidget);

    dispatcher.localesTestValue = const [Locale('fr', 'FR'), Locale('ru')];
    await tester.pumpAndSettle();
    expect(find.text('Total balance'), findsOneWidget);
    expect(find.text('Общий баланс'), findsNothing);
  });

  testWidgets('an explicit language switches the open screen and is restored', (
    tester,
  ) async {
    final dispatcher = tester.binding.platformDispatcher;
    dispatcher.localesTestValue = const [Locale('de', 'DE')];
    final store = (await tester.runAsync(() => createStore(seeded: false)))!;
    await boot(tester, store, _phone);
    await navigate(tester, 4);

    final language = find.byKey(const ValueKey('app-language-system'));
    await reveal(tester, language);
    expect(find.text('App language'), findsOneWidget);
    await tester.tap(language);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Русский').last);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pumpAndSettle();
    expect(store.appLanguage, 'ru');
    expect(find.text('Язык приложения'), findsOneWidget);
    expect(find.text('App language'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('appLanguage'), 'ru');
    final restarted = (await tester.runAsync(
      () => createStore(seeded: false),
    ))!;
    expect(restarted.appLanguage, 'ru');
    await tester.pumpWidget(const SizedBox.shrink());
    await boot(tester, restarted, _phone);
    expect(find.text('Общий баланс'), findsOneWidget);

    await tester.runAsync(() => restarted.setAppLanguage('system'));
    await tester.pumpAndSettle();
    expect(find.text('Total balance'), findsOneWidget);
  });

  testWidgets('English formats amounts and displays translated categories', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localesTestValue = const [
      Locale('en', 'US'),
    ];
    final store = (await tester.runAsync(() => createStore()))!;
    await boot(tester, store, const Size(320, 568));
    expect(find.text('Total balance'), findsOneWidget);
    await navigate(tester, 1);
    expect(find.text('Transactions'), findsWidgets);
    expect(find.textContaining('250,000.00'), findsWidgets);
    expect(find.text('Salary'), findsOneWidget);
    expect(
      localDateFormat('d MMM y').format(DateTime(2026, 11, 24)),
      'Nov 24, 2026',
    );
    expect(tester.takeException(), isNull);
  });
}
