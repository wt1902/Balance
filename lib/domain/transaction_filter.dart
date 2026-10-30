import 'finance.dart';

enum TransactionSort {
  newest('Сначала новые'),
  oldest('Сначала старые'),
  largest('Сначала крупные'),
  smallest('Сначала мелкие');

  const TransactionSort(this.title);
  final String title;
  bool get byDate => this == newest || this == oldest;
}

/// Quick periods for the filter; ranges are half-open local intervals.
enum PeriodPreset {
  thisMonth('Этот месяц'),
  lastMonth('Прошлый месяц'),
  threeMonths('3 месяца'),
  thisYear('Этот год');

  const PeriodPreset(this.title);
  final String title;

  (DateTime, DateTime) range(DateTime now) {
    final month = FinanceMath.monthStart(now);
    return switch (this) {
      thisMonth => (month, FinanceMath.nextMonth(month)),
      lastMonth => (DateTime(now.year, now.month - 1), month),
      // Same start as the 3-month analytics period.
      threeMonths => (
        DateTime(now.year, now.month - 2),
        FinanceMath.nextMonth(month),
      ),
      thisYear => (DateTime(now.year), DateTime(now.year + 1)),
    };
  }
}

/// What the operations list shows. Empty fields do not filter.
class TransactionFilter {
  const TransactionFilter({
    this.kind = 'all',
    this.query = '',
    this.start,
    this.endExclusive,
    this.minMinor,
    this.maxMinor,
    this.categories = const {},
    this.sort = TransactionSort.newest,
  });

  /// `all`, `expense` or `income`.
  final String kind;
  final String query;

  /// Period `[start, endExclusive)`.
  final DateTime? start, endExclusive;

  /// Inclusive amount bounds in hundredths.
  final int? minMinor, maxMinor;

  /// Category names; transactions group by name across the app.
  final Set<String> categories;
  final TransactionSort sort;

  bool get hasPeriod => start != null || endExclusive != null;
  bool get hasAmount => minMinor != null || maxMinor != null;

  /// Filters set in the filter sheet (search, kind and sort are on screen).
  int get activeCount =>
      (hasPeriod ? 1 : 0) + (hasAmount ? 1 : 0) + (categories.isEmpty ? 0 : 1);

  TransactionFilter copyWith({
    String? kind,
    String? query,
    DateTime? Function()? start,
    DateTime? Function()? endExclusive,
    int? Function()? minMinor,
    int? Function()? maxMinor,
    Set<String>? categories,
    TransactionSort? sort,
  }) => TransactionFilter(
    kind: kind ?? this.kind,
    query: query ?? this.query,
    start: start == null ? this.start : start(),
    endExclusive: endExclusive == null ? this.endExclusive : endExclusive(),
    minMinor: minMinor == null ? this.minMinor : minMinor(),
    maxMinor: maxMinor == null ? this.maxMinor : maxMinor(),
    categories: categories ?? this.categories,
    sort: sort ?? this.sort,
  );

  TransactionFilter withoutPeriod() =>
      copyWith(start: () => null, endExclusive: () => null);
  TransactionFilter withoutAmount() =>
      copyWith(minMinor: () => null, maxMinor: () => null);

  bool matches(TransactionRecord t) {
    if (kind != 'all' && t.kindRawValue != kind) return false;
    final from = start, to = endExclusive;
    if (from != null && t.date.isBefore(from)) return false;
    if (to != null && !t.date.isBefore(to)) return false;
    final min = minMinor, max = maxMinor;
    if (min != null && t.amountMinor < min) return false;
    if (max != null && t.amountMinor > max) return false;
    if (categories.isNotEmpty && !categories.contains(t.categoryName)) {
      return false;
    }
    final q = query.trim().toLowerCase();
    return q.isEmpty || '${t.categoryName} ${t.note}'.toLowerCase().contains(q);
  }

  /// Matching transactions in the chosen order; equal amounts newest first.
  List<TransactionRecord> apply(Iterable<TransactionRecord> items) {
    final result = items.where(matches).toList();
    int newestFirst(TransactionRecord a, TransactionRecord b) =>
        b.date.compareTo(a.date);
    result.sort(switch (sort) {
      TransactionSort.newest => newestFirst,
      TransactionSort.oldest => (a, b) => a.date.compareTo(b.date),
      TransactionSort.largest => (a, b) {
        final c = b.amountMinor.compareTo(a.amountMinor);
        return c != 0 ? c : newestFirst(a, b);
      },
      TransactionSort.smallest => (a, b) {
        final c = a.amountMinor.compareTo(b.amountMinor);
        return c != 0 ? c : newestFirst(a, b);
      },
    });
    return result;
  }
}

/// One local calendar day of the list with its totals. Like period analytics,
/// totals leave balance adjustments out; they still appear in [items].
class DayGroup {
  DayGroup(this.day, this.items);
  final DateTime day;
  final List<TransactionRecord> items;

  late final int incomeMinor = _sum(TransactionKind.income);
  late final int expenseMinor = _sum(TransactionKind.expense);
  int get netMinor => incomeMinor - expenseMinor;

  int _sum(TransactionKind kind) => items
      .where((t) => !t.isBalanceAdjustment && t.kind == kind)
      .fold(0, (sum, t) => sum + t.amountMinor);

  /// Consecutive transactions of the same local day; [items] must be sorted
  /// by date (either direction).
  static List<DayGroup> group(List<TransactionRecord> items) {
    final groups = <DayGroup>[];
    for (final item in items) {
      final local = item.date.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (groups.isEmpty || groups.last.day != day) {
        groups.add(DayGroup(day, [item]));
      } else {
        groups.last.items.add(item);
      }
    }
    return groups;
  }

  /// Income and expenses of a whole list, adjustments excluded.
  static FinanceSummary totals(Iterable<TransactionRecord> items) {
    var income = 0, expenses = 0;
    for (final t in items) {
      if (t.isBalanceAdjustment) continue;
      if (t.kind == TransactionKind.income) {
        income += t.amountMinor;
      } else {
        expenses += t.amountMinor;
      }
    }
    return FinanceSummary(incomeMinor: income, expensesMinor: expenses);
  }
}
