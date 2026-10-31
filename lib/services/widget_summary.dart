import '../domain/finance.dart';
import '../domain/money_format.dart';

/// Home-screen widget lines, written as preformatted strings to shared
/// preferences (`flutter.widget.*`) where the native Android widget reads them.
/// [transactions] are in the base currency; [balanceMinor], when given, is the
/// multi-currency total balance (contract v2 §3).
Map<String, String> widgetSummary({
  required Iterable<TransactionRecord> transactions,
  required Iterable<BudgetRecord> budgets,
  required String currency,
  required DateTime now,
  int? balanceMinor,
}) {
  final items = transactions.toList();
  final start = FinanceMath.monthStart(now.toLocal());
  final month = FinanceMath.summary(items, start, FinanceMath.nextMonth(start));
  final budget = FinanceMath.monthBudgets(budgets, items, now);
  final left = budget.limitMinor - budget.usedMinor;
  return {
    'widget.balance': money(
      balanceMinor ?? FinanceMath.totalBalance(items),
      currency,
    ),
    'widget.monthExpenses': money(month.expensesMinor, currency),
    'widget.budget': budget.count == 0
        ? 'Бюджеты на месяц не заданы'
        : left >= 0
        ? 'Остаток бюджета: ${money(left, currency)} из ${money(budget.limitMinor, currency)}'
        : 'Бюджет превышен на ${money(-left, currency)}',
  };
}
