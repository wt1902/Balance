/// A purchase decoded from a Russian fiscal receipt QR code.
class Receipt {
  const Receipt._(this.amountMinor, this.date);

  final int amountMinor;
  final DateTime date;

  static final _amount = RegExp(r'^(\d{1,12})(?:\.(\d{1,2}))?$');
  static final _timestamp = RegExp(
    r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?$',
  );
  static final _digits = RegExp(r'^\d+$');

  static Receipt? parse(String value) {
    final fields = <String, String>{};
    for (final field in value.trim().split('&')) {
      final pair = field.split('=');
      if (pair.length != 2 || fields.containsKey(pair.first)) return null;
      fields[pair.first] = pair.last;
    }
    // n=1 is a purchase. Returns and other settlement types have their own codes.
    if (fields['n'] != '1' ||
        ![
          'fn',
          'i',
          'fp',
        ].every((key) => _digits.hasMatch(fields[key] ?? ''))) {
      return null;
    }
    final sum = _amount.firstMatch(fields['s'] ?? '');
    final time = _timestamp.firstMatch(fields['t'] ?? '');
    if (sum == null || time == null) return null;

    final minor =
        int.parse(sum[1]!) * 100 + int.parse((sum[2] ?? '').padRight(2, '0'));
    if (minor == 0) return null;

    final year = int.parse(time[1]!);
    final month = int.parse(time[2]!);
    final day = int.parse(time[3]!);
    final hour = int.parse(time[4]!);
    final minute = int.parse(time[5]!);
    final second = int.parse(time[6] ?? '0');
    final date = DateTime(year, month, day, hour, minute, second);
    if (year < 1900 ||
        year >= 2200 ||
        date.month != month ||
        date.day != day ||
        date.hour != hour ||
        date.minute != minute ||
        date.second != second) {
      return null;
    }
    return Receipt._(minor, date);
  }
}
