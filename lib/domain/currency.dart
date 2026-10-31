/// Multi-currency balances (contract v2 §2–3). Amounts stay integer
/// hundredths; a rate is applied through its exact decimal value, never
/// through accumulated `double`s.
library;

import 'finance.dart';
import 'records.dart';

final _million = BigInt.from(1000000);

/// Divides with rounding half up, away from zero.
int _roundDiv(BigInt numerator, BigInt denominator) {
  final negative = numerator.isNegative != denominator.isNegative;
  final n = numerator.abs(), d = denominator.abs();
  final q = (n * BigInt.two + d) ~/ (d * BigInt.two);
  return (negative ? -q : q).toInt();
}

/// The rate chosen for converting [from] into [to]: [record] is either the
/// direct pair or the reverse one ([inverse], the amount is then divided).
class RateQuote {
  const RateQuote(this.record, {required this.inverse});
  final RateRecord record;
  final bool inverse;

  int convert(int minor) => inverse
      ? _roundDiv(BigInt.from(minor) * _million, record.rateMicros)
      : _roundDiv(BigInt.from(minor) * record.rateMicros, _million);
}

/// Converts amounts with the latest known rates (§2). A rate dated after
/// [asOf] is not used yet; the rate of the calculation date applies to every
/// period, not the rate of each operation's date.
class CurrencyConverter {
  CurrencyConverter({
    required this.baseCurrency,
    Iterable<RateRecord> rates = const [],
    this.asOf,
  }) : _rates = [
         for (final rate in rates)
           if (asOf == null || !rate.date.isAfter(asOf)) rate,
       ];

  final String baseCurrency;
  final DateTime? asOf;
  final List<RateRecord> _rates;
  final Map<String, RateQuote?> _quotes = {};

  /// The latest record by `date`, then direct pair before reverse, then by
  /// `updatedAt`. Null when no record links the two currencies.
  RateQuote? quote(String from, String to) =>
      _quotes.putIfAbsent('$from→$to', () {
        RateQuote? best;
        int compare(RateQuote a, RateQuote b) {
          final byDate = a.record.date.compareTo(b.record.date);
          if (byDate != 0) return byDate;
          if (a.inverse != b.inverse) return a.inverse ? -1 : 1;
          return a.record.updatedAt.compareTo(b.record.updatedAt);
        }

        for (final rate in _rates) {
          final RateQuote candidate;
          if (rate.from == from && rate.to == to) {
            candidate = RateQuote(rate, inverse: false);
          } else if (rate.from == to && rate.to == from) {
            candidate = RateQuote(rate, inverse: true);
          } else {
            continue;
          }
          if (best == null || compare(candidate, best) > 0) best = candidate;
        }
        return best;
      });

  /// [minor] of [from] in [to], rounded to hundredths; null without a rate.
  int? convert(int minor, String from, String to) {
    if (from == to) return minor;
    return quote(from, to)?.convert(minor);
  }

  int? toBase(int minor, String currency) =>
      convert(minor, currency, baseCurrency);
}

/// A sum in the base currency and the pairs (`USD→RUB`) that had no rate, so
/// their amounts are left out (the client shows «нет курса C→B»).
class BaseAmount {
  const BaseAmount(this.minor, this.missingRates);
  final int minor;
  final Set<String> missingRates;
  bool get isComplete => missingRates.isEmpty;
}

/// Transactions with amounts converted to the base currency; those without
/// a rate are left out and listed in [missingRates].
class BaseTransactions {
  const BaseTransactions(this.items, this.missingRates);
  final List<TransactionRecord> items;
  final Set<String> missingRates;
}

/// Accounts, transfers and currencies. Results equal the v1 rules of
/// [FinanceMath] when everything is in one currency and there are no
/// transfers.
class LedgerMath {
  /// The currency an amount of [item] is in: its own, else its account's,
  /// else the base currency.
  static String transactionCurrency(
    TransactionRecord item,
    Map<String, AccountRecord> accounts,
    String baseCurrency,
  ) => item.currency ?? accounts[item.accountId]?.currency ?? baseCurrency;

  /// An account's currency; a deleted or unknown account counts as base.
  static String accountCurrency(
    String? accountId,
    Map<String, AccountRecord> accounts,
    String baseCurrency,
  ) => accounts[accountId]?.currency ?? baseCurrency;

  /// Balance of every referenced account in its own currency: income −
  /// expenses with that `accountId` (adjustments included), plus `toAmount`
  /// of incoming and minus `amount` of outgoing transfers. Ids of deleted
  /// accounts are included too («Удалённый счёт»).
  static Map<String, int> accountBalances(
    Iterable<TransactionRecord> transactions,
    Iterable<TransferRecord> transfers,
  ) {
    final result = <String, int>{};
    for (final item in transactions) {
      final account = item.accountId;
      if (account == null) continue;
      result[account] = (result[account] ?? 0) + item.signedMinor;
    }
    for (final transfer in transfers) {
      result[transfer.fromAccountId] =
          (result[transfer.fromAccountId] ?? 0) - transfer.amountMinor;
      result[transfer.toAccountId] =
          (result[transfer.toAccountId] ?? 0) + transfer.toAmountMinor;
    }
    return result;
  }

  /// «Без счёта»: transactions without an account, by their currency.
  static Map<String, int> unassignedBalances(
    Iterable<TransactionRecord> transactions,
    String baseCurrency,
  ) {
    final result = <String, int>{};
    for (final item in transactions) {
      if (item.accountId != null) continue;
      final currency = item.currency ?? baseCurrency;
      result[currency] = (result[currency] ?? 0) + item.signedMinor;
    }
    return result;
  }

  /// Every transaction and both sides of every transfer in the base
  /// currency. With a single currency transfers cancel out and the result is
  /// [FinanceMath.totalBalance].
  static BaseAmount totalBalance({
    required Iterable<TransactionRecord> transactions,
    Iterable<TransferRecord> transfers = const [],
    Map<String, AccountRecord> accounts = const {},
    required CurrencyConverter converter,
  }) {
    final base = converter.baseCurrency;
    final missing = <String>{};
    var total = 0;
    void add(int signedMinor, String currency) {
      final converted = converter.toBase(signedMinor, currency);
      if (converted == null) {
        missing.add('$currency→$base');
      } else {
        total += converted;
      }
    }

    for (final item in transactions) {
      add(item.signedMinor, transactionCurrency(item, accounts, base));
    }
    for (final transfer in transfers) {
      add(
        transfer.toAmountMinor,
        accountCurrency(transfer.toAccountId, accounts, base),
      );
      add(
        -transfer.amountMinor,
        accountCurrency(transfer.fromAccountId, accounts, base),
      );
    }
    return BaseAmount(total, missing);
  }

  /// Transactions for analytics and budgets: amounts in the base currency,
  /// currency set to the base. A transaction already in the base currency is
  /// passed through as the same object, so v1 data gives v1 results.
  static BaseTransactions inBase({
    required Iterable<TransactionRecord> transactions,
    Map<String, AccountRecord> accounts = const {},
    required CurrencyConverter converter,
  }) {
    final base = converter.baseCurrency;
    final missing = <String>{};
    final items = <TransactionRecord>[];
    for (final item in transactions) {
      final currency = transactionCurrency(item, accounts, base);
      if (currency == base) {
        items.add(item);
        continue;
      }
      final converted = converter.toBase(item.amountMinor, currency);
      if (converted == null) {
        missing.add('$currency→$base');
        continue;
      }
      items.add(item.copyWith(amountMinor: converted, currency: base));
    }
    return BaseTransactions(items, missing);
  }

  /// Goal progress in the goal's terms: the balance of its account when
  /// set, otherwise the saved amount.
  static int goalProgress(GoalRecord goal, Map<String, int> accountBalances) =>
      goal.accountId == null
      ? goal.savedMinor
      : accountBalances[goal.accountId] ?? 0;

  /// What is left to save for [goal], never below zero.
  static int goalRemaining(GoalRecord goal, Map<String, int> accountBalances) {
    final left = goal.targetMinor - goalProgress(goal, accountBalances);
    return left > 0 ? left : 0;
  }
}
