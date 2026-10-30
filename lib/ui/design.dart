import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

String money(int minor, String currency) => NumberFormat.currency(
  locale: 'ru_RU',
  name: currency,
  symbol:
      {'RUB': '₽', 'USD': r'$', 'EUR': '€', 'SEK': 'kr'}[currency] ?? currency,
).format(minor / 100);
int? parseAmount(String value, {bool signed = false}) {
  final clean = value
      .replaceAll(RegExp(r'[\s\u00a0\u202f]'), '')
      .replaceAll(',', '.');
  if (!RegExp(
    signed ? r'^-?\d{1,12}(\.\d{1,2})?$' : r'^\d{1,12}(\.\d{1,2})?$',
  ).hasMatch(clean)) {
    return null;
  }
  final parts = clean.replaceFirst('-', '').split('.');
  final result =
      int.parse(parts[0]) * 100 +
      (parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0);
  return clean.startsWith('-') ? -result : result;
}

String amountInput(int minor) => (minor / 100).toStringAsFixed(2);

const categoryColors = <String, Color>{
  'red': Colors.red,
  'orange': Colors.orange,
  'yellow': Colors.amber,
  'green': Colors.green,
  'mint': Color(0xff39b997),
  'teal': Colors.teal,
  'cyan': Colors.cyan,
  'blue': Colors.blue,
  'indigo': Colors.indigo,
  'purple': Colors.purple,
  'pink': Colors.pink,
  'gray': Colors.blueGrey,
  'coral': Color(0xffee7063),
  'peach': Color(0xffe9a077),
  'gold': Color(0xffbf930c),
  'lime': Color(0xff91ad21),
  'forest': Color(0xff28734a),
  'turquoise': Color(0xff27a9a0),
  'sky': Color(0xff459bc8),
  'navy': Color(0xff364d94),
  'lavender': Color(0xff9b82ce),
  'magenta': Color(0xffbd439d),
  'brown': Colors.brown,
  'slate': Color(0xff627389),
};
const categoryIcons = <String, IconData>{
  'star.fill': Icons.star_rounded,
  'heart.fill': Icons.favorite_rounded,
  'sparkles': Icons.auto_awesome,
  'bolt.fill': Icons.bolt,
  'flame.fill': Icons.local_fire_department,
  'drop.fill': Icons.water_drop,
  'cart.fill': Icons.shopping_cart_outlined,
  'bag.fill': Icons.shopping_bag_outlined,
  'creditcard.fill': Icons.credit_card,
  'banknote.fill': Icons.payments_outlined,
  'gift.fill': Icons.card_giftcard,
  'tag.fill': Icons.sell_outlined,
  'cup.and.saucer.fill': Icons.coffee,
  'fork.knife': Icons.restaurant,
  'takeoutbag.and.cup.and.straw.fill': Icons.takeout_dining,
  'birthday.cake.fill': Icons.cake_outlined,
  'car.fill': Icons.directions_car_outlined,
  'bus.fill': Icons.directions_bus,
  'tram.fill': Icons.tram,
  'bicycle': Icons.pedal_bike,
  'airplane': Icons.flight,
  'fuelpump.fill': Icons.local_gas_station,
  'house.fill': Icons.home_outlined,
  'bed.double.fill': Icons.bed_outlined,
  'lightbulb.fill': Icons.lightbulb_outline,
  'wifi': Icons.wifi,
  'phone.fill': Icons.phone_outlined,
  'printer.fill': Icons.print_outlined,
  'pawprint.fill': Icons.pets,
  'leaf.fill': Icons.eco_outlined,
  'figure.walk': Icons.directions_walk,
  'figure.run': Icons.directions_run,
  'dumbbell.fill': Icons.fitness_center,
  'cross.case.fill': Icons.medical_services_outlined,
  'pills.fill': Icons.medication_outlined,
  'stethoscope': Icons.monitor_heart_outlined,
  'book.fill': Icons.menu_book,
  'graduationcap.fill': Icons.school_outlined,
  'laptopcomputer': Icons.laptop,
  'briefcase.fill': Icons.work_outline,
  'gamecontroller.fill': Icons.sports_esports_outlined,
  'music.note': Icons.music_note,
  'film.fill': Icons.movie_outlined,
  'camera.fill': Icons.photo_camera_outlined,
  'paintpalette.fill': Icons.palette_outlined,
  'tshirt.fill': Icons.checkroom,
  'hammer.fill': Icons.gavel,
  'wrench.and.screwdriver.fill': Icons.handyman_outlined,
  'shippingbox.fill': Icons.inventory_2_outlined,
  'globe.europe.africa.fill': Icons.public,
  'repeat': Icons.repeat,
  'chart.line.uptrend.xyaxis': Icons.trending_up,
  'ellipsis.circle.fill': Icons.more_horiz,
  'plus.circle.fill': Icons.add_circle_outline,
  'slider.horizontal.3': Icons.tune,
  'tune': Icons.tune,
};

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key,
    required this.icon,
    this.emoji = '',
    this.color = 'indigo',
    this.size = 44,
  });
  final String icon, emoji, color;
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = categoryColors[color] ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: emoji.isNotEmpty
          ? Text(emoji, style: TextStyle(fontSize: size * .48))
          : Icon(
              categoryIcons[icon] ?? Icons.category_outlined,
              color: c,
              size: size * .52,
            ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(padding: padding, child: child),
  );
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
    this.icon = Icons.receipt_long_outlined,
  });
  final String title, subtitle;
  final Widget? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Panel(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    ),
  );
}

class Metric extends StatelessWidget {
  const Metric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });
  final String label, value;
  final IconData icon;
  final Color? color;
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              color: color ?? Theme.of(context).colorScheme.primary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class SpendingRing extends StatelessWidget {
  const SpendingRing({super.key, required this.segments, required this.total});
  final List<(int, Color)> segments;
  final String total;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Всего расходов: $total. Структура по категориям приведена ниже.',
    child: SizedBox(
      height: 200,
      child: Center(
        child: SizedBox.square(
          dimension: 190,
          child: CustomPaint(
            painter: _RingPainter(segments),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Расходы',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      child: Text(
                        total,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.segments);
  final List<(int, Color)> segments;
  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold<int>(0, (sum, s) => sum + s.$1);
    if (total <= 0) return;
    final rect = Offset.zero & size;
    var angle = -1.5707963267948966;
    for (final segment in segments) {
      final sweep = segment.$1 / total * 6.283185307179586;
      canvas.drawArc(
        rect.deflate(13),
        angle,
        sweep,
        false,
        Paint()
          ..color = segment.$2
          ..style = PaintingStyle.stroke
          ..strokeWidth = 20,
      );
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.segments != segments;
}
