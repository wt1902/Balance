import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/receipt.dart';

class ReceiptScanner extends StatefulWidget {
  const ReceiptScanner({super.key});

  @override
  State<ReceiptScanner> createState() => _ReceiptScannerState();
}

class _ReceiptScannerState extends State<ReceiptScanner> {
  bool _finished = false;
  bool _invalidCode = false;

  void _onDetect(BarcodeCapture capture) {
    if (!mounted || _finished || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (barcode.format != BarcodeFormat.qrCode || value == null) continue;
      final receipt = Receipt.parse(value);
      if (receipt != null) {
        _finished = true;
        Navigator.pop(context, receipt);
        return;
      }
      if (!_invalidCode) setState(() => _invalidCode = true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(uiText('Сканировать чек'))),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: _onDetect,
              tapToFocus: true,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? uiText(
                            'Разрешите доступ к камере в настройках устройства.',
                          )
                        : uiText('Не удалось открыть камеру.'),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _invalidCode
                    ? uiText('Поднесите QR-код кассового чека покупки.')
                    : uiText('Наведите камеру на QR-код кассового чека.'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
