class ReceiptPosition {
  const ReceiptPosition(this.name, this.quantity, this.price, this.total);

  final String name;
  final String quantity;
  final int price;
  final int total;

  String get description =>
      '$quantity × ${PdfReceipt.formatAmount(price)} ₽ = '
      '${PdfReceipt.formatAmount(total)} ₽';
}

class PdfReceipt {
  PdfReceipt({required List<ReceiptPosition> positions, this.total, this.date})
    : positions = List.unmodifiable(positions);

  final List<ReceiptPosition> positions;
  final int? total;
  final DateTime? date;

  int get positionsTotal => positions.fold(0, (sum, item) => sum + item.total);

  static const _noteHeading = 'Позиции чека';
  static final _notePosition = RegExp(
    r'^(.+) — ([\d.,]+) × ([\d., ]+) ₽ = ([\d., ]+) ₽$',
  );

  String get note => [
    _noteHeading,
    for (final item in positions) '${item.name} — ${item.description}',
  ].join('\n');

  static List<ReceiptPosition> positionsFromNote(String note) {
    if (!note.contains(_noteHeading)) return const [];
    final positions = <ReceiptPosition>[];
    var inReceipt = false;
    for (final rawLine in note.split('\n')) {
      final line = rawLine.trim();
      if (line == _noteHeading) {
        inReceipt = true;
      } else if (line.isEmpty) {
        inReceipt = false;
      } else if (inReceipt) {
        final row = _notePosition.firstMatch(line);
        if (row == null) continue;
        final quantity = parseQuantity(row[2]!);
        final price = parseAmount(row[3]!);
        final total = parseAmount(row[4]!);
        if (quantity != null && price != null && total != null) {
          positions.add(ReceiptPosition(row[1]!, quantity, price, total));
        }
      }
    }
    return positions;
  }

  static String formatAmount(int minor) =>
      '${minor ~/ 100},${(minor % 100).toString().padLeft(2, '0')}';

  static int? parseAmount(String value) {
    final clean = value.replaceAll(RegExp(r'[ \u00a0\u202f₽]'), '');
    final match = RegExp(r'^(\d{1,12})(?:[.,](\d{1,2}))?$').firstMatch(clean);
    if (match == null) return null;
    return int.parse(match[1]!) * 100 +
        int.parse((match[2] ?? '').padRight(2, '0'));
  }

  static String? parseQuantity(String value) {
    final match =
        RegExp(
          r'^(\d{1,9}(?:[.,]\d{1,6})?)(?:\s*(?:кг|шт\.?|л))?$',
          caseSensitive: false,
        ).firstMatch(
          value.trim().replaceAll(RegExp(r'(?<=[\d.,])\s+(?=[\d.,])'), ''),
        );
    if (match == null || !RegExp(r'[1-9]').hasMatch(match[1]!)) return null;
    return match[1]!.replaceAll('.', ',');
  }

  static final _total = RegExp(
    r'^(?:итого?|к оплате|сумма расч[её]та)\s*[:=]?\s*'
    r'([0-9][0-9 .,\u00a0\u202f]*)\s*₽?$',
  );
  static final _totalCaption = RegExp(r'^(?:итого?|к оплате)\s*[:=]?\s*$');
  static final _payment = RegExp(
    r'^(?:электронн(?:ый|ая|ые) плат[её]ж|безналичными|безналичная оплата|'
    r'наличными|оплата картой)\s*[:=]?\s*'
    r'([0-9][0-9 .,\u00a0\u202f]*)\s*₽?$',
  );
  static final _footer = RegExp(
    r'^(?:электронн(?:ый|ая|ые) плат[её]ж|безналичн|наличными|итог|к оплате|'
    r'сумма расч|сумма ндс|кассир|фн\s*:|фд\s*:|адрес расч|смена)',
    caseSensitive: false,
    unicode: true,
  );
  static final _tax = RegExp(r'^(?:в\s*т\.?\s*ч\.?\s*)?ндс(?:\s|$)');
  static final _header = RegExp(r'товар|наименование|позици');
  static final _fallback = RegExp(
    r'^(.+?)\s+(\d+(?:[.,]\d+)?(?:\s*(?:кг|шт\.?|л))?)\s+'
    r'([\d \u00a0\u202f]+[.,]\d{2})\s*₽?\s+'
    r'([\d \u00a0\u202f]+[.,]\d{2})\s*₽?$',
  );
  static final _date = RegExp(
    r'\b(\d\s*\d)\s*[./-]\s*(\d\s*\d)\s*[./-]\s*'
    r'(\d(?:\s*\d){3}|\d\s*\d)\s+'
    r'(\d\s*\d)\s*:\s*(\d\s*\d)(?:\s*:\s*(\d\s*\d))?\b',
  );

  /// Lines are in visual order, with tabs between widely spaced columns.
  static PdfReceipt parse(List<List<String>> pages) {
    final positions = <ReceiptPosition>[];
    final payments = <int>[];
    DateTime? date;
    int? total;
    var totalHasSeparator = false;
    var recognized = false;
    for (final page in pages) {
      var previousWasTotalCaption = false;
      var canContinuePosition = false;
      var tableEnded = false;
      for (final raw in page) {
        final line = raw.trim();
        if (line.isEmpty || line.length > 1000) continue;
        final plain = line.replaceAll(RegExp(r'\s+'), ' ');
        final lower = plain.toLowerCase();
        if (lower.contains('возврат прихода')) {
          throw const FormatException('Этот PDF содержит чек возврата.');
        }
        if (lower.contains('кассовый чек')) recognized = true;
        date ??= _readDate(plain);
        final amount = _total.firstMatch(lower)?[1];
        if (amount != null || _totalCaption.hasMatch(lower)) recognized = true;
        final totalText = amount ?? (previousWasTotalCaption ? plain : null);
        if (total == null && totalText != null) {
          total = parseAmount(totalText);
          totalHasSeparator =
              totalText.contains('.') || totalText.contains(',');
        }
        previousWasTotalCaption = _totalCaption.hasMatch(lower);

        final paymentText = _payment.firstMatch(lower)?[1];
        if (paymentText != null) {
          final payment = parseAmount(paymentText);
          if (payment != null && payment > 0) payments.add(payment);
        }

        if (_header.hasMatch(lower) &&
            lower.contains('количеств') &&
            lower.contains('сумма')) {
          recognized = true;
          tableEnded = false;
          canContinuePosition = false;
          continue;
        }
        if (paymentText != null || _footer.hasMatch(lower)) {
          tableEnded = positions.isNotEmpty;
          canContinuePosition = false;
          continue;
        }
        if (tableEnded || _tax.hasMatch(lower)) continue;

        final item = _readPosition(line, plain);
        if (item != null) {
          positions.add(item);
          canContinuePosition = true;
        } else if (canContinuePosition &&
            !line.contains('\t') &&
            !RegExp(r'^[\d .,₽%]+$').hasMatch(line) &&
            line.length <= 160) {
          final last = positions.removeLast();
          positions.add(
            ReceiptPosition(
              '${last.name} $plain',
              last.quantity,
              last.price,
              last.total,
            ),
          );
        } else {
          canContinuePosition = false;
        }
      }
    }
    if (!recognized || positions.isEmpty) {
      throw const FormatException('Не удалось найти таблицу покупок в PDF.');
    }
    if (total != null && total > 0 && !totalHasSeparator) {
      // A PDF can draw the decimal separator outside the extracted text.
      // A single payment can corroborate the reading in kopecks. The item
      // sum alone can only flag an ambiguous total, since items may be missing.
      final digitsAsKopecks = total ~/ 100;
      final payment = payments.length == 1 ? payments.single : null;
      if (payment == digitsAsKopecks) {
        total = payment;
      } else if (payment != total &&
          positions.fold(0, (sum, item) => sum + item.total) ==
              digitsAsKopecks) {
        total = null;
      }
    }
    return PdfReceipt(
      positions: positions,
      total: total != null && total > 0 ? total : null,
      date: date,
    );
  }

  static ReceiptPosition? _readPosition(String line, String plain) {
    final cells = line.split(RegExp(r'\t+| {2,}'));
    final match = _fallback.firstMatch(plain);
    final fields = cells.length == 4
        ? cells
        : match == null
        ? null
        : [match[1]!, match[2]!, match[3]!, match[4]!];
    if (fields == null) return null;
    final name = fields[0].trim();
    final quantity = parseQuantity(fields[1]);
    final price = parseAmount(fields[2]);
    final total = parseAmount(fields[3]);
    if (name.isEmpty || quantity == null || price == null || total == null) {
      return null;
    }
    return ReceiptPosition(name, quantity, price, total);
  }

  static DateTime? _readDate(String line) {
    final match = _date.firstMatch(line);
    if (match == null) return null;
    String digits(int group) =>
        (match[group] ?? '0').replaceAll(RegExp(r'\s'), '');
    final day = int.parse(digits(1));
    final month = int.parse(digits(2));
    final yearDigits = digits(3);
    final year = int.parse(
      yearDigits.length == 2 ? '20$yearDigits' : yearDigits,
    );
    final hour = int.parse(digits(4));
    final minute = int.parse(digits(5));
    final second = int.parse(digits(6));
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
    return date;
  }
}
