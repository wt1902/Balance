import 'finance.dart';

/// A budget of the current month that crossed 80% or 100% of its limit.
class BudgetAlert {
  const BudgetAlert({
    required this.budget,
    required this.threshold,
    required this.percent,
  });
  final BudgetRecord budget;

  /// 80 or 100.
  final int threshold;
  final int percent;

  String get title => 'Бюджет «${budget.categoryName}»';

  /// Percentages only: notifications can show on a lock screen, so no amounts.
  String body(String monthName) => threshold >= 100
      ? 'Лимит на $monthName превышен: израсходовано $percent%'
      : 'Израсходовано $percent% лимита на $monthName';
}

class NotificationRules {
  /// `budgetId|yyyy-mm`, so each month starts afresh.
  static String budgetKey(BudgetRecord budget) {
    final month = budget.monthStart.toLocal();
    return '${budget.id}|${month.year}-${month.month.toString().padLeft(2, '0')}';
  }

  /// Budgets of [now]'s month whose spending reached a threshold higher than
  /// the one already notified (`notified[budgetKey]`): 80% once, then 100%.
  /// Uses the same spending rule as the budgets screen (no adjustments).
  static List<BudgetAlert> budgetAlerts(
    Iterable<BudgetRecord> budgets,
    Iterable<TransactionRecord> transactions,
    DateTime now,
    Map<String, int> notified,
  ) {
    final local = now.toLocal();
    final items = transactions.toList();
    final alerts = <BudgetAlert>[];
    for (final budget in budgets) {
      final month = budget.monthStart.toLocal();
      if (month.year != local.year ||
          month.month != local.month ||
          budget.limitMinor <= 0) {
        continue;
      }
      final used = FinanceMath.budgetUsed(budget, items);
      final percent = used * 100 ~/ budget.limitMinor;
      final threshold = percent >= 100 ? 100 : (percent >= 80 ? 80 : 0);
      if (threshold > (notified[budgetKey(budget)] ?? 0)) {
        alerts.add(
          BudgetAlert(budget: budget, threshold: threshold, percent: percent),
        );
      }
    }
    return alerts;
  }

  /// True when a non-adjustment transaction is dated on [now]'s local day.
  static bool hasEntryToday(
    Iterable<TransactionRecord> transactions,
    DateTime now,
  ) {
    final local = now.toLocal();
    return transactions.any((t) {
      final date = t.date.toLocal();
      return !t.isBalanceAdjustment &&
          date.year == local.year &&
          date.month == local.month &&
          date.day == local.day;
    });
  }

  /// First reminder time: today at [hour]:[minute] if it is still ahead and
  /// nothing was entered today, otherwise tomorrow. It then repeats daily.
  static DateTime nextReminder(
    DateTime now,
    int hour,
    int minute, {
    required bool enteredToday,
  }) {
    final today = DateTime(now.year, now.month, now.day, hour, minute);
    return !enteredToday && today.isAfter(now)
        ? today
        : DateTime(now.year, now.month, now.day + 1, hour, minute);
  }
}
