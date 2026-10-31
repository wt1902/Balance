import 'finance.dart';

/// Calendar days between two local dates, immune to DST shifts.
int calendarDays(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Start of the local day after [now]: today counts as elapsed.
DateTime _tomorrow(DateTime now) {
  final local = now.toLocal();
  return DateTime(local.year, local.month, local.day + 1);
}

DateTime _min(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
DateTime _max(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

/// `в январе` … `в декабре`, for «чем в сентябре».
const monthsPrepositional = [
  'январе',
  'феврале',
  'марте',
  'апреле',
  'мае',
  'июне',
  'июле',
  'августе',
  'сентябре',
  'октябре',
  'ноябре',
  'декабре',
];

/// 1 день, 2 дня, 5 дней.
String pluralDays(int n) {
  final mod10 = n % 10, mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return '$n день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$n дня';
  }
  return '$n дней';
}

enum PeriodKind { months, year, custom }

/// An analytics period: a local half-open interval `[start, endExclusive)`.
class AnalyticsPeriod {
  const AnalyticsPeriod._(
    this.kind,
    this.start,
    this.endExclusive,
    this.months,
  );

  /// The current month, 3 or 12 months ending with [now]'s month.
  factory AnalyticsPeriod.months(int months, DateTime now) {
    if (months < 1) throw ArgumentError.value(months, 'months');
    final local = now.toLocal();
    return AnalyticsPeriod._(
      PeriodKind.months,
      DateTime(local.year, local.month - months + 1),
      DateTime(local.year, local.month + 1),
      months,
    );
  }

  /// A calendar year.
  factory AnalyticsPeriod.year(int year) => AnalyticsPeriod._(
    PeriodKind.year,
    DateTime(year),
    DateTime(year + 1),
    12,
  );

  /// Whole local days from [start] up to [endExclusive].
  factory AnalyticsPeriod.custom(DateTime start, DateTime endExclusive) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(endExclusive.year, endExclusive.month, endExclusive.day);
    if (!s.isBefore(e)) throw ArgumentError('Пустой период');
    return AnalyticsPeriod._(PeriodKind.custom, s, e, 0);
  }

  final PeriodKind kind;
  final DateTime start, endExclusive;

  /// Length in months for [PeriodKind.months] and [PeriodKind.year].
  final int months;

  int get days => calendarDays(start, endExclusive);

  /// The period of the same kind and length right before this one.
  AnalyticsPeriod get previous => switch (kind) {
    PeriodKind.months => AnalyticsPeriod._(
      kind,
      DateTime(start.year, start.month - months),
      start,
      months,
    ),
    PeriodKind.year => AnalyticsPeriod.year(start.year - 1),
    PeriodKind.custom => AnalyticsPeriod._(
      kind,
      DateTime(start.year, start.month, start.day - days),
      start,
      0,
    ),
  };

  /// End of the part of the period that has already happened by [now].
  DateTime elapsedEnd(DateTime now) =>
      _min(endExclusive, _max(start, _tomorrow(now)));

  /// Days already elapsed, today included; 0 for a future period.
  int elapsedDays(DateTime now) => calendarDays(start, elapsedEnd(now));

  /// The period has started but not finished yet.
  bool isOngoing(DateTime now) {
    final end = elapsedEnd(now);
    return end.isAfter(start) && end.isBefore(endExclusive);
  }

  /// «в сентябре», «за предыдущие 3 месяца», «в 2025 году»…
  String get previousTitle {
    final p = previous;
    return switch (kind) {
      PeriodKind.months when months == 1 =>
        'в ${monthsPrepositional[p.start.month - 1]}',
      PeriodKind.months =>
        'за предыдущие ${months == 12 ? '12 месяцев' : '$months месяца'}',
      PeriodKind.year => 'в ${p.start.year} году',
      PeriodKind.custom => 'за предыдущие ${pluralDays(days)}',
    };
  }

  @override
  bool operator ==(Object other) =>
      other is AnalyticsPeriod &&
      other.kind == kind &&
      other.start == start &&
      other.endExclusive == endExclusive;

  @override
  int get hashCode => Object.hash(kind, start, endExclusive);
}

/// Income and expenses of a period against the previous one. While the period
/// is ongoing both sides cover the same number of elapsed days, so the
/// unfinished month is not compared with a whole one.
class PeriodComparison {
  const PeriodComparison({
    required this.currentStart,
    required this.currentEnd,
    required this.previousStart,
    required this.previousEnd,
    required this.current,
    required this.previous,
    required this.partial,
    required this.previousTitle,
  });

  final DateTime currentStart, currentEnd, previousStart, previousEnd;
  final FinanceSummary current, previous;

  /// Only the elapsed part of the periods is compared.
  final bool partial;
  final String previousTitle;

  factory PeriodComparison.of(
    Iterable<TransactionRecord> items,
    AnalyticsPeriod period,
    DateTime now,
  ) {
    final prev = period.previous;
    final partial = period.isOngoing(now);
    final currentEnd = partial ? period.elapsedEnd(now) : period.endExclusive;
    final previousEnd = partial
        ? _min(
            DateTime(
              prev.start.year,
              prev.start.month,
              prev.start.day + period.elapsedDays(now),
            ),
            prev.endExclusive,
          )
        : prev.endExclusive;
    final snapshot = items.toList();
    return PeriodComparison(
      currentStart: period.start,
      currentEnd: currentEnd,
      previousStart: prev.start,
      previousEnd: previousEnd,
      current: FinanceMath.summary(snapshot, period.start, currentEnd),
      previous: FinanceMath.summary(snapshot, prev.start, previousEnd),
      partial: partial,
      previousTitle: period.previousTitle,
    );
  }

  /// Change in whole percent; null when there is nothing to compare with.
  static int? changePercent(int current, int previous) =>
      previous == 0 ? null : ((current - previous) * 100 / previous).round();

  int? get expensesChange =>
      changePercent(current.expensesMinor, previous.expensesMinor);
  int? get incomeChange =>
      changePercent(current.incomeMinor, previous.incomeMinor);

  String get expensesText => _text(
    'Расходы',
    'расходов',
    current.expensesMinor,
    previous.expensesMinor,
  );
  String get incomeText =>
      _text('Доходы', 'доходов', current.incomeMinor, previous.incomeMinor);

  String _text(String noun, String genitive, int current, int previous) {
    final change = changePercent(current, previous);
    if (change == null) {
      return 'Нет $genitive $previousTitle для сравнения';
    }
    if (change == 0) return '$noun такие же, как $previousTitle';
    return '$noun на ${change.abs()}% ${change > 0 ? 'выше' : 'ниже'}, '
        'чем $previousTitle';
  }
}

enum BucketSize { day, week, month }

/// One bar of a trend chart, clipped to the period.
class TrendBucket {
  const TrendBucket(this.start, this.endExclusive, this.size);
  final DateTime start, endExclusive;
  final BucketSize size;

  /// Days up to 45, weeks (from Monday) up to 130 days, months beyond.
  static List<TrendBucket> of(DateTime start, DateTime endExclusive) {
    final days = calendarDays(start, endExclusive);
    final size = days <= 45
        ? BucketSize.day
        : days <= 130
        ? BucketSize.week
        : BucketSize.month;
    var d = switch (size) {
      BucketSize.day => start,
      BucketSize.week => DateTime(
        start.year,
        start.month,
        start.day - start.weekday + 1,
      ),
      BucketSize.month => DateTime(start.year, start.month),
    };
    final result = <TrendBucket>[];
    while (d.isBefore(endExclusive)) {
      final next = switch (size) {
        BucketSize.day => DateTime(d.year, d.month, d.day + 1),
        BucketSize.week => DateTime(d.year, d.month, d.day + 7),
        BucketSize.month => DateTime(d.year, d.month + 1),
      };
      result.add(TrendBucket(_max(d, start), _min(next, endExclusive), size));
      d = next;
    }
    return result;
  }
}

class MonthlyAmount {
  const MonthlyAmount(this.month, this.amountMinor);
  final DateTime month;
  final int amountMinor;
}

/// Spending pace of [now]'s local month. Expenses dated later this month are
/// already planned, so they are added to the projection as they are.
class MonthForecast {
  const MonthForecast({
    required this.month,
    required this.daysInMonth,
    required this.elapsedDays,
    required this.spentMinor,
    required this.scheduledMinor,
  });

  final DateTime month;
  final int daysInMonth, elapsedDays;

  /// Expenses up to the end of today, adjustments excluded.
  final int spentMinor;

  /// Expenses dated after today within the month.
  final int scheduledMinor;

  int get dailyPaceMinor => _divRound(spentMinor, elapsedDays);
  int get projectedMinor =>
      _divRound(spentMinor * daysInMonth, elapsedDays) + scheduledMinor;

  factory MonthForecast.of(Iterable<TransactionRecord> items, DateTime now) {
    final local = now.toLocal();
    final month = DateTime(local.year, local.month);
    final next = DateTime(local.year, local.month + 1);
    final tomorrow = _tomorrow(now);
    final snapshot = items.toList();
    return MonthForecast(
      month: month,
      daysInMonth: calendarDays(month, next),
      elapsedDays: local.day,
      spentMinor: FinanceMath.summary(snapshot, month, tomorrow).expensesMinor,
      scheduledMinor: FinanceMath.summary(
        snapshot,
        tomorrow,
        next,
      ).expensesMinor,
    );
  }
}

/// A limit of [now]'s month against its spending pace.
class BudgetForecast {
  const BudgetForecast({
    required this.limitMinor,
    required this.usedMinor,
    required this.usedToDateMinor,
    required this.elapsedDays,
    required this.daysInMonth,
  });

  final int limitMinor;

  /// All spending of the month, including expenses dated after today.
  final int usedMinor;

  /// Spending up to the end of today; it sets the pace.
  final int usedToDateMinor;
  final int elapsedDays, daysInMonth;

  bool get exceeded => usedMinor >= limitMinor;

  int get projectedMinor =>
      _divRound(usedToDateMinor * daysInMonth, elapsedDays) +
      usedMinor -
      usedToDateMinor;

  /// Day of the month the limit runs out at the current pace; null if it is
  /// already spent, there is no pace yet or it lasts the whole month.
  int? get exhaustionDay {
    if (limitMinor <= 0 || exceeded || usedToDateMinor <= 0) return null;
    final remaining = limitMinor - usedMinor;
    // First whole day k with usedToDate / elapsed * k >= remaining.
    final extra =
        (remaining * elapsedDays + usedToDateMinor - 1) ~/ usedToDateMinor;
    final day = elapsedDays + extra;
    return day <= daysInMonth ? day : null;
  }

  /// Budgets of [now]'s month together; null when none is set.
  static BudgetForecast? total(
    Iterable<BudgetRecord> budgets,
    Iterable<TransactionRecord> items,
    DateTime now,
  ) {
    final local = now.toLocal();
    final month = DateTime(local.year, local.month);
    final snapshot = items.toList();
    final tomorrow = _tomorrow(now);
    var limit = 0, used = 0, toDate = 0, count = 0;
    for (final budget in budgets) {
      final m = budget.monthStart.toLocal();
      if (m.year != local.year || m.month != local.month) continue;
      count++;
      limit += budget.limitMinor;
      used += FinanceMath.budgetUsed(budget, snapshot);
      toDate += snapshot
          .where(
            (t) =>
                t.categoryName == budget.categoryName &&
                t.kind == TransactionKind.expense &&
                !t.isBalanceAdjustment &&
                !t.date.isBefore(month) &&
                t.date.isBefore(tomorrow),
          )
          .fold(0, (sum, t) => sum + t.amountMinor);
    }
    if (count == 0) return null;
    return BudgetForecast(
      limitMinor: limit,
      usedMinor: used,
      usedToDateMinor: toDate,
      elapsedDays: local.day,
      daysInMonth: calendarDays(month, DateTime(local.year, local.month + 1)),
    );
  }

  /// One budget; null unless it belongs to [now]'s month.
  static BudgetForecast? of(
    BudgetRecord budget,
    Iterable<TransactionRecord> items,
    DateTime now,
  ) => total([budget], items, now);
}

/// Totals of a calendar year month by month.
class YearReport {
  const YearReport(this.year, this.months, this.monthsElapsed);

  final int year;

  /// January to December, empty months included.
  final List<MonthlyTotal> months;

  /// Months that have started by now: 12 for past years, 0 for future ones.
  final int monthsElapsed;

  FinanceSummary get total => FinanceSummary(
    incomeMinor: months.fold(0, (s, m) => s + m.summary.incomeMinor),
    expensesMinor: months.fold(0, (s, m) => s + m.summary.expensesMinor),
  );

  /// Average over the months that have started.
  int get averageMonthlyExpensesMinor =>
      _divRound(total.expensesMinor, monthsElapsed);
  int get averageMonthlyIncomeMinor =>
      _divRound(total.incomeMinor, monthsElapsed);

  MonthlyTotal? get topExpenseMonth => _top((m) => m.summary.expensesMinor);
  MonthlyTotal? get topIncomeMonth => _top((m) => m.summary.incomeMinor);

  MonthlyTotal? _top(int Function(MonthlyTotal) value) {
    MonthlyTotal? best;
    for (final m in months) {
      if (value(m) > 0 && (best == null || value(m) > value(best))) best = m;
    }
    return best;
  }

  factory YearReport.of(
    Iterable<TransactionRecord> items,
    int year,
    DateTime now,
  ) {
    final local = now.toLocal();
    return YearReport(
      year,
      FinanceMath.monthlyTrend(items, DateTime(year, 12), months: 12),
      year < local.year
          ? 12
          : year > local.year
          ? 0
          : local.month,
    );
  }
}

class Analytics {
  /// Expenses of one category (grouped by name) per local month, the last
  /// [months] months through [through]'s month, oldest first.
  static List<MonthlyAmount> categoryTrend(
    Iterable<TransactionRecord> items,
    String categoryName,
    DateTime through, {
    int months = 12,
  }) {
    final local = through.toLocal();
    final first = DateTime(local.year, local.month - months + 1);
    final end = DateTime(local.year, local.month + 1);
    final sums = List.filled(months, 0);
    for (final t in items) {
      if (t.categoryName != categoryName ||
          t.kind != TransactionKind.expense ||
          t.isBalanceAdjustment ||
          t.date.isBefore(first) ||
          !t.date.isBefore(end)) {
        continue;
      }
      final d = t.date.toLocal();
      sums[(d.year - first.year) * 12 + d.month - first.month] += t.amountMinor;
    }
    return [
      for (var i = 0; i < months; i++)
        MonthlyAmount(DateTime(first.year, first.month + i), sums[i]),
    ];
  }
}

/// Integer division rounded half up; 0 for an empty divisor.
int _divRound(int value, int by) => by <= 0 ? 0 : (value * 2 + by) ~/ (by * 2);
