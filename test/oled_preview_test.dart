import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' as fixtures;

void main() {
  setUpAll(fixtures.loadReadableFont);
  setUp(fixtures.mockStorage);
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('OLED renders black pixels at $size', (tester) async {
      final store = (await tester.runAsync(() => fixtures.createStore()))!;
      await tester.runAsync(() => store.setThemePreset('oled'));
      final key = GlobalKey();
      await fixtures.boot(tester, store, size, boundaryKey: key);
      for (final page in [0, 4]) {
        await fixtures.navigate(tester, page);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final rgba = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          // Left edge of the scaffold/rail below the app bar, away from text.
          final pixel = (110 * image.width) * 4;
          expect(rgba!.getUint8(pixel), 0);
          expect(rgba.getUint8(pixel + 1), 0);
          expect(rgba.getUint8(pixel + 2), 0);
          expect(rgba.getUint8(pixel + 3), 255);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('/tmp/balance-oled-preview')
            ..createSync(recursive: true);
          File(
            '${dir.path}/${size.width.toInt()}-${page == 0 ? 'overview' : 'settings'}.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
    });
  }
}
