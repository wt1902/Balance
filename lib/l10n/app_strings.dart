import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'english.dart';

// The app has one active locale. MaterialApp resolves it before building its
// routes, including when the platform language changes.
String appLocale = 'en';

const appLocales = [Locale('en'), Locale('ru')];

Locale resolveAppLocale(Locale? locale, Iterable<Locale> supported) =>
    locale?.languageCode == 'ru' ? const Locale('ru') : const Locale('en');

final _placeholder = RegExp(r'\{(\d+)\}');

String uiText(String message, [List<Object?> values = const []]) =>
    uiTextFor(appLocale, message, values);

String uiTextFor(
  String locale,
  String message, [
  List<Object?> values = const [],
]) {
  final text = locale == 'en' ? english[message] ?? message : message;
  if (values.isEmpty) return text;
  return text.replaceAllMapped(_placeholder, (match) {
    final index = int.parse(match[1]!);
    return index < values.length ? '${values[index]}' : match[0]!;
  });
}

const _builtInCategoryNames = <String, String>{
  'Продукты': 'Groceries',
  'Транспорт': 'Transport',
  'Дом': 'Home',
  'Развлечения': 'Entertainment',
  'Здоровье': 'Health',
  'Покупки': 'Shopping',
  'Подписки': 'Subscriptions',
  'Образование': 'Education',
  'Зарплата': 'Salary',
  'Подработка': 'Side income',
  'Инвестиции': 'Investments',
  'Подарок': 'Gift',
  'Другое': 'Other',
  'Корректировка': 'Adjustment',
};

// Category names are keys in budgets and synchronization. Translate their
// labels at the UI boundary, without changing the stored values.
String categoryTitle(String name) =>
    appLocale == 'en' ? _builtInCategoryNames[name] ?? name : name;

String localDecimal(String value) =>
    appLocale == 'en' ? value.replaceAll(',', '.') : value;

String uiError(Object error) {
  if (error is ArgumentError && error.message is String) {
    return uiText(error.message as String);
  }
  if (error is FormatException) return uiText(error.message);
  if (error is StateError) return uiText(error.message);
  return uiText(error.toString());
}

final _syncSkipped = RegExp(
  r'^Синхронизировано\. Пропущено записей с ошибками: (\d+) — см\. Настройки → Данные$',
);

String uiSyncStatus(String message) {
  const failed = 'Не удалось синхронизировать: ';
  if (message.startsWith(failed)) {
    return uiText('Не удалось синхронизировать: {0}', [
      message.substring(failed.length),
    ]);
  }
  final skipped = _syncSkipped.firstMatch(message);
  if (skipped != null) {
    return uiText(
      'Синхронизировано. Пропущено записей с ошибками: {0} — см. Настройки → Данные',
      [skipped[1]],
    );
  }
  return uiText(message);
}

DateFormat localDateFormat(String pattern) => DateFormat(
  appLocale == 'en'
      ? switch (pattern) {
          'd MMM y' => 'MMM d, y',
          'd MMMM y' => 'MMMM d, y',
          'd MMMM y, HH:mm' => 'MMMM d, y, HH:mm',
          'd MMMM y, EEE' => 'EEE, MMMM d, y',
          'd MMM, HH:mm' => 'MMM d, HH:mm',
          'd MMM' => 'MMM d',
          'dd.MM.yyyy' => 'MM/dd/yyyy',
          'd.MM' => 'M/d',
          'd.MM.y HH:mm' => 'M/d/y HH:mm',
          _ => pattern,
        }
      : pattern,
  appLocale,
);
