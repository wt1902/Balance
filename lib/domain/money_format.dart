import 'package:intl/intl.dart';

/// Display formatting only; the currency never converts stored amounts.
String money(int minor, String currency, {String locale = 'ru_RU'}) =>
    NumberFormat.currency(
      locale: locale,
      name: currency,
      symbol:
          {'RUB': '₽', 'USD': r'$', 'EUR': '€', 'SEK': 'kr'}[currency] ??
          currency,
    ).format(minor / 100);
