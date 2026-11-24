import 'package:balance_flutter/domain/receipt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fiscal = '&fn=8710000100008458&i=25202&fp=2974929930&n=1';

  test('reads receipt totals as integer kopecks and parses local time', () {
    final receipt = Receipt.parse('t=20240229T1245&s=1800.05$fiscal')!;
    expect(receipt.amountMinor, 180005);
    expect(receipt.date, DateTime(2024, 2, 29, 12, 45));
    final withSeconds = Receipt.parse('s=12.5&t=20240301T124530$fiscal')!;
    expect(withSeconds.amountMinor, 1250);
    expect(withSeconds.date.second, 30);
  });

  test('rejects unrelated codes, returns and invalid dates and amounts', () {
    final purchase = 't=20240229T1245&s=1800.05$fiscal';
    for (final input in [
      'https://example.com',
      't=20240229T1245&s=1800.05&n=1',
      purchase.replaceFirst('n=1', 'n=2'),
      purchase.replaceFirst('20240229', '20230229'),
      purchase.replaceFirst('1245', '1260'),
      purchase.replaceFirst('1800.05', '0.00'),
      purchase.replaceFirst('1800.05', '-12.00'),
      purchase.replaceFirst('1800.05', '1800.005'),
      '$purchase&s=1.00',
    ]) {
      expect(Receipt.parse(input), isNull, reason: input);
    }
  });
}
