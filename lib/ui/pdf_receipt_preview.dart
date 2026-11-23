import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/pdf_receipt.dart';
import 'design.dart';

class PdfReceiptPreview extends StatefulWidget {
  const PdfReceiptPreview({super.key, required this.receipt});

  final PdfReceipt receipt;

  @override
  State<PdfReceiptPreview> createState() => _PdfReceiptPreviewState();
}

class _PdfReceiptPreviewState extends State<PdfReceiptPreview> {
  late final _positions = widget.receipt.positions.toList();
  late int? _total = widget.receipt.total;
  late final _totalInput = TextEditingController(
    text: _total == null ? '' : PdfReceipt.formatAmount(_total!),
  );

  @override
  void dispose() {
    _totalInput.dispose();
    super.dispose();
  }

  Future<void> _editPosition([int? index]) async {
    final position = await showDialog<ReceiptPosition>(
      context: context,
      builder: (_) =>
          _PositionEditor(position: index == null ? null : _positions[index]),
    );
    if (!mounted || position == null) return;
    setState(() {
      if (index == null) {
        _positions.add(position);
      } else {
        _positions[index] = position;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final receipt = PdfReceipt(
      positions: _positions,
      total: _total,
      date: widget.receipt.date,
    );
    final difference =
        (_total ?? receipt.positionsTotal) - receipt.positionsTotal;
    return Scaffold(
      appBar: AppBar(title: const Text('Позиции чека')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (receipt.date case final date?)
                  Text(DateFormat('d MMMM y, HH:mm', 'ru').format(date))
                else
                  const Text(
                    'Дата не распознана. Проверьте её в форме операции.',
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _totalInput,
                  decoration: InputDecoration(
                    labelText: 'Итог чека, ₽',
                    border: const OutlineInputBorder(),
                    helperText: (_total ?? 0) > 0
                        ? null
                        : 'Введите итоговую сумму с чека',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (value) =>
                      setState(() => _total = PdfReceipt.parseAmount(value)),
                ),
                const SizedBox(height: 12),
                Text('Сумма позиций: ${money(receipt.positionsTotal, 'RUB')}'),
                if (difference != 0)
                  Text(
                    'Расхождение: ${money(difference.abs(), 'RUB')}. '
                    'Проверьте позиции и итог по PDF.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Divider(),
                for (var i = 0; i < _positions.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_positions[i].name),
                    subtitle: Text(_positions[i].description),
                    onTap: () => _editPosition(i),
                    trailing: IconButton(
                      tooltip: 'Убрать позицию',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _positions.removeAt(i)),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _editPosition,
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить позицию'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _positions.isEmpty || (_total ?? 0) <= 0
                      ? null
                      : () => Navigator.pop(context, receipt),
                  child: const Text('Использовать чек'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PositionEditor extends StatefulWidget {
  const _PositionEditor({required this.position});

  final ReceiptPosition? position;

  @override
  State<_PositionEditor> createState() => _PositionEditorState();
}

class _PositionEditorState extends State<_PositionEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.position?.name);
  late final _quantity = TextEditingController(text: widget.position?.quantity);
  late final _price = TextEditingController(
    text: widget.position == null
        ? ''
        : PdfReceipt.formatAmount(widget.position!.price),
  );
  late final _total = TextEditingController(
    text: widget.position == null
        ? ''
        : PdfReceipt.formatAmount(widget.position!.total),
  );

  @override
  void dispose() {
    for (final controller in [_name, _quantity, _price, _total]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Позиция чека'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Товар'),
            validator: (value) =>
                value!.trim().isEmpty ? 'Введите название' : null,
          ),
          TextFormField(
            controller: _quantity,
            decoration: const InputDecoration(labelText: 'Количество'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (value) => PdfReceipt.parseQuantity(value!) == null
                ? 'Введите количество'
                : null,
          ),
          for (final (controller, label) in [
            (_price, 'Цена, ₽'),
            (_total, 'Сумма, ₽'),
          ])
            TextFormField(
              controller: controller,
              decoration: InputDecoration(labelText: label),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (value) => PdfReceipt.parseAmount(value!) == null
                  ? 'Введите сумму'
                  : null,
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            ReceiptPosition(
              _name.text.trim(),
              PdfReceipt.parseQuantity(_quantity.text)!,
              PdfReceipt.parseAmount(_price.text)!,
              PdfReceipt.parseAmount(_total.text)!,
            ),
          );
        },
        child: const Text('Готово'),
      ),
    ],
  );
}
