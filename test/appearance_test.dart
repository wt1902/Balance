import 'package:balance_flutter/domain/appearance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(fixtures.mockStorage);

  test('OLED uses pure black for surfaces, cards, navigation and dialogs', () {
    final theme = BalanceThemes.build(Brightness.dark, ColorPreset.oled);
    final scheme = theme.colorScheme;
    expect(theme.brightness, Brightness.dark);
    for (final surface in [
      theme.scaffoldBackgroundColor,
      theme.canvasColor,
      scheme.surface,
      scheme.surfaceDim,
      scheme.surfaceBright,
      scheme.surfaceContainerLowest,
      scheme.surfaceContainerLow,
      scheme.surfaceContainer,
      scheme.surfaceContainerHigh,
      scheme.surfaceContainerHighest,
      scheme.primaryContainer,
      theme.appBarTheme.backgroundColor,
      theme.navigationBarTheme.backgroundColor,
      theme.navigationRailTheme.backgroundColor,
      theme.dialogTheme.backgroundColor,
    ]) {
      expect(surface, Colors.black);
    }
    expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
    expect(theme.applyElevationOverlayColor, isFalse);
    expect(scheme.onSurface.computeLuminance(), greaterThan(.6));
    expect(scheme.primary.computeLuminance(), greaterThan(.3));
  });

  test('presets have distinct accents and preserve light/dark mode', () {
    final accents = <Color>{};
    for (final preset in ColorPreset.values) {
      final light = BalanceThemes.build(Brightness.light, preset);
      final dark = BalanceThemes.build(Brightness.dark, preset);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.scaffoldBackgroundColor, isNot(Colors.black));
      accents.add(light.colorScheme.primary);
    }
    expect(accents.length, ColorPreset.values.length);
  });

  test(
    'preset and mode survive restart; OLED initially selects dark',
    () async {
      final storage = MemorySnapshotStorage();
      final store = AppStore(storage: storage, background: true);
      await store.initialize();
      expect(store.themePreset, 'forest');
      expect(store.theme, 'system');
      await store.setTheme('light');
      await store.setThemePreset('oled');
      expect(store.theme, 'dark');
      await store.setTheme('system');
      final reopened = AppStore(storage: storage, background: true);
      await reopened.initialize();
      expect(reopened.themePreset, 'oled');
      expect(reopened.theme, 'system');
      await reopened.setThemePreset('rose');
      expect(reopened.theme, 'system');
      await expectLater(
        reopened.setThemePreset('unknown'),
        throwsArgumentError,
      );
      await store.close();
      await reopened.close();
      store.dispose();
      reopened.dispose();
    },
  );

  testWidgets('system mode responds to OS brightness with OLED selected', (
    tester,
  ) async {
    final store = (await tester.runAsync(
      () => fixtures.createStore(seeded: false),
    ))!;
    await tester.runAsync(() async {
      await store.setThemePreset('oled');
      await store.setTheme('system');
    });
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await fixtures.boot(tester, store, const Size(390, 844));
    ThemeData theme() => Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme().scaffoldBackgroundColor, Colors.black);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(theme().brightness, Brightness.light);
    expect(theme().scaffoldBackgroundColor, isNot(Colors.black));
    await tester.runAsync(() => store.setTheme('dark'));
    await tester.pumpAndSettle();
    expect(theme().scaffoldBackgroundColor, Colors.black);
  });

  testWidgets(
    'OLED can be selected in narrow settings and updates mode control',
    (tester) async {
      await fixtures.loadReadableFont();
      final store = (await tester.runAsync(
        () => fixtures.createStore(seeded: false),
      ))!;
      await fixtures.boot(tester, store, const Size(320, 568));
      await fixtures.navigate(tester, 4);
      final oled = find.widgetWithText(ChoiceChip, 'OLED — чёрный');
      await tester.ensureVisible(oled);
      await tester.pumpAndSettle();
      await tester.tap(oled);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(store.themePreset, 'oled');
      expect(store.theme, 'dark');
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(
        Theme.of(
          tester.element(find.byType(Scaffold).first),
        ).scaffoldBackgroundColor,
        Colors.black,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
