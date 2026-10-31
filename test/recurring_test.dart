import 'package:balance_flutter/domain/records.dart';
import 'package:balance_flutter/domain/recurring.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final created = DateTime.utc(2026);

  RecurringRecord rule({
    String id = 'rule',
    String frequency = 'monthly',
    int interval = 1,
    required DateTime start,
    DateTime? end,
    String? through,
    bool paused = false,
  }) => RecurringRecord(
    id: id,
    amountMinor: 99000,
    categoryName: 'Подписки',
    startDate: start,
    updatedAt: created,
    frequencyRawValue: frequency,
    interval: interval,
    endDate: end,
    generatedThrough: through,
    isPaused: paused,
    accountId: 'card',
    currency: 'RUB',
    tags: const ['Связь'],
    note: 'Связь',
  );

  List<String> days(RecurringRecord r, DateTime now, {int? limit}) => [
    for (final o in RecurringEngine.due(
      r,
      now,
      limit: limit ?? RecurringEngine.maxPerRun,
    ))
      o.occurrence,
  ];

  test('transaction id is UUID v5 of recurring:<id>:<occurrence>', () {
    // Reference values from Python's uuid.uuid5.
    expect(
      RecurringEngine.transactionId(
        '3f0c1c2e-0000-4000-8000-000000000001',
        '2026-01-31',
      ),
      'f1ee2a08-9d03-5bf5-aa65-fd7546457667',
    );
    expect(
      RecurringEngine.transactionId('ABC', '2026-02-28'),
      '5c174f58-ea08-5035-b784-a12588b3c31f',
    );
  });

  test('daily and weekly with intervals', () {
    final start = DateTime.utc(2026, 1, 30, 9);
    expect(
      days(
        rule(frequency: 'daily', interval: 2, start: start),
        DateTime.utc(2026, 2, 5),
      ),
      ['2026-01-30', '2026-02-01', '2026-02-03', '2026-02-05'],
    );
    expect(
      days(rule(frequency: 'weekly', start: start), DateTime.utc(2026, 2, 20)),
      ['2026-01-30', '2026-02-06', '2026-02-13', '2026-02-20'],
    );
    expect(
      days(
        rule(frequency: 'weekly', interval: 2, start: start),
        DateTime.utc(2026, 2, 27),
      ),
      ['2026-01-30', '2026-02-13', '2026-02-27'],
    );
  });

  test('monthly keeps the start day, clamping to the month end', () {
    final r = rule(start: DateTime.utc(2026, 1, 31, 9, 30));
    expect(days(r, DateTime.utc(2026, 6, 1)), [
      '2026-01-31',
      '2026-02-28',
      '2026-03-31',
      '2026-04-30',
      '2026-05-31',
    ]);
    expect(
      days(
        rule(start: DateTime.utc(2024, 1, 31), interval: 1),
        DateTime.utc(2024, 3, 1),
      ),
      ['2024-01-31', '2024-02-29'],
    );
    expect(
      days(
        rule(start: DateTime.utc(2026, 11, 15), interval: 3),
        DateTime.utc(2027, 9, 1),
      ),
      ['2026-11-15', '2027-02-15', '2027-05-15', '2027-08-15'],
    );
  });

  test('yearly: 29 February becomes 28 February', () {
    expect(
      days(
        rule(frequency: 'yearly', start: DateTime.utc(2024, 2, 29)),
        DateTime.utc(2028, 3, 1),
      ),
      ['2024-02-29', '2025-02-28', '2026-02-28', '2027-02-28', '2028-02-29'],
    );
  });

  test('occurrence date carries the start time of day in UTC', () {
    final occurrences = RecurringEngine.due(
      rule(start: DateTime.parse('2026-01-05T09:15:30+03:00')),
      DateTime.utc(2026, 2, 5),
    );
    expect(occurrences.map((o) => o.date), [
      DateTime.utc(2026, 1, 5, 6, 15, 30),
      DateTime.utc(2026, 2, 5, 6, 15, 30),
    ]);
    final tx = occurrences.last.toTransaction(created);
    expect(tx.id, RecurringEngine.transactionId('rule', '2026-02-05'));
    expect(tx.recurringId, 'rule');
    expect(tx.occurrence, '2026-02-05');
    expect(tx.amountMinor, 99000);
    expect(tx.accountId, 'card');
    expect(tx.currency, 'RUB');
    expect(tx.tags, ['Связь']);
    expect(tx.categoryName, 'Подписки');
  });

  test('today counts by UTC date, whatever the time of day', () {
    final r = rule(start: DateTime.utc(2026, 1, 5, 23));
    expect(days(r, DateTime.utc(2026, 2, 5)), ['2026-01-05', '2026-02-05']);
    expect(days(r, DateTime.utc(2026, 2, 4, 23, 59)), ['2026-01-05']);
    // 2026-02-05 00:30 in Moscow is still 2026-02-04 in UTC.
    expect(days(r, DateTime.parse('2026-02-05T00:30:00+03:00')), [
      '2026-01-05',
    ]);
  });

  test('window starts after generatedThrough; endDate is inclusive', () {
    final start = DateTime.utc(2026, 1, 5, 9);
    expect(
      days(rule(start: start, through: '2026-03-05'), DateTime.utc(2026, 6, 1)),
      ['2026-04-05', '2026-05-05'],
    );
    expect(
      days(rule(start: start, through: '2026-03-04'), DateTime.utc(2026, 4, 1)),
      ['2026-03-05'],
    );
    expect(
      days(
        rule(start: start, end: DateTime.utc(2026, 3, 5)),
        DateTime.utc(2026, 12, 1),
      ),
      ['2026-01-05', '2026-02-05', '2026-03-05'],
    );
    expect(days(rule(start: start), DateTime.utc(2026, 1, 4)), isEmpty);
  });

  test('paused, unknown frequency or interval below 1 create nothing', () {
    final start = DateTime.utc(2026, 1, 5);
    final now = DateTime.utc(2026, 6, 1);
    expect(days(rule(start: start, paused: true), now), isEmpty);
    expect(days(rule(start: start, frequency: 'hourly'), now), isEmpty);
    expect(days(rule(start: start, interval: 0), now), isEmpty);
  });

  test('at most 366 occurrences per run, resumable', () {
    final r = rule(frequency: 'daily', start: DateTime.utc(2020, 1, 1));
    final now = DateTime.utc(2026, 1, 1);
    final first = days(r, now);
    expect(first, hasLength(366));
    expect(first.first, '2020-01-01');
    expect(first.last, '2020-12-31');
    final next = days(r.copyWith(generatedThrough: first.last), now);
    expect(next.first, '2021-01-01');
  });

  test('a long-running rule is not walked from its start', () {
    final r = rule(
      frequency: 'daily',
      start: DateTime.utc(1970, 1, 1),
      through: '2026-10-29',
    );
    expect(days(r, DateTime.utc(2026, 10, 31)), ['2026-10-30', '2026-10-31']);
    final monthly = rule(
      start: DateTime.utc(1990, 1, 31),
      through: '2026-09-30',
    );
    expect(days(monthly, DateTime.utc(2026, 12, 1)), [
      '2026-10-31',
      '2026-11-30',
    ]);
  });
}
