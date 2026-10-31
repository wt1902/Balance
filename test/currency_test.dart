import 'package:balance_flutter/domain/currency.dart';
import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = DateTime.utc(2026, 10, 15, 12);

  RateRecord rate(
    String from,
    String to,
    String value, {
    DateTime? date,
    DateTime? updatedAt,
    String? id,
  }) => RateRecord(
    id: id ?? '$from$to$value',
    from: from,
    to: to,
    rate: value,
    date: date ?? day,
    updatedAt: updatedAt ?? day,
  );

  TransactionRecord tx(
    String id,
    int minor, {
    bool income = false,
    String? currency,
    String? accountId,
    bool adjustment = false,
    DateTime? date,
    String category = 'Еда',
  }) => TransactionRecord(
    id: id,
    amountMinor: minor,
    date: date ?? day,
    categoryName: category,
    updatedAt: day,
    kindRawValue: income ? 'income' : 'expense',
    currency: currency,
    accountId: accountId,
    isBalanceAdjustment: adjustment,
  );

  AccountRecord account(String id, {String? currency}) => AccountRecord(
    id: id,
    name: id,
    createdAt: day,
    updatedAt: day,
    currency: currency,
  );

  group('conversion (§2)', () {
    test('same currency passes through without a rate', () {
      final converter = CurrencyConverter(baseCurrency: 'RUB');
      expect(converter.toBase(12345, 'RUB'), 12345);
      expect(converter.toBase(1, 'USD'), isNull);
    });

    test('direct rate multiplies and rounds half up away from zero', () {
      final converter = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [rate('USD', 'RUB', '92.35')],
      );
      expect(converter.toBase(100, 'USD'), 9235);
      // 0.01 USD * 92.35 = 0.9235 RUB -> 0.92
      expect(converter.toBase(1, 'USD'), 92);
      // 0.03 * 92.35 = 2.7705 -> 2.77; exact half: 0.5 cents
      final half = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [rate('USD', 'RUB', '1.5')],
      );
      expect(half.toBase(1, 'USD'), 2); // 1.5 -> 2
      expect(half.toBase(-1, 'USD'), -2); // -1.5 -> -2 (away from zero)
      expect(half.toBase(3, 'USD'), 5); // 4.5 -> 5
    });

    test('reverse rate divides', () {
      final converter = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [rate('RUB', 'USD', '0.01')],
      );
      expect(converter.toBase(100, 'USD'), 10000);
      final third = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [rate('RUB', 'EUR', '3')],
      );
      expect(third.toBase(100, 'EUR'), 33); // 33.33… -> 33
      expect(third.toBase(200, 'EUR'), 67); // 66.66… -> 67
    });

    test('no double accumulation for large amounts', () {
      final converter = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [rate('USD', 'RUB', '92.123457')],
      );
      // The product in micro-units exceeds 2^53; the result does not.
      expect(converter.toBase(1000000000001, 'USD'), 92123457000092);
    });

    test('latest by date, then direct before reverse, then updatedAt', () {
      final later = day.add(const Duration(days: 1));
      final converter = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [
          rate('USD', 'RUB', '90', date: day),
          rate('RUB', 'USD', '0.01', date: later),
          rate('USD', 'RUB', '95', date: later, id: 'old'),
          rate('USD', 'RUB', '96', date: later, id: 'new', updatedAt: later),
        ],
      );
      final quote = converter.quote('USD', 'RUB')!;
      expect(quote.inverse, isFalse);
      expect(quote.record.id, 'new');
      expect(converter.toBase(100, 'USD'), 9600);

      final reverseOnlyLater = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [
          rate('USD', 'RUB', '90', date: day),
          rate('RUB', 'USD', '0.01', date: later),
        ],
      );
      expect(reverseOnlyLater.toBase(100, 'USD'), 10000);

      final reverseNewerUpdate = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [
          rate('USD', 'RUB', '90', date: day),
          rate('RUB', 'USD', '0.01', date: day, updatedAt: later),
        ],
      );
      // Same date: the direct pair wins although the reverse is newer.
      expect(reverseNewerUpdate.toBase(100, 'USD'), 9000);
    });

    test('a rate dated after the calculation date is not used yet', () {
      final converter = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [
          rate('USD', 'RUB', '90', date: day),
          rate('USD', 'RUB', '100', date: day.add(const Duration(days: 2))),
        ],
        asOf: day.add(const Duration(days: 1)),
      );
      expect(converter.toBase(100, 'USD'), 9000);
    });
  });

  group('balances (§3)', () {
    test('account balance: income − expenses ± transfers', () {
      final balances = LedgerMath.accountBalances(
        [
          tx('1', 10000, income: true, accountId: 'card'),
          tx('2', 2500, accountId: 'card'),
          tx('3', 700, accountId: 'card', adjustment: true, income: true),
          tx('4', 100),
        ],
        [
          TransferRecord(
            id: 't',
            fromAccountId: 'card',
            toAccountId: 'usd',
            amountMinor: 9235,
            toAmountMinor: 100,
            date: day,
            updatedAt: day,
          ),
        ],
      );
      expect(balances, {'card': 10000 - 2500 + 700 - 9235, 'usd': 100});
    });

    test('unassigned balances by currency', () {
      expect(
        LedgerMath.unassignedBalances([
          tx('1', 1000, income: true),
          tx('2', 300, currency: 'USD', income: true),
          tx('3', 200, accountId: 'card'),
        ], 'RUB'),
        {'RUB': 1000, 'USD': 300},
      );
    });

    test('total balance converts every transaction and transfer side', () {
      final accounts = {
        'rub': account('rub'),
        'usd': account('usd', currency: 'USD'),
      };
      final converter = CurrencyConverter(
        baseCurrency: 'RUB',
        rates: [rate('USD', 'RUB', '90')],
      );
      final total = LedgerMath.totalBalance(
        transactions: [
          tx('1', 100000, income: true, accountId: 'rub'),
          tx('2', 1000, income: true, accountId: 'usd'), // 10 USD
          tx('3', 500, currency: 'USD'), // -5 USD without account
          tx('4', 100, currency: 'EUR', income: true), // no rate
        ],
        transfers: [
          TransferRecord(
            id: 't',
            fromAccountId: 'rub',
            toAccountId: 'usd',
            amountMinor: 9000,
            toAmountMinor: 100,
            date: day,
            updatedAt: day,
          ),
        ],
        accounts: accounts,
        converter: converter,
      );
      // 1000 + 900 - 450 + (+90 - 90)
      expect(total.minor, 145000);
      expect(total.missingRates, {'EUR→RUB'});
      expect(total.isComplete, isFalse);
    });

    test('single-currency transfers cancel out; v1 balance unchanged', () {
      final items = [
        tx('1', 10000, income: true, accountId: 'a'),
        tx('2', 2500, accountId: 'b'),
        tx('3', 4000, adjustment: true),
        tx('4', 999, date: DateTime.utc(2030)),
      ];
      final total = LedgerMath.totalBalance(
        transactions: items,
        transfers: [
          TransferRecord(
            id: 't',
            fromAccountId: 'a',
            toAccountId: 'b',
            amountMinor: 3000,
            date: day,
            updatedAt: day,
          ),
        ],
        accounts: {'a': account('a'), 'b': account('b')},
        converter: CurrencyConverter(baseCurrency: 'RUB'),
      );
      expect(total.minor, FinanceMath.totalBalance(items));
      expect(total.isComplete, isTrue);
    });

    test('a deleted account counts in the base currency', () {
      final total = LedgerMath.totalBalance(
        transactions: [tx('1', 500, income: true, accountId: 'gone')],
        converter: CurrencyConverter(baseCurrency: 'RUB'),
      );
      expect(total.minor, 500);
      expect(
        LedgerMath.accountBalances([
          tx('1', 500, income: true, accountId: 'gone'),
        ], const []),
        {'gone': 500},
      );
    });
  });

  group('analytics in the base currency', () {
    final start = DateTime.utc(2026, 10);
    final end = DateTime.utc(2026, 11);

    test('one currency: same objects, identical v1 results', () {
      final items = [
        tx('1', 10000, income: true),
        tx('2', 2500, category: 'Еда'),
        tx('3', 1500, category: 'Дом', accountId: 'a'),
        tx('4', 4000, adjustment: true),
      ];
      final converted = LedgerMath.inBase(
        transactions: items,
        accounts: {'a': account('a')},
        converter: CurrencyConverter(baseCurrency: 'RUB'),
      );
      for (var i = 0; i < items.length; i++) {
        expect(identical(converted.items[i], items[i]), isTrue);
      }
      final v1 = FinanceMath.summary(items, start, end);
      final v2 = FinanceMath.summary(converted.items, start, end);
      expect(v2.incomeMinor, v1.incomeMinor);
      expect(v2.expensesMinor, v1.expensesMinor);
      expect(
        FinanceMath.spending(
          converted.items,
          start,
          end,
        ).map((c) => c.amountMinor),
        FinanceMath.spending(items, start, end).map((c) => c.amountMinor),
      );
    });

    test('foreign amounts are converted, missing rates left out', () {
      final converted = LedgerMath.inBase(
        transactions: [
          tx('1', 1000, currency: 'USD'),
          tx('2', 1000, accountId: 'eur'),
          tx('3', 500),
        ],
        accounts: {'eur': account('eur', currency: 'EUR')},
        converter: CurrencyConverter(
          baseCurrency: 'RUB',
          rates: [rate('USD', 'RUB', '90')],
        ),
      );
      expect(converted.items.map((t) => t.amountMinor), [90000, 500]);
      expect(converted.items.first.currency, 'RUB');
      expect(converted.missingRates, {'EUR→RUB'});
      final budget = BudgetRecord(
        id: 'b',
        categoryName: 'Еда',
        limitMinor: 100000,
        monthStart: DateTime(2026, 10),
        updatedAt: day,
      );
      expect(FinanceMath.budgetUsed(budget, converted.items), 90500);
    });
  });

  test('goal progress: account balance when linked, else saved', () {
    final goal = GoalRecord(
      id: 'g',
      name: 'Отпуск',
      targetMinor: 15000000,
      savedMinor: 2000000,
      createdAt: day,
      updatedAt: day,
    );
    expect(LedgerMath.goalProgress(goal, {'a': 5}), 2000000);
    expect(LedgerMath.goalProgress(goal.copyWith(accountId: 'a'), {'a': 5}), 5);
    expect(
      LedgerMath.goalProgress(goal.copyWith(accountId: 'gone'), {'a': 5}),
      0,
    );
  });
}
