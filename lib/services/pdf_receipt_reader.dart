import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:pdfrx/pdfrx.dart'
    show PdfDocument, PdfPageRawText, PdfRect, pdfrxFlutterInitialize;

import '../domain/pdf_receipt.dart';

Future<PdfReceipt> readPdfReceipt(XFile file) async {
  if (await file.length() > 10 * 1024 * 1024) {
    throw const FormatException('Выберите PDF-чек размером до 10 МБ.');
  }
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openData(
    await file.readAsBytes(),
    passwordProvider: () async => null,
  );
  try {
    if (document.pages.length > 20) {
      throw const FormatException('Выберите PDF-чек длиной до 20 страниц.');
    }
    final pages = <List<String>>[];
    for (final page in document.pages) {
      final text = await page.loadText();
      if (text != null && text.fullText.trim().isNotEmpty) {
        if (text.fullText.length > 50000) {
          throw const FormatException('В PDF-чеке слишком много текста.');
        }
        pages.add(_visualLines(text));
      }
    }
    if (pages.isEmpty) {
      throw const FormatException(
        'В PDF нет текстового слоя. Выберите электронный чек.',
      );
    }
    return PdfReceipt.parse(pages);
  } finally {
    await document.dispose();
  }
}

typedef _Glyph = ({String char, PdfRect box, bool afterSpace});

/// Restore rows visually because a PDF can store an entire column at a time.
List<String> _visualLines(PdfPageRawText page) {
  if (page.fullText.length != page.charRects.length) {
    return page.fullText.split('\n');
  }
  final glyphs = <_Glyph>[];
  for (var i = 0; i < page.fullText.length; i++) {
    final char = page.fullText[i];
    final rect = page.charRects[i];
    if (char.trim().isNotEmpty && rect.isNotEmpty) {
      final previous = i == 0 ? '' : page.fullText[i - 1];
      glyphs.add((
        char: char,
        box: rect,
        afterSpace: const [' ', '\u00a0', '\u202f'].contains(previous),
      ));
    }
  }
  if (glyphs.isEmpty) return page.fullText.split('\n');
  final heights = glyphs.map((g) => g.box.height).toList()..sort();
  final height = heights[heights.length ~/ 2];
  final tolerance = math.max(1.5, height * .44);
  glyphs.sort((a, b) => b.box.center.y.compareTo(a.box.center.y));
  final rows = <List<_Glyph>>[];
  final centers = <double>[];
  for (final glyph in glyphs) {
    // Commas and periods sit low and must not start another visual row.
    if (glyph.box.height < height * .65) continue;
    final center = glyph.box.center.y;
    if (centers.isEmpty || centers.last - center > tolerance) {
      rows.add([glyph]);
      centers.add(center);
    } else {
      final count = rows.last.length;
      centers.last = (centers.last * count + center) / (count + 1);
      rows.last.add(glyph);
    }
  }
  var index = 0;
  for (final glyph in glyphs) {
    if (glyph.box.height >= height * .65) continue;
    final center = glyph.box.center.y;
    while (index + 1 < centers.length &&
        (centers[index + 1] - center).abs() < (centers[index] - center).abs()) {
      index++;
    }
    if ((centers[index] - center).abs() < height * 1.1) {
      rows[index].add(glyph);
    }
  }
  return [for (final row in rows) _formatRow(row, height)];
}

String _formatRow(List<_Glyph> row, double height) {
  row.sort((a, b) => a.box.left.compareTo(b.box.left));
  final buffer = StringBuffer();
  double? right;
  for (final (:char, box: rect, :afterSpace) in row) {
    if (right != null) {
      final gap = rect.left - right;
      if (gap > math.max(8, height * 1.3)) {
        buffer.write('\t');
      } else if (afterSpace || gap > height * .55) {
        buffer.write(' ');
      }
    }
    buffer.write(char);
    right = rect.right;
  }
  return buffer.toString();
}
