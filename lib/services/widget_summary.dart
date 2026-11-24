import '../domain/finance.dart';
import '../domain/money_format.dart';
import '../l10n/app_strings.dart';

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
  bool allLanguages = false,
}) {
  final items = transactions.toList();
  final start = FinanceMath.monthStart(now.toLocal());
  final month = FinanceMath.summary(items, start, FinanceMath.nextMonth(start));
  final budget = FinanceMath.monthBudgets(budgets, items, now);
  final left = budget.limitMinor - budget.usedMinor;
  final balance = balanceMinor ?? FinanceMath.totalBalance(items);
  final result = <String, String>{};
  for (final language in allLanguages ? const ['ru', 'en'] : const ['ru']) {
    final suffix = allLanguages ? '.$language' : '';
    String format(int minor) => money(minor, currency, locale: language);
    result['widget.balance$suffix'] = format(balance);
    result['widget.monthExpenses$suffix'] = format(month.expensesMinor);
    result['widget.budget$suffix'] = budget.count == 0
        ? uiTextFor(language, 'Бюджеты на месяц не заданы')
        : left >= 0
        ? uiTextFor(language, 'Остаток бюджета: {0} из {1}', [
            format(left),
            format(budget.limitMinor),
          ])
        : uiTextFor(language, 'Бюджет превышен на {0}', [format(-left)]);
  }
  return result;
}
