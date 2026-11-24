import 'package:flutter/material.dart';

import '../domain/pdf_receipt.dart';
import 'design.dart';

class SavedReceiptPage extends StatelessWidget {
  const SavedReceiptPage({super.key, required this.positions});

  final List<ReceiptPosition> positions;

  @override
  Widget build(BuildContext context) {
    final total = PdfReceipt(positions: positions).positionsTotal;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Позиции чека')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final table = constraints.maxWidth >= 620;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    Text(
                      'Сумма позиций: ${money(total, 'RUB')}',
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    if (table)
                      Table(
                        columnWidths: const {
                          0: FlexColumnWidth(3),
                          1: FlexColumnWidth(),
                          2: FlexColumnWidth(),
                          3: FlexColumnWidth(),
                        },
                        border: TableBorder(
                          horizontalInside: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        defaultVerticalAlignment:
                            TableCellVerticalAlignment.middle,
                        children: [
                          TableRow(
                            children: [
                              _cell('Товар', style: text.labelLarge),
                              for (final label in [
                                'Количество',
                                'Цена за ед.',
                                'Сумма',
                              ])
                                _cell(
                                  label,
                                  style: text.labelLarge,
                                  numeric: true,
                                ),
                            ],
                          ),
                          for (final item in positions)
                            TableRow(
                              children: [
                                _cell(item.name),
                                _cell(item.quantity, numeric: true),
                                _cell(money(item.price, 'RUB'), numeric: true),
                                _cell(money(item.total, 'RUB'), numeric: true),
                              ],
                            ),
                        ],
                      )
                    else
                      for (final item in positions) ...[
                        Text(item.name, style: text.titleMedium),
                        const SizedBox(height: 4),
                        Text('Количество: ${item.quantity}'),
                        Text('Цена за ед.: ${money(item.price, 'RUB')}'),
                        Text('Сумма: ${money(item.total, 'RUB')}'),
                        const Divider(height: 24),
                      ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(String value, {TextStyle? style, bool numeric = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Text(
          value,
          style: style,
          textAlign: numeric ? TextAlign.end : TextAlign.start,
        ),
      );
}
