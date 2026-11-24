import 'dart:io';

import 'package:balance_flutter/domain/pdf_receipt.dart';
import 'package:cross_file/cross_file.dart';
import 'package:balance_flutter/services/pdf_receipt_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads a PDF whose drawing order groups the table by column', () async {
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    final receipt = await readPdfReceipt(
      XFile('test/fixtures/receipt_table.pdf'),
    );

    expect(receipt.total, 100734);
    expect(receipt.positionsTotal, 100734);
    expect(receipt.date, DateTime(2026, 11, 22, 22, 38));
    expect(receipt.positions.map((item) => item.name), [
      'Помидоры тепличные, вес',
      'Молочный коктейль шоколадный упаковка 1 л',
      'Кофе в зёрнах',
    ]);
    expect(receipt.positions.first.quantity, '0,68');
    expect(receipt.positions.first.price, 26998);
    expect(receipt.positions.first.total, 18359);
  });

  test('keeps printed total, including a one-kopeck discrepancy', () {
    final receipt = PdfReceipt.parse([
      ['Кассовый чек', 'Помидоры  0,68  269,98  183,59', 'Итого 183,60'],
    ]);
    expect(receipt.total, 18360);
    expect(receipt.positionsTotal, 18359);
  });

  test('recovers a missing decimal separator from the payment line', () {
    final receipt = PdfReceipt.parse([
      [
        'Кассовый чек',
        'Итого\t1 70735 ₽',
        'Покупка\t1\t1 707,34\t1 707,34',
        'Электронный платеж\t1 707,35',
      ],
    ]);
    expect(receipt.total, 170735);
    expect(receipt.positionsTotal, 170734);
  });

  test('requires review when only the item sum suggests a lost separator', () {
    final receipt = PdfReceipt.parse([
      ['Кассовый чек', 'Итого 170735', 'Покупка\t1\t1 707,35\t1 707,35'],
    ]);
    expect(receipt.total, isNull);
    expect(receipt.positionsTotal, 170735);
  });

  test('keeps a whole-ruble total confirmed by its payment line', () {
    final receipt = PdfReceipt.parse([
      [
        'Кассовый чек',
        'Итого 170735',
        'Покупка\t1\t1 707,35\t1 707,35',
        'Оплата картой: 170 735,00 ₽',
      ],
    ]);
    expect(receipt.total, 17073500);
  });

  test('rejects a refund or a PDF without a purchase table', () {
    for (final lines in [
      ['Кассовый чек', 'Возврат прихода', 'Кофе   1   49,95   49,95'],
      ['Кассовый чек', 'Итого 49,95'],
    ]) {
      expect(() => PdfReceipt.parse([lines]), throwsFormatException);
    }
  });
}
