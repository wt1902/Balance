import 'dart:convert';

import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wire payloads round-trip through JSON in real use.
Map<String, dynamic> wire(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

void main() {
  final at = DateTime.utc(2026, 10, 31, 12);

  group('transaction v2 fields', () {
    test('a v1 record keeps exactly its v1 payload', () {
      final record = TransactionRecord(
        id: 'a',
        amountMinor: 12345,
        date: at,
        categoryName: 'Еда',
        updatedAt: at,
      );
      expect(record.payload().keys.toSet(), {
        'amount',
        'date',
        'note',
        'categoryName',
        'categoryIcon',
        'categoryEmoji',
        'categoryColorName',
        'isBalanceAdjustment',
        'kindRawValue',
      });
    });

    test('new fields round-trip and default when absent', () {
      final payload = wire({
        'amount': 990.0,
        'date': '2026-01-05T09:00:00.000Z',
        'categoryName': 'Подписки',
        'kindRawValue': 'expense',
        'accountId': 'acc',
        'currency': 'eur',
        'tags': [' Дом ', 'дом', '', 'x' * 33, 'Работа'],
        'recurringId': 'rule',
        'occurrence': '2026-01-05',
      });
      final record = TransactionRecord.fromPayload(
        id: 'id',
        updatedAt: at,
        payload: payload,
      );
      expect(record.accountId, 'acc');
      expect(record.currency, 'EUR');
      expect(record.tags, ['Дом', 'Работа']);
      expect(record.recurringId, 'rule');
      expect(record.occurrence, '2026-01-05');
      final again = TransactionRecord.fromJson(wire(record.toJson()));
      expect(again.payload(), record.payload());
      expect(again.amountMinor, 99000);

      final plain = TransactionRecord.fromPayload(
        id: 'p',
        updatedAt: at,
        payload: wire({
          'amount': 1,
          'date': '2026-01-05T09:00:00Z',
          'categoryName': 'Еда',
        }),
      );
      expect(plain.accountId, isNull);
      expect(plain.currency, isNull);
      expect(plain.tags, isEmpty);
    });

    test('copyWith can clear nullable fields', () {
      final record = TransactionRecord(
        id: 'a',
        amountMinor: 1,
        date: at,
        categoryName: 'Еда',
        updatedAt: at,
        accountId: 'acc',
        currency: 'USD',
      );
      expect(record.copyWith(note: 'x').accountId, 'acc');
      expect(record.copyWith(accountId: null).accountId, isNull);
      expect(record.copyWith(currency: null).currency, isNull);
    });

    test('an invalid currency code is rejected', () {
      expect(
        () => TransactionRecord.fromPayload(
          id: 'a',
          updatedAt: at,
          payload: {
            'amount': 1,
            'date': '2026-01-05T09:00:00Z',
            'categoryName': 'Еда',
            'currency': 'RUBLE',
          },
        ),
        throwsFormatException,
      );
    });
  });

  group('unknown payload fields survive a save (§0.2)', () {
    final future = {
      'futureFlag': true,
      'futureNested': {
        'a': [1, 2],
      },
    };
    final samples = <String, Map<String, dynamic>>{
      'transaction': {
        'amount': 10.5,
        'date': '2026-01-01T00:00:00.000Z',
        'categoryName': 'Еда',
      },
      'category': {'name': 'Еда', 'createdAt': '2026-01-01T00:00:00.000Z'},
      'budget': {
        'categoryName': 'Еда',
        'limit': 100,
        'monthStart': '2026-01-01T00:00:00.000Z',
      },
      'account': {'name': 'Карта', 'kindRawValue': 'card', 'currency': 'RUB'},
      'transfer': {
        'fromAccountId': 'a',
        'toAccountId': 'b',
        'amount': 1000.0,
        'toAmount': 10.5,
        'date': '2026-01-01T00:00:00.000Z',
      },
      'recurring': {
        'amount': 990.0,
        'categoryName': 'Подписки',
        'frequency': 'monthly',
        'interval': 1,
        'startDate': '2026-01-05T09:00:00.000Z',
        'mode': 'auto',
        'generatedThrough': '2026-02-05',
      },
      'goal': {'name': 'Отпуск', 'target': 150000.0, 'saved': 20000.0},
      'debt': {
        'person': 'Иван',
        'direction': 'owedToMe',
        'amount': 5000.0,
        'date': '2026-01-01T00:00:00.000Z',
        'repaid': 1000.0,
      },
      'rate': {
        'from': 'USD',
        'to': 'RUB',
        'rate': '92.35',
        'date': '2026-10-31T00:00:00.000Z',
      },
      'setting': {'value': 'EUR'},
      'attachment': {
        'transactionId': 't',
        'sha256': 'a' * 64,
        'contentType': 'image/jpeg',
        'size': 182345,
        'name': 'чек.jpg',
        'createdAt': '2026-01-01T00:00:00.000Z',
      },
    };

    test('every entity has a sample', () {
      expect(samples.keys.toSet(), entityCodecs.keys.toSet());
    });

    for (final entry in samples.entries) {
      test(entry.key, () {
        final codec = entityCodecs[entry.key]!;
        final record = codec.fromPayload(
          id: 'id',
          updatedAt: at,
          payload: wire({...entry.value, ...future}),
        );
        final payload = wire(record.payload());
        expect(payload['futureFlag'], true);
        expect(payload['futureNested'], future['futureNested']);
        // Restamped (as a save does) and through the local snapshot.
        final saved = record.stamped(at.add(const Duration(days: 1)));
        final local = codec.fromJson(wire(saved.toJson()));
        expect(local.updatedAt, at.add(const Duration(days: 1)));
        expect(wire(local.payload()), payload);
        // Local keys never leak into the wire payload.
        expect(payload.keys, isNot(contains('id')));
        expect(payload.keys, isNot(contains('updatedAt')));
        expect(payload.keys, isNot(contains('amountMinor')));
        expect(payload.keys, isNot(contains('limitMinor')));
      });
    }

    test('known fields win over stale extras after an edit', () {
      final record = AccountRecord.fromPayload(
        id: 'a',
        updatedAt: at,
        payload: {'name': 'Old', 'other': 1},
      );
      final edited = record.copyWith(name: 'New');
      expect(edited.payload()['name'], 'New');
      expect(edited.payload()['other'], 1);
    });
  });

  group('entity defaults', () {
    test('account: unknown kind reads as other, raw value kept', () {
      final account = AccountRecord.fromPayload(
        id: 'a',
        updatedAt: at,
        payload: {'name': 'Брокер', 'kindRawValue': 'brokerage'},
      );
      expect(account.kind, AccountKind.other);
      expect(account.payload()['kindRawValue'], 'brokerage');
      expect(account.currency, isNull);
      expect(account.createdAt, at);
      expect(account.isArchived, isFalse);
    });

    test('transfer: toAmount defaults to amount', () {
      final transfer = TransferRecord.fromPayload(
        id: 't',
        updatedAt: at,
        payload: {
          'fromAccountId': 'a',
          'toAccountId': 'b',
          'amount': 12.34,
          'date': '2026-01-01T00:00:00Z',
        },
      );
      expect(transfer.amountMinor, 1234);
      expect(transfer.toAmountMinor, 1234);
      expect(transfer.payload()['toAmount'], 12.34);
    });

    test('recurring: defaults and validated generatedThrough', () {
      final rule = RecurringRecord.fromPayload(
        id: 'r',
        updatedAt: at,
        payload: {
          'amount': 1,
          'categoryName': 'Еда',
          'startDate': '2026-01-01T00:00:00Z',
        },
      );
      expect(rule.frequency, RecurrenceFrequency.monthly);
      expect(rule.interval, 1);
      expect(rule.mode, RecurringMode.auto);
      expect(rule.isPaused, isFalse);
      expect(rule.generatedThrough, isNull);
      expect(rule.payload()['endDate'], isNull);
      expect(
        () => RecurringRecord.fromPayload(
          id: 'r',
          updatedAt: at,
          payload: {
            'amount': 1,
            'categoryName': 'Еда',
            'startDate': '2026-01-01T00:00:00Z',
            'generatedThrough': '2026-02-30',
          },
        ),
        throwsFormatException,
      );
      final future = rule.copyWith(frequencyRawValue: 'hourly');
      expect(future.frequency, isNull);
    });

    test('debt: remaining is amount minus repaid', () {
      final debt = DebtRecord.fromPayload(
        id: 'd',
        updatedAt: at,
        payload: {
          'person': 'Иван',
          'direction': 'iOwe',
          'amount': 5000.0,
          'repaid': 1000.5,
          'date': '2026-01-01T00:00:00Z',
        },
      );
      expect(debt.direction, DebtDirection.iOwe);
      expect(debt.remainingMinor, 399950);
    });

    test('attachment: sha256 must be 64 hex characters', () {
      Map<String, dynamic> payload(String sha) => {
        'transactionId': 't',
        'sha256': sha,
        'contentType': 'image/png',
        'size': 1,
      };
      expect(
        AttachmentRecord.fromPayload(
          id: 'a',
          updatedAt: at,
          payload: payload('AB' * 32),
        ).sha256,
        'ab' * 32,
      );
      expect(
        () => AttachmentRecord.fromPayload(
          id: 'a',
          updatedAt: at,
          payload: payload('xyz'),
        ),
        throwsFormatException,
      );
    });
  });

  group('rates are exact decimal strings', () {
    test('parses up to six fractional digits', () {
      expect(RateRecord.parseRateMicros('92.35'), BigInt.from(92350000));
      expect(RateRecord.parseRateMicros('0.000001'), BigInt.one);
      expect(RateRecord.parseRateMicros('1'), BigInt.from(1000000));
      for (final invalid in [
        '0',
        '0.0',
        '-1',
        '1e3',
        '1,5',
        '1.1234567',
        '',
        '.5',
      ]) {
        expect(
          () => RateRecord.parseRateMicros(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    });

    test('the wire value stays a string', () {
      final rate = RateRecord.fromPayload(
        id: 'r',
        updatedAt: at,
        payload: {
          'from': 'usd',
          'to': 'RUB',
          'rate': '92.350000',
          'date': '2026-10-31T00:00:00Z',
        },
      );
      expect(rate.from, 'USD');
      expect(rate.payload()['rate'], '92.350000');
    });
  });

  group('tags (§6)', () {
    test('normalize trims, deduplicates case-insensitively, caps at 10', () {
      expect(
        TagRules.normalize([
          ' a ',
          'A',
          'b',
          '',
          'b ',
          for (var i = 0; i < 20; i++) 't$i',
        ]),
        ['a', 'b', 't0', 't1', 't2', 't3', 't4', 't5', 't6', 't7'],
      );
      expect(TagRules.normalize(['x' * 32, 'y' * 33]), ['x' * 32]);
    });

    test('validate rejects long tags and more than 10', () {
      expect(TagRules.validate([' Дом ', 'дом']), ['Дом']);
      expect(() => TagRules.validate(['x' * 33]), throwsArgumentError);
      expect(
        () => TagRules.validate([for (var i = 0; i < 11; i++) 't$i']),
        throwsArgumentError,
      );
    });
  });

  test('isoDay and parseIsoDay use the UTC calendar', () {
    expect(isoDay(DateTime.utc(2026, 3, 1, 23, 59)), '2026-03-01');
    expect(parseIsoDay('2024-02-29'), DateTime.utc(2024, 2, 29));
    expect(() => parseIsoDay('2026-1-01'), throwsFormatException);
    expect(() => parseIsoDay('2025-02-29'), throwsFormatException);
  });

  test('CSV export carries v2 fields', () {
    final csv = FinanceMath.exportCsv([
      TransactionRecord(
        id: 'a',
        amountMinor: 100,
        date: at,
        categoryName: 'Еда',
        updatedAt: at,
        accountId: 'acc',
        currency: 'EUR',
        tags: const ['Дом', 'a,b'],
        recurringId: 'rule',
        occurrence: '2026-10-31',
      ),
    ]);
    expect(
      csv,
      contains('"acc","EUR","[""Дом"",""a,b""]","rule","2026-10-31"'),
    );
  });
}
