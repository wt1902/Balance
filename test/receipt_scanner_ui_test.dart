import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'widget_test.dart'
    show
        boot,
        createStore,
        field,
        loadReadableFont,
        mockStorage,
        reveal,
        saveDialog;

class _FakeCamera extends MobileScannerPlatform {
  final codes = StreamController<BarcodeCapture>.broadcast();

  void scan(String code) => codes.add(
    BarcodeCapture(
      barcodes: [Barcode(rawValue: code, format: BarcodeFormat.qrCode)],
    ),
  );

  @override
  Stream<BarcodeCapture?> get barcodesStream => codes.stream;

  @override
  Stream<TorchState> get torchStateStream =>
      Stream.value(TorchState.unavailable);

  @override
  Stream<double> get zoomScaleStateStream => Stream.value(1);

  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable,
        size: Size(320, 568),
        numberOfCameras: 1,
      );

  @override
  Widget buildCameraView() => const SizedBox.expand();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  setUpAll(loadReadableFont);
  setUp(mockStorage);

  testWidgets('receipt fills an editable expense before an explicit save', (
    tester,
  ) async {
    final previousPlatform = MobileScannerPlatform.instance;
    final camera = _FakeCamera();
    MobileScannerPlatform.instance = camera;
    addTearDown(() async {
      await camera.codes.close();
      MobileScannerPlatform.instance = previousPlatform;
    });
    final store = (await tester.runAsync(() => createStore(seeded: false)))!;
    await boot(tester, store, const Size(320, 568));

    Future<void> openScanner() async {
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      final button = find.text('Сканировать чек');
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    const code = 't=20260115T1345&s=125.30&fn=123&i=42&fp=555&n=1';
    await openScanner();
    camera.scan('https://example.com');
    await tester.pumpAndSettle();
    expect(
      find.text('Поднесите QR-код кассового чека покупки.'),
      findsOneWidget,
    );
    expect(store.transactions, isEmpty);
    camera.scan(code);
    camera.scan(code);
    await tester.pumpAndSettle();
    expect(find.text('Предпросмотр операции'), findsOneWidget);
    expect(
      tester.widget<TextFormField>(field('Сумма')).controller!.text,
      '125.30',
    );
    expect(store.transactions, isEmpty);

    final cancel = find.text('Отмена');
    await reveal(tester, cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(store.transactions, isEmpty);

    await openScanner();
    camera.scan(code);
    await tester.pumpAndSettle();
    await reveal(tester, field('Сумма'));
    await tester.enterText(field('Сумма'), '120,50');
    await saveDialog(tester);
    final saved = store.transactions.single;
    expect(saved.amountMinor, 12050);
    expect(saved.date.toLocal(), DateTime(2026, 1, 15, 13, 45));
    expect(saved.kindRawValue, 'expense');
    expect(saved.currency, 'RUB');
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
