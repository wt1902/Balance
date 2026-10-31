/// Occurrences of recurring operations (contract v2 §4). Dates are counted in
/// the UTC calendar from `startDate`, and a generated transaction gets a
/// deterministic id, so two devices create the same record, never a copy.
library;

import 'package:uuid/uuid.dart';

import 'finance.dart';
import 'records.dart';

/// One occurrence of [rule] on the UTC day [occurrence] (`YYYY-MM-DD`).
class RecurringOccurrence {
  const RecurringOccurrence(this.rule, this.occurrence, this.date);
  final RecurringRecord rule;
  final String occurrence;

  /// The occurrence day with the time of day of `startDate`, in UTC.
  final DateTime date;

  String get transactionId =>
      RecurringEngine.transactionId(rule.id, occurrence);

  TransactionRecord toTransaction(DateTime updatedAt) => TransactionRecord(
    id: transactionId,
    amountMinor: rule.amountMinor,
    date: date,
    categoryName: rule.categoryName,
    categoryIcon: rule.categoryIcon,
    categoryEmoji: rule.categoryEmoji,
    categoryColorName: rule.categoryColorName,
    note: rule.note,
    kindRawValue: rule.kindRawValue,
    accountId: rule.accountId,
    currency: rule.currency,
    tags: rule.tags,
    recurringId: rule.id,
    occurrence: occurrence,
    updatedAt: updatedAt,
  );
}

class RecurringEngine {
  static const namespace = '6f1c3f5e-8a8d-4c3a-9d2b-4b1f0e7a2c11';

  /// At most this many occurrences are processed in one run.
  static const maxPerRun = 366;

  /// UUID v5 of `recurring:<recurringId>:<occurrence>` in lower case.
  static String transactionId(String recurringId, String occurrence) =>
      const Uuid().v5(
        namespace,
        'recurring:$recurringId:$occurrence'.toLowerCase(),
      );

  static int _daysIn(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  /// The [index]-th occurrence (0 is `startDate`) or null when the rule has
  /// an unknown frequency or an interval below 1.
  static DateTime? occurrenceAt(RecurringRecord rule, int index) {
    final frequency = rule.frequency;
    if (frequency == null || rule.interval < 1 || index < 0) return null;
    final s = rule.startDate.toUtc();
    DateTime at(int year, int month, int day) => DateTime.utc(
      year,
      month,
      day,
      s.hour,
      s.minute,
      s.second,
      s.millisecond,
      s.microsecond,
    );
    final step = index * rule.interval;
    switch (frequency) {
      case RecurrenceFrequency.daily:
        return at(s.year, s.month, s.day + step);
      case RecurrenceFrequency.weekly:
        return at(s.year, s.month, s.day + 7 * step);
      case RecurrenceFrequency.monthly:
        final total = s.month - 1 + step;
        final year = s.year + total ~/ 12, month = total % 12 + 1;
        final days = _daysIn(year, month);
        return at(year, month, s.day > days ? days : s.day);
      case RecurrenceFrequency.yearly:
        final year = s.year + step;
        final days = _daysIn(year, s.month);
        return at(year, s.month, s.day > days ? days : s.day);
    }
  }

  static DateTime _day(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  /// An index at or before the first occurrence after [after], so a rule
  /// that started long ago is not walked from its start.
  static int _firstIndex(RecurringRecord rule, DateTime? after) {
    if (after == null) return 0;
    final s = _day(rule.startDate);
    final interval = rule.interval;
    final index = switch (rule.frequency!) {
      RecurrenceFrequency.daily => after.difference(s).inDays ~/ interval,
      RecurrenceFrequency.weekly =>
        after.difference(s).inDays ~/ (7 * interval),
      RecurrenceFrequency.monthly =>
        ((after.year - s.year) * 12 + after.month - s.month) ~/ interval - 1,
      RecurrenceFrequency.yearly => (after.year - s.year) ~/ interval - 1,
    };
    return index < 0 ? 0 : index;
  }

  /// Occurrences in `(generatedThrough, today UTC]` (from `startDate` when
  /// `generatedThrough` is empty), none after `endDate`'s UTC day, oldest
  /// first, at most [limit]. A paused rule has none.
  static List<RecurringOccurrence> due(
    RecurringRecord rule,
    DateTime now, {
    int limit = maxPerRun,
  }) {
    if (rule.isPaused || rule.frequency == null || rule.interval < 1) {
      return const [];
    }
    final today = _day(now);
    final end = rule.endDate == null ? null : _day(rule.endDate!);
    final through = rule.generatedThrough == null
        ? null
        : parseIsoDay(rule.generatedThrough!);
    final result = <RecurringOccurrence>[];
    for (
      var index = _firstIndex(rule, through);
      result.length < limit;
      index++
    ) {
      final date = occurrenceAt(rule, index)!;
      final day = _day(date);
      if (day.isAfter(today) || (end != null && day.isAfter(end))) break;
      if (through != null && !day.isAfter(through)) continue;
      result.add(RecurringOccurrence(rule, isoDay(day), date));
    }
    return result;
  }

  /// The first occurrence on a UTC day after both [now]'s day and
  /// `generatedThrough`, for «Следующая …»; null when the rule is paused,
  /// invalid or ended.
  static DateTime? nextOccurrence(RecurringRecord rule, DateTime now) {
    if (rule.isPaused || rule.frequency == null || rule.interval < 1) {
      return null;
    }
    var after = _day(now);
    final through = rule.generatedThrough;
    if (through != null) {
      final day = parseIsoDay(through);
      if (day.isAfter(after)) after = day;
    }
    final end = rule.endDate == null ? null : _day(rule.endDate!);
    for (var index = _firstIndex(rule, after); ; index++) {
      final date = occurrenceAt(rule, index)!;
      final day = _day(date);
      if (end != null && day.isAfter(end)) return null;
      if (day.isAfter(after)) return date;
    }
  }
}
