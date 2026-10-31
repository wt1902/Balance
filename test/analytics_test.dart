import 'package:balance_flutter/domain/analytics.dart';
import 'package:balance_flutter/domain/finance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final stamp = DateTime.utc(2026);

  TransactionRecord record(
    String id,
    int amount,
    DateTime date, {
    String kind = 'expense',
    bool adjustment = false,
    String category = 'Продукты',
  }) => TransactionRecord(
    id: id,
    amountMinor: amount,
    date: date,
    categoryName: category,
    updatedAt: stamp,
    kindRawValue: kind,
    isBalanceAdjustment: adjustment,
  );

  BudgetRecord budget(String category, int limit, DateTime month) =>
      BudgetRecord(
        id: 'b-$category-${month.month}',
        categoryName: category,
        limitMinor: limit,
        monthStart: month,
        updatedAt: stamp,
      );

  group('helpers', () {
    test('calendarDays counts local calendar days', () {
      expect(calendarDays(DateTime(2026, 3), DateTime(2026, 4)), 31);
      expect(calendarDays(DateTime(2026, 3, 28), DateTime(2026, 3, 30)), 2);
      expect(
        calendarDays(DateTime(2026, 3, 5, 23), DateTime(2026, 3, 6, 1)),
        1,
      );
      expect(calendarDays(DateTime(2026, 3, 5), DateTime(2026, 3, 5)), 0);
    });

    test('pluralDays follows Russian plural rules', () {
      expect(pluralDays(0), '0 дней');
      expect(pluralDays(1), '1 день');
      expect(pluralDays(2), '2 дня');
      expect(pluralDays(4), '4 дня');
      expect(pluralDays(5), '5 дней');
      expect(pluralDays(11), '11 дней');
      expect(pluralDays(12), '12 дней');
      expect(pluralDays(14), '14 дней');
      expect(pluralDays(21), '21 день');
      expect(pluralDays(22), '22 дня');
      expect(pluralDays(25), '25 дней');
      expect(pluralDays(101), '101 день');
      expect(pluralDays(111), '111 дней');
    });
  });

  group('AnalyticsPeriod', () {
    final now = DateTime(2026, 3, 15, 12);

    test('months builds ranges ending with the current month', () {
      final one = AnalyticsPeriod.months(1, now);
      expect(one.kind, PeriodKind.months);
      expect(one.start, DateTime(2026, 3));
      expect(one.endExclusive, DateTime(2026, 4));
      expect(one.days, 31);

      final three = AnalyticsPeriod.months(3, now);
      expect(three.start, DateTime(2026, 1));
      expect(three.endExclusive, DateTime(2026, 4));
      expect(three.months, 3);

      final twelve = AnalyticsPeriod.months(12, now);
      expect(twelve.start, DateTime(2025, 4));
      expect(twelve.endExclusive, DateTime(2026, 4));
      expect(twelve.days, 365);
    });

    test('months rejects non-positive lengths', () {
      expect(() => AnalyticsPeriod.months(0, now), throwsArgumentError);
      expect(() => AnalyticsPeriod.months(-1, now), throwsArgumentError);
    });

    test('year covers a calendar year', () {
      final year = AnalyticsPeriod.year(2026);
      expect(year.kind, PeriodKind.year);
      expect(year.start, DateTime(2026));
      expect(year.endExclusive, DateTime(2027));
      expect(year.days, 365);
      expect(AnalyticsPeriod.year(2024).days, 366);
    });

    test('custom snaps to whole days and rejects empty ranges', () {
      final period = AnalyticsPeriod.custom(
        DateTime(2026, 3, 10, 15, 30),
        DateTime(2026, 3, 20, 8),
      );
      expect(period.kind, PeriodKind.custom);
      expect(period.start, DateTime(2026, 3, 10));
      expect(period.endExclusive, DateTime(2026, 3, 20));
      expect(period.days, 10);
      expect(
        () => AnalyticsPeriod.custom(
          DateTime(2026, 3, 5, 1),
          DateTime(2026, 3, 5, 23),
        ),
        throwsArgumentError,
      );
      expect(
        () =>
            AnalyticsPeriod.custom(DateTime(2026, 3, 6), DateTime(2026, 3, 5)),
        throwsArgumentError,
      );
    });

    test('previous is the same kind and length right before', () {
      final one = AnalyticsPeriod.months(1, now).previous;
      expect(one.start, DateTime(2026, 2));
      expect(one.endExclusive, DateTime(2026, 3));
      expect(one.months, 1);

      final three = AnalyticsPeriod.months(3, now).previous;
      expect(three.start, DateTime(2025, 10));
      expect(three.endExclusive, DateTime(2026, 1));

      final twelve = AnalyticsPeriod.months(12, now).previous;
      expect(twelve.start, DateTime(2024, 4));
      expect(twelve.endExclusive, DateTime(2025, 4));

      final year = AnalyticsPeriod.year(2026).previous;
      expect(year, AnalyticsPeriod.year(2025));

      final custom = AnalyticsPeriod.custom(
        DateTime(2026, 3, 10),
        DateTime(2026, 3, 20),
      ).previous;
      expect(custom.kind, PeriodKind.custom);
      expect(custom.start, DateTime(2026, 2, 28));
      expect(custom.endExclusive, DateTime(2026, 3, 10));
      expect(custom.days, 10);
    });

    test('previous of January goes to December of the previous year', () {
      final previous = AnalyticsPeriod.months(1, DateTime(2026, 1, 5)).previous;
      expect(previous.start, DateTime(2025, 12));
      expect(previous.endExclusive, DateTime(2026));
    });

    test('equality compares kind and bounds', () {
      expect(
        AnalyticsPeriod.months(1, now),
        AnalyticsPeriod.months(1, DateTime(2026, 3, 1)),
      );
      expect(
        AnalyticsPeriod.months(1, now).hashCode,
        AnalyticsPeriod.months(1, DateTime(2026, 3, 28)).hashCode,
      );
      expect(
        AnalyticsPeriod.months(1, now) == AnalyticsPeriod.months(3, now),
        isFalse,
      );
      expect(
        AnalyticsPeriod.custom(DateTime(2026, 3), DateTime(2026, 4)) ==
            AnalyticsPeriod.months(1, now),
        isFalse,
      );
    });

    test('elapsedDays and isOngoing for an ongoing month', () {
      final march = AnalyticsPeriod.months(1, now);
      expect(march.elapsedEnd(now), DateTime(2026, 3, 16));
      expect(march.elapsedDays(now), 15);
      expect(march.isOngoing(now), isTrue);
    });

    test('the first day counts as one elapsed day', () {
      final march = AnalyticsPeriod.months(1, DateTime(2026, 3, 1, 0, 5));
      expect(march.elapsedDays(DateTime(2026, 3, 1, 0, 5)), 1);
      expect(march.isOngoing(DateTime(2026, 3, 1, 0, 5)), isTrue);
    });

    test('the last day is elapsed but the period is no longer ongoing', () {
      final march = AnalyticsPeriod.months(1, now);
      final last = DateTime(2026, 3, 31, 18);
      expect(march.elapsedDays(last), 31);
      expect(march.isOngoing(last), isFalse);
    });

    test('a finished period is fully elapsed', () {
      final march = AnalyticsPeriod.months(1, now);
      final later = DateTime(2026, 4, 20);
      expect(march.elapsedEnd(later), DateTime(2026, 4));
      expect(march.elapsedDays(later), 31);
      expect(march.isOngoing(later), isFalse);
    });

    test('a future period has no elapsed days', () {
      final march = AnalyticsPeriod.months(1, now);
      final before = DateTime(2026, 2, 10);
      expect(march.elapsedEnd(before), DateTime(2026, 3));
      expect(march.elapsedDays(before), 0);
      expect(march.isOngoing(before), isFalse);
    });

    test('a custom period can be ongoing', () {
      final period = AnalyticsPeriod.custom(
        DateTime(2026, 3, 10),
        DateTime(2026, 3, 20),
      );
      expect(period.elapsedDays(DateTime(2026, 3, 14, 9)), 5);
      expect(period.isOngoing(DateTime(2026, 3, 14, 9)), isTrue);
      expect(period.isOngoing(DateTime(2026, 3, 25)), isFalse);
    });

    test('previousTitle describes the previous period', () {
      expect(
        AnalyticsPeriod.months(1, DateTime(2026, 10, 31)).previousTitle,
        'в сентябре',
      );
      expect(
        AnalyticsPeriod.months(1, DateTime(2026, 1, 5)).previousTitle,
        'в декабре',
      );
      expect(
        AnalyticsPeriod.months(1, DateTime(2026, 5, 5)).previousTitle,
        'в апреле',
      );
      expect(
        AnalyticsPeriod.months(3, now).previousTitle,
        'за предыдущие 3 месяца',
      );
      expect(
        AnalyticsPeriod.months(12, now).previousTitle,
        'за предыдущие 12 месяцев',
      );
      expect(AnalyticsPeriod.year(2026).previousTitle, 'в 2025 году');
      expect(
        AnalyticsPeriod.custom(
          DateTime(2026, 3, 10),
          DateTime(2026, 3, 20),
        ).previousTitle,
        'за предыдущие 10 дней',
      );
      expect(
        AnalyticsPeriod.custom(
          DateTime(2026, 3, 10),
          DateTime(2026, 3, 11),
        ).previousTitle,
        'за предыдущие 1 день',
      );
      expect(
        AnalyticsPeriod.custom(
          DateTime(2026, 3, 10),
          DateTime(2026, 3, 12),
        ).previousTitle,
        'за предыдущие 2 дня',
      );
    });
  });

  group('PeriodComparison', () {
    test('an ongoing month compares the same number of elapsed days', () {
      final now = DateTime(2026, 3, 15, 10);
      final items = [
        // Current: 1-15 March.
        record('c1', 1000, DateTime(2026, 3, 1)),
        record('c2', 500, DateTime(2026, 3, 15, 9)),
        record('c3', 7000, DateTime(2026, 3, 16)),
        record('c4', 99999, DateTime(2026, 3, 5), adjustment: true),
        record('ci', 20000, DateTime(2026, 3, 2), kind: 'income'),
        // Previous: 1-15 February.
        record('p1', 1200, DateTime(2026, 2)),
        record('p2', 400, DateTime(2026, 2, 15, 23)),
        record('p3', 9999, DateTime(2026, 2, 16)),
        record('pi', 10000, DateTime(2026, 2, 3), kind: 'income'),
      ];
      final comparison = PeriodComparison.of(
        items,
        AnalyticsPeriod.months(1, now),
        now,
      );
      expect(comparison.partial, isTrue);
      expect(comparison.currentStart, DateTime(2026, 3));
      expect(comparison.currentEnd, DateTime(2026, 3, 16));
      expect(comparison.previousStart, DateTime(2026, 2));
      expect(comparison.previousEnd, DateTime(2026, 2, 16));
      expect(comparison.current.expensesMinor, 1500);
      expect(comparison.previous.expensesMinor, 1600);
      expect(comparison.current.incomeMinor, 20000);
      expect(comparison.previous.incomeMinor, 10000);
      expect(comparison.expensesChange, -6);
      expect(comparison.incomeChange, 100);
      expect(comparison.previousTitle, 'в феврале');
      expect(comparison.expensesText, 'Расходы на 6% ниже, чем в феврале');
      expect(comparison.incomeText, 'Доходы на 100% выше, чем в феврале');
    });

    test('the previous side is clamped to its whole month', () {
      // 30 elapsed days of March against a 28-day February.
      final now = DateTime(2026, 3, 30, 12);
      final items = [
        record('c1', 100, DateTime(2026, 3, 29)),
        record('c2', 1000, DateTime(2026, 3, 31)),
        record('p1', 200, DateTime(2026, 2)),
        record('p2', 300, DateTime(2026, 2, 28, 23)),
      ];
      final comparison = PeriodComparison.of(
        items,
        AnalyticsPeriod.months(1, now),
        now,
      );
      expect(comparison.partial, isTrue);
      expect(comparison.currentEnd, DateTime(2026, 3, 31));
      expect(comparison.previousEnd, DateTime(2026, 3));
      expect(comparison.current.expensesMinor, 100);
      expect(comparison.previous.expensesMinor, 500);
    });

    test('February against January stops at the same day', () {
      final now = DateTime(2026, 2, 20, 12);
      final items = [
        record('c1', 100, DateTime(2026, 2, 20)),
        record('c2', 50, DateTime(2026, 2, 21)),
        record('p1', 400, DateTime(2026, 1, 20, 23)),
        record('p2', 800, DateTime(2026, 1, 21)),
      ];
      final comparison = PeriodComparison.of(
        items,
        AnalyticsPeriod.months(1, now),
        now,
      );
      expect(comparison.currentEnd, DateTime(2026, 2, 21));
      expect(comparison.previousEnd, DateTime(2026, 1, 21));
      expect(comparison.current.expensesMinor, 100);
      expect(comparison.previous.expensesMinor, 400);
      expect(comparison.previousTitle, 'в январе');
    });

    test('a finished month compares whole ranges', () {
      // 31 October is the last day: the month is no longer ongoing.
      final now = DateTime(2026, 10, 31, 12);
      final items = [
        record('c1', 5000, DateTime(2026, 10)),
        record('c2', 6200, DateTime(2026, 10, 31, 20)),
        record('p1', 4000, DateTime(2026, 9)),
        record('p2', 6000, DateTime(2026, 9, 30, 23)),
        record('p3', 777, DateTime(2026, 8, 31)),
      ];
      final comparison = PeriodComparison.of(
        items,
        AnalyticsPeriod.months(1, now),
        now,
      );
      expect(comparison.partial, isFalse);
      expect(comparison.currentEnd, DateTime(2026, 11));
      expect(comparison.previousEnd, DateTime(2026, 10));
      expect(comparison.current.expensesMinor, 11200);
      expect(comparison.previous.expensesMinor, 10000);
      expect(comparison.expensesChange, 12);
      expect(comparison.expensesText, 'Расходы на 12% выше, чем в сентябре');
    });

    test('a finished year compares whole years', () {
      final now = DateTime(2026, 3, 15);
      final items = [
        record('c1', 2000, DateTime(2025, 12, 31, 23)),
        record('c2', 5000, DateTime(2026)),
        record('p1', 1000, DateTime(2024, 12, 31)),
        record('p2', 1000, DateTime(2024, 6)),
        record('p3', 4000, DateTime(2023, 12, 31)),
      ];
      final comparison = PeriodComparison.of(
        items,
        AnalyticsPeriod.year(2025),
        now,
      );
      expect(comparison.partial, isFalse);
      expect(comparison.previousStart, DateTime(2024));
      expect(comparison.previousEnd, DateTime(2025));
      expect(comparison.current.expensesMinor, 2000);
      expect(comparison.previous.expensesMinor, 2000);
      expect(comparison.expensesChange, 0);
      expect(comparison.expensesText, 'Расходы такие же, как в 2024 году');
    });

    test('a custom ongoing period uses its own elapsed days', () {
      final now = DateTime(2026, 3, 14, 9);
      final period = AnalyticsPeriod.custom(
        DateTime(2026, 3, 10),
        DateTime(2026, 3, 20),
      );
      final items = [
        record('c1', 100, DateTime(2026, 3, 14)),
        record('c2', 900, DateTime(2026, 3, 15)),
        // Previous period starts 28 February, 5 days are compared.
        record('p1', 300, DateTime(2026, 3, 4, 23)),
        record('p2', 700, DateTime(2026, 3, 5)),
      ];
      final comparison = PeriodComparison.of(items, period, now);
      expect(comparison.partial, isTrue);
      expect(comparison.currentEnd, DateTime(2026, 3, 15));
      expect(comparison.previousStart, DateTime(2026, 2, 28));
      expect(comparison.previousEnd, DateTime(2026, 3, 5));
      expect(comparison.current.expensesMinor, 100);
      expect(comparison.previous.expensesMinor, 300);
      expect(comparison.previousTitle, 'за предыдущие 10 дней');
    });

    test('changePercent rounds and is null without a base', () {
      expect(PeriodComparison.changePercent(100, 0), isNull);
      expect(PeriodComparison.changePercent(0, 0), isNull);
      expect(PeriodComparison.changePercent(150, 100), 50);
      expect(PeriodComparison.changePercent(50, 100), -50);
      expect(PeriodComparison.changePercent(100, 100), 0);
      expect(PeriodComparison.changePercent(0, 100), -100);
      expect(PeriodComparison.changePercent(1, 3), -67);
      expect(PeriodComparison.changePercent(4, 3), 33);
    });

    test('texts explain a missing base', () {
      final now = DateTime(2026, 10, 31, 12);
      final comparison = PeriodComparison.of(
        [record('c1', 100, DateTime(2026, 10, 5))],
        AnalyticsPeriod.months(1, now),
        now,
      );
      expect(comparison.expensesChange, isNull);
      expect(comparison.incomeChange, isNull);
      expect(comparison.expensesText, 'Нет расходов в сентябре для сравнения');
      expect(comparison.incomeText, 'Нет доходов в сентябре для сравнения');
    });

    test('empty ledger yields zero summaries', () {
      final now = DateTime(2026, 3, 15);
      final comparison = PeriodComparison.of(
        const <TransactionRecord>[],
        AnalyticsPeriod.months(3, now),
        now,
      );
      expect(comparison.current.expensesMinor, 0);
      expect(comparison.previous.incomeMinor, 0);
      expect(comparison.previousTitle, 'за предыдущие 3 месяца');
    });
  });

  group('TrendBucket', () {
    test('up to 45 days uses day buckets', () {
      final buckets = TrendBucket.of(DateTime(2026, 3), DateTime(2026, 3, 11));
      expect(buckets, hasLength(10));
      expect(buckets.every((b) => b.size == BucketSize.day), isTrue);
      expect(buckets.first.start, DateTime(2026, 3));
      expect(buckets.first.endExclusive, DateTime(2026, 3, 2));
      expect(buckets.last.start, DateTime(2026, 3, 10));
      expect(buckets.last.endExclusive, DateTime(2026, 3, 11));
    });

    test('45 days is still daily and 46 days switches to weeks', () {
      final daily = TrendBucket.of(DateTime(2026, 3), DateTime(2026, 4, 15));
      expect(daily, hasLength(45));
      expect(daily.first.size, BucketSize.day);

      final weekly = TrendBucket.of(DateTime(2026, 3), DateTime(2026, 4, 16));
      expect(weekly.first.size, BucketSize.week);
    });

    test('weeks start on Monday and are clipped to the period', () {
      // 1 March 2026 is a Sunday, 30 April a Thursday.
      final buckets = TrendBucket.of(DateTime(2026, 3), DateTime(2026, 4, 30));
      expect(buckets, hasLength(10));
      expect(buckets.every((b) => b.size == BucketSize.week), isTrue);
      expect(buckets.first.start, DateTime(2026, 3));
      expect(buckets.first.endExclusive, DateTime(2026, 3, 2));
      expect(buckets[1].start, DateTime(2026, 3, 2));
      expect(buckets[1].start.weekday, DateTime.monday);
      expect(buckets[1].endExclusive, DateTime(2026, 3, 9));
      expect(buckets.last.start, DateTime(2026, 4, 27));
      expect(buckets.last.endExclusive, DateTime(2026, 4, 30));
      for (var i = 1; i < buckets.length; i++) {
        expect(buckets[i].start, buckets[i - 1].endExclusive);
      }
    });

    test('a week-aligned period yields whole weeks', () {
      // Monday 2 March to Monday 4 May: nine whole weeks.
      final buckets = TrendBucket.of(
        DateTime(2026, 3, 2),
        DateTime(2026, 5, 4),
      );
      expect(buckets, hasLength(9));
      expect(
        buckets.every((b) => calendarDays(b.start, b.endExclusive) == 7),
        isTrue,
      );
    });

    test('130 days is weekly and 131 days switches to months', () {
      final weekly = TrendBucket.of(DateTime(2026, 3), DateTime(2026, 7, 9));
      expect(weekly.first.size, BucketSize.week);

      final monthly = TrendBucket.of(DateTime(2026, 3), DateTime(2026, 7, 10));
      expect(monthly.first.size, BucketSize.month);
    });

    test('a year is twelve month buckets', () {
      final buckets = TrendBucket.of(DateTime(2026), DateTime(2027));
      expect(buckets, hasLength(12));
      expect(buckets.every((b) => b.size == BucketSize.month), isTrue);
      expect(buckets[1].start, DateTime(2026, 2));
      expect(buckets[1].endExclusive, DateTime(2026, 3));
      expect(buckets.last.endExclusive, DateTime(2027));
    });

    test('month buckets are clipped at both ends', () {
      final buckets = TrendBucket.of(
        DateTime(2026, 1, 15),
        DateTime(2026, 8, 10),
      );
      expect(buckets, hasLength(8));
      expect(buckets.first.start, DateTime(2026, 1, 15));
      expect(buckets.first.endExclusive, DateTime(2026, 2));
      expect(buckets.last.start, DateTime(2026, 8));
      expect(buckets.last.endExclusive, DateTime(2026, 8, 10));
    });
  });

  group('MonthForecast', () {
    final now = DateTime(2026, 4, 10, 15);

    test('pace, projection and scheduled expenses', () {
      final items = [
        record('a', 1000, DateTime(2026, 4)),
        record('b', 500, DateTime(2026, 4, 10, 8)),
        // Scheduled for later this month.
        record('c', 2000, DateTime(2026, 4, 11)),
        record('d', 300, DateTime(2026, 4, 30, 23)),
        // Ignored.
        record('adj', 99999, DateTime(2026, 4, 5), adjustment: true),
        record('inc', 5000, DateTime(2026, 4, 3), kind: 'income'),
        record('prev', 777, DateTime(2026, 3, 31, 23)),
        record('next', 888, DateTime(2026, 5)),
      ];
      final forecast = MonthForecast.of(items, now);
      expect(forecast.month, DateTime(2026, 4));
      expect(forecast.daysInMonth, 30);
      expect(forecast.elapsedDays, 10);
      expect(forecast.spentMinor, 1500);
      expect(forecast.scheduledMinor, 2300);
      expect(forecast.dailyPaceMinor, 150);
      expect(forecast.projectedMinor, 4500 + 2300);
    });

    test('pace rounds half up', () {
      final forecast = MonthForecast.of([
        record('a', 100, DateTime(2026, 4, 2)),
      ], DateTime(2026, 4, 8));
      expect(forecast.dailyPaceMinor, 13);

      final third = MonthForecast.of([
        record('a', 1000, DateTime(2026, 4, 2)),
      ], DateTime(2026, 4, 3));
      expect(third.dailyPaceMinor, 333);
      expect(third.projectedMinor, 10000);
    });

    test('empty month projects only scheduled expenses', () {
      final forecast = MonthForecast.of([
        record('a', 400, DateTime(2026, 4, 20)),
      ], now);
      expect(forecast.spentMinor, 0);
      expect(forecast.dailyPaceMinor, 0);
      expect(forecast.projectedMinor, 400);
    });

    test('the last day has nothing scheduled', () {
      final forecast = MonthForecast.of([
        record('a', 3000, DateTime(2026, 4, 30, 10)),
        record('b', 100, DateTime(2026, 5)),
      ], DateTime(2026, 4, 30, 20));
      expect(forecast.elapsedDays, 30);
      expect(forecast.spentMinor, 3000);
      expect(forecast.scheduledMinor, 0);
      expect(forecast.projectedMinor, 3000);
    });

    test('leap February has 29 days', () {
      final forecast = MonthForecast.of(
        const <TransactionRecord>[],
        DateTime(2024, 2, 10),
      );
      expect(forecast.daysInMonth, 29);
      expect(
        MonthForecast.of(
          const <TransactionRecord>[],
          DateTime(2026, 2, 10),
        ).daysInMonth,
        28,
      );
    });
  });

  group('BudgetForecast', () {
    final now = DateTime(2026, 4, 10, 15);
    final april = DateTime(2026, 4);

    test('limit runs out on the last day of the month', () {
      final forecast = BudgetForecast.of(budget('Продукты', 3000, april), [
        record('a', 600, DateTime(2026, 4, 4)),
        record('b', 400, DateTime(2026, 4, 10, 9)),
      ], now)!;
      expect(forecast.limitMinor, 3000);
      expect(forecast.usedMinor, 1000);
      expect(forecast.usedToDateMinor, 1000);
      expect(forecast.elapsedDays, 10);
      expect(forecast.daysInMonth, 30);
      expect(forecast.exceeded, isFalse);
      expect(forecast.projectedMinor, 3000);
      expect(forecast.exhaustionDay, 30);
    });

    test('a smaller limit runs out earlier', () {
      final forecast = BudgetForecast.of(budget('Продукты', 2000, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
      ], now)!;
      expect(forecast.exhaustionDay, 20);
    });

    test('a limit that lasts the whole month has no exhaustion day', () {
      final forecast = BudgetForecast.of(budget('Продукты', 3001, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
      ], now)!;
      expect(forecast.exceeded, isFalse);
      expect(forecast.exhaustionDay, isNull);
    });

    test('an exceeded limit has no exhaustion day', () {
      final exact = BudgetForecast.of(budget('Продукты', 1000, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
      ], now)!;
      expect(exact.exceeded, isTrue);
      expect(exact.exhaustionDay, isNull);

      final over = BudgetForecast.of(budget('Продукты', 500, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
      ], now)!;
      expect(over.exceeded, isTrue);
      expect(over.exhaustionDay, isNull);
    });

    test('a zero limit has no exhaustion day', () {
      final forecast = BudgetForecast.of(budget('Продукты', 0, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
      ], now)!;
      expect(forecast.exhaustionDay, isNull);
    });

    test('without spending to date there is no pace', () {
      final forecast = BudgetForecast.of(budget('Продукты', 3000, april), [
        record('a', 500, DateTime(2026, 4, 20)),
      ], now)!;
      expect(forecast.usedMinor, 500);
      expect(forecast.usedToDateMinor, 0);
      expect(forecast.exhaustionDay, isNull);
      expect(forecast.projectedMinor, 500);

      final empty = BudgetForecast.of(
        budget('Продукты', 3000, april),
        const <TransactionRecord>[],
        now,
      )!;
      expect(empty.exhaustionDay, isNull);
      expect(empty.projectedMinor, 0);
    });

    test('future expenses count as used but not as pace', () {
      final forecast = BudgetForecast.of(budget('Продукты', 3000, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
        record('b', 500, DateTime(2026, 4, 20)),
      ], now)!;
      expect(forecast.usedMinor, 1500);
      expect(forecast.usedToDateMinor, 1000);
      expect(forecast.projectedMinor, 3500);
      expect(forecast.exhaustionDay, 25);
    });

    test('other categories, income and adjustments are not counted', () {
      final forecast = BudgetForecast.of(budget('Продукты', 3000, april), [
        record('a', 1000, DateTime(2026, 4, 4)),
        record('other', 5000, DateTime(2026, 4, 4), category: 'Кафе'),
        record('inc', 5000, DateTime(2026, 4, 4), kind: 'income'),
        record('adj', 5000, DateTime(2026, 4, 4), adjustment: true),
        record('prev', 5000, DateTime(2026, 3, 31, 23)),
        record('next', 5000, DateTime(2026, 5)),
      ], now)!;
      expect(forecast.usedMinor, 1000);
      expect(forecast.usedToDateMinor, 1000);
    });

    test('a budget of another month is ignored', () {
      final march = budget('Продукты', 3000, DateTime(2026, 3));
      final items = [record('a', 1000, DateTime(2026, 4, 4))];
      expect(BudgetForecast.of(march, items, now), isNull);
      expect(BudgetForecast.total([march], items, now), isNull);
      expect(BudgetForecast.total(const <BudgetRecord>[], items, now), isNull);
    });

    test('total sums only the budgets of the current month', () {
      final forecast = BudgetForecast.total(
        [
          budget('Продукты', 2500, april),
          budget('Транспорт', 1000, april),
          budget('Дом', 5000, DateTime(2026, 3)),
        ],
        [
          record('a', 1000, DateTime(2026, 4, 4)),
          record('adj', 9999, DateTime(2026, 4, 3), adjustment: true),
          record('t1', 200, DateTime(2026, 4, 2), category: 'Транспорт'),
          record('t2', 300, DateTime(2026, 4, 20), category: 'Транспорт'),
          record('h', 4000, DateTime(2026, 4, 5), category: 'Дом'),
          record('old', 800, DateTime(2026, 3, 20)),
        ],
        now,
      )!;
      expect(forecast.limitMinor, 3500);
      expect(forecast.usedMinor, 1500);
      expect(forecast.usedToDateMinor, 1200);
      expect(forecast.elapsedDays, 10);
      expect(forecast.daysInMonth, 30);
      expect(forecast.projectedMinor, 3600 + 300);
      expect(forecast.exhaustionDay, 27);
    });
  });

  group('YearReport', () {
    MonthlyTotal month(int m, {int income = 0, int expenses = 0}) =>
        MonthlyTotal(
          DateTime(2026, m),
          FinanceSummary(incomeMinor: income, expensesMinor: expenses),
        );

    List<MonthlyTotal> twelve(Map<int, (int, int)> values) => [
      for (var m = 1; m <= 12; m++)
        month(m, income: values[m]?.$1 ?? 0, expenses: values[m]?.$2 ?? 0),
    ];

    test('totals, averages and top months', () {
      final report = YearReport(
        2026,
        twelve({1: (5000, 1000), 2: (0, 3000), 3: (7000, 2000)}),
        3,
      );
      expect(report.total.incomeMinor, 12000);
      expect(report.total.expensesMinor, 6000);
      expect(report.total.balanceMinor, 6000);
      expect(report.averageMonthlyExpensesMinor, 2000);
      expect(report.averageMonthlyIncomeMinor, 4000);
      expect(report.topExpenseMonth?.month, DateTime(2026, 2));
      expect(report.topIncomeMonth?.month, DateTime(2026, 3));
    });

    test('averages are rounded and divide by elapsed months only', () {
      final report = YearReport(2026, twelve({1: (100, 1000)}), 3);
      expect(report.averageMonthlyExpensesMinor, 333);
      expect(report.averageMonthlyIncomeMinor, 33);

      final full = YearReport(2026, twelve({1: (0, 1200)}), 12);
      expect(full.averageMonthlyExpensesMinor, 100);
    });

    test('a future year has zero averages', () {
      final report = YearReport(2026, twelve({}), 0);
      expect(report.averageMonthlyExpensesMinor, 0);
      expect(report.averageMonthlyIncomeMinor, 0);
    });

    test('top months are null for an empty year and ties keep the first', () {
      final empty = YearReport(2026, twelve({}), 12);
      expect(empty.topExpenseMonth, isNull);
      expect(empty.topIncomeMonth, isNull);

      final tie = YearReport(2026, twelve({4: (0, 900), 8: (0, 900)}), 12);
      expect(tie.topExpenseMonth?.month, DateTime(2026, 4));
      expect(tie.topIncomeMonth, isNull);
    });

    test('monthsElapsed depends on the year relative to now', () {
      final now = DateTime(2026, 3, 15);
      expect(
        YearReport.of(const <TransactionRecord>[], 2025, now).monthsElapsed,
        12,
      );
      expect(
        YearReport.of(const <TransactionRecord>[], 2026, now).monthsElapsed,
        3,
      );
      expect(
        YearReport.of(const <TransactionRecord>[], 2027, now).monthsElapsed,
        0,
      );
      expect(
        YearReport.of(
          const <TransactionRecord>[],
          2026,
          DateTime(2026, 12, 31, 23),
        ).monthsElapsed,
        12,
      );
      expect(
        YearReport.of(
          const <TransactionRecord>[],
          2026,
          DateTime(2026, 1, 1),
        ).monthsElapsed,
        1,
      );
    });

    test('of builds twelve months January to December', () {
      final now = DateTime(2026, 3, 15);
      final report = YearReport.of(
        [
          record('a', 1000, DateTime(2026, 1, 10)),
          record('b', 5000, DateTime(2026, 1, 11), kind: 'income'),
          record('c', 3000, DateTime(2026, 2, 28, 23)),
          record('d', 2000, DateTime(2026, 3, 1)),
          record('adj', 99999, DateTime(2026, 3, 2), adjustment: true),
          record('prev', 4444, DateTime(2025, 12, 31, 23)),
          record('next', 5555, DateTime(2027)),
        ],
        2026,
        now,
      );
      expect(report.year, 2026);
      expect(report.months, hasLength(12));
      expect(report.months.first.month, DateTime(2026));
      expect(report.months.last.month, DateTime(2026, 12));
      expect(report.months[1].summary.expensesMinor, 3000);
      expect(report.total.expensesMinor, 6000);
      expect(report.total.incomeMinor, 5000);
      expect(report.averageMonthlyExpensesMinor, 2000);
      expect(report.topExpenseMonth?.month, DateTime(2026, 2));
      expect(report.topIncomeMonth?.month, DateTime(2026));
    });
  });

  group('Analytics.categoryTrend', () {
    final through = DateTime(2026, 3, 20);

    test('returns twelve months oldest first', () {
      final trend = Analytics.categoryTrend(
        const <TransactionRecord>[],
        'Кафе',
        through,
      );
      expect(trend, hasLength(12));
      expect(trend.first.month, DateTime(2025, 4));
      expect(trend[8].month, DateTime(2025, 12));
      expect(trend.last.month, DateTime(2026, 3));
      expect(trend.every((m) => m.amountMinor == 0), isTrue);
    });

    test('sums one category expenses per month', () {
      final trend = Analytics.categoryTrend(
        [
          record('a', 500, DateTime(2026, 3, 5), category: 'Кафе'),
          record('b', 300, DateTime(2026, 3, 20), category: 'Кафе'),
          record('c', 200, DateTime(2026, 3, 31, 23), category: 'Кафе'),
          record('d', 100, DateTime(2025, 4), category: 'Кафе'),
          record('e', 400, DateTime(2026, 1, 15), category: 'Кафе'),
          // Out of the window.
          record('before', 999, DateTime(2025, 3, 31, 23), category: 'Кафе'),
          record('after', 888, DateTime(2026, 4), category: 'Кафе'),
          // Other category, income and adjustment.
          record('other', 777, DateTime(2026, 3, 5), category: 'Такси'),
          record(
            'income',
            666,
            DateTime(2026, 3, 5),
            category: 'Кафе',
            kind: 'income',
          ),
          record(
            'adj',
            555,
            DateTime(2026, 3, 5),
            category: 'Кафе',
            adjustment: true,
          ),
        ],
        'Кафе',
        through,
      );
      expect(trend[0].amountMinor, 100);
      expect(trend[9].month, DateTime(2026));
      expect(trend[9].amountMinor, 400);
      expect(trend[11].amountMinor, 1000);
      final others = [
        for (var i = 0; i < trend.length; i++)
          if (i != 0 && i != 9 && i != 11) trend[i].amountMinor,
      ];
      expect(others.every((v) => v == 0), isTrue);
    });

    test('supports a custom length across a year boundary', () {
      final trend = Analytics.categoryTrend(
        [
          record('a', 100, DateTime(2025, 12, 31, 23), category: 'Кафе'),
          record('b', 200, DateTime(2026, 1), category: 'Кафе'),
          record('c', 300, DateTime(2025, 11, 30), category: 'Кафе'),
        ],
        'Кафе',
        DateTime(2026, 1, 20),
        months: 2,
      );
      expect(trend, hasLength(2));
      expect(trend[0].month, DateTime(2025, 12));
      expect(trend[0].amountMinor, 100);
      expect(trend[1].month, DateTime(2026));
      expect(trend[1].amountMinor, 200);
    });
  });
}
