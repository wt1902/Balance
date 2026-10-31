import '../domain/finance.dart';
import '../domain/money_format.dart';

/// Home-screen widget lines, written as preformatted strings to shared
/// preferences (`flutter.widget.*`) where the native Android widget reads them.
Map<String, String> widgetSummary({
  required Iterable<TransactionRecord> transactions,
  required Iterable<BudgetRecord> budgets,
  required String currency,
  required DateTime now,
}) {
  final items = transactions.toList();
  final start = FinanceMath.monthStart(now.toLocal());
  final month = FinanceMath.summary(items, start, FinanceMath.nextMonth(start));
  final budget = FinanceMath.monthBudgets(budgets, items, now);
  final left = budget.limitMinor - budget.usedMinor;
  return {
    'widget.balance': money(FinanceMath.totalBalance(items), currency),
    'widget.monthExpenses': money(month.expensesMinor, currency),
    'widget.budget': budget.count == 0
        ? 'Бюджеты на месяц не заданы'
        : left >= 0
        ? 'Остаток бюджета: ${money(left, currency)} из ${money(budget.limitMinor, currency)}'
        : 'Бюджет превышен на ${money(-left, currency)}',
  };
}
