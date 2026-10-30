import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/notifications.dart';
import 'package:balance_flutter/services/notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSink implements NotificationSink {
  bool permission = true;
  final shown = <(int, String, String, String)>[];
  final scheduled = <(int, DateTime, String)>[];
  final cancelled = <int>[];
  @override
  Future<void> initialize(void Function(String payload) onTap) async {}
  @override
  Future<String?> launchPayload() async => null;
  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<void> show(int id, String title, String body, String payload) async =>
      shown.add((id, title, body, payload));
  @override
  Future<void> scheduleDaily(
    int id,
    String title,
    String body,
    DateTime first,
    String payload,
  ) async => scheduled.add((id, first, payload));
  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 15, 12);
  BudgetRecord budget(String id, int limit, {DateTime? month}) => BudgetRecord(
    id: id,
    categoryName: id == 'food' ? 'Продукты' : 'Транспорт',
    limitMinor: limit,
    monthStart: month ?? DateTime(2026, 10),
    updatedAt: now,
  );
  TransactionRecord spend(
    String id,
    int amount, {
    String category = 'Продукты',
    DateTime? date,
    bool adjustment = false,
  }) => TransactionRecord(
    id: id,
    amountMinor: amount,
    date: date ?? DateTime(2026, 10, 10),
    categoryName: category,
    isBalanceAdjustment: adjustment,
    updatedAt: now,
  );

  group('rules', () {
    test('80% then 100% per budget and month, adjustments excluded', () {
      final budgets = [
        budget('food', 10000),
        budget('transport', 10000),
        budget('old', 100, month: DateTime(2026, 9)),
      ];
      List<BudgetAlert> alerts(
        List<TransactionRecord> items, [
        Map<String, int> notified = const {},
      ]) => NotificationRules.budgetAlerts(budgets, items, now, notified);

      expect(alerts([spend('a', 7900)]), isEmpty);
      final eighty = alerts([spend('a', 8000)]);
      expect(eighty.single.threshold, 80);
      expect(eighty.single.percent, 80);
      expect(
        eighty.single.body('октябрь'),
        'Израсходовано 80% лимита на октябрь',
      );
      final key = NotificationRules.budgetKey(budgets.first);
      expect(key, 'food|2026-10');
      expect(alerts([spend('a', 9000)], {key: 80}), isEmpty);
      final over = alerts([spend('a', 12000)], {key: 80});
      expect(over.single.threshold, 100);
      expect(
        over.single.body('октябрь'),
        contains('превышен: израсходовано 120%'),
      );
      // Adjustments are not spending.
      expect(alerts([spend('adj', 50000, adjustment: true)]), isEmpty);
      // Another category or month does not count.
      expect(alerts([spend('t', 9000, category: 'Кафе')]), isEmpty);
      expect(alerts([spend('s', 9000, date: DateTime(2026, 9, 20))]), isEmpty);
    });

    test('next reminder: today if still ahead and nothing entered', () {
      expect(
        NotificationRules.nextReminder(now, 20, 0, enteredToday: false),
        DateTime(2026, 10, 15, 20),
      );
      expect(
        NotificationRules.nextReminder(now, 20, 0, enteredToday: true),
        DateTime(2026, 10, 16, 20),
      );
      expect(
        NotificationRules.nextReminder(now, 9, 30, enteredToday: false),
        DateTime(2026, 10, 16, 9, 30),
      );
      // Month end rolls over.
      expect(
        NotificationRules.nextReminder(
          DateTime(2026, 10, 31, 21),
          20,
          0,
          enteredToday: false,
        ),
        DateTime(2026, 11, 1, 20),
      );
      expect(
        NotificationRules.hasEntryToday([spend('x', 1, date: now)], now),
        isTrue,
      );
      expect(
        NotificationRules.hasEntryToday([
          spend('x', 1, date: now, adjustment: true),
          spend('y', 1, date: DateTime(2026, 10, 14, 23)),
        ], now),
        isFalse,
      );
    });
  });

  group('service', () {
    late FakeSink sink;
    late Notifications service;
    var clock = now;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      clock = now;
      sink = FakeSink();
      service = Notifications(sink: sink, clock: () => clock);
      await service.initialize();
    });

    test(
      'alerts are opt-in, start silent and fire once per threshold',
      () async {
        final budgets = [budget('food', 10000)];
        // Off: nothing is shown.
        await service.ledgerChanged(
          budgets: budgets,
          transactions: [spend('a', 9000)],
        );
        expect(sink.shown, isEmpty);
        // Turning on while already at 90% records it without a notification.
        await service.setBudgetAlerts(
          true,
          budgets: budgets,
          transactions: [spend('a', 9000)],
        );
        await service.ledgerChanged(
          budgets: budgets,
          transactions: [spend('a', 9000)],
        );
        expect(sink.shown, isEmpty);
        // Crossing 100% notifies once, without amounts.
        final over = [spend('a', 9000), spend('b', 2000)];
        await service.ledgerChanged(budgets: budgets, transactions: over);
        await service.ledgerChanged(budgets: budgets, transactions: over);
        expect(sink.shown, hasLength(1));
        expect(sink.shown.single.$2, 'Бюджет «Продукты»');
        expect(
          sink.shown.single.$3,
          'Лимит на октябрь превышен: израсходовано 110%',
        );
        expect(sink.shown.single.$3, isNot(contains('₽')));
        expect(sink.shown.single.$4, 'budget');
        // A new month starts afresh.
        clock = DateTime(2026, 11, 3, 12);
        await service.ledgerChanged(
          budgets: [budget('food', 10000, month: DateTime(2026, 11))],
          transactions: [spend('n', 8500, date: DateTime(2026, 11, 2))],
        );
        expect(sink.shown, hasLength(2));
        expect(sink.shown.last.$3, 'Израсходовано 85% лимита на ноябрь');
      },
    );

    test('state survives a restart and another engine', () async {
      final budgets = [budget('food', 10000)];
      await service.setBudgetAlerts(true, budgets: budgets, transactions: []);
      await service.ledgerChanged(
        budgets: budgets,
        transactions: [spend('a', 8000)],
      );
      expect(sink.shown, hasLength(1));
      final background = Notifications(sink: sink, clock: () => clock);
      await background.initialize();
      await background.ledgerChanged(
        budgets: budgets,
        transactions: [spend('a', 8000)],
      );
      expect(sink.shown, hasLength(1));
    });

    test('permission denied keeps notifications off', () async {
      sink.permission = false;
      await expectLater(
        service.setBudgetAlerts(true, budgets: [], transactions: []),
        throwsA(isA<NotificationException>()),
      );
      await expectLater(
        service.setReminder(true, transactions: []),
        throwsA(isA<NotificationException>()),
      );
      expect(service.budgetAlerts, isFalse);
      expect(service.reminder, isFalse);
      expect(sink.scheduled, isEmpty);
    });

    test('reminder moves to tomorrow once something is entered', () async {
      await service.setReminder(true, transactions: []);
      expect(sink.scheduled.single.$2, DateTime(2026, 10, 15, 20));
      expect(sink.scheduled.single.$3, 'reminder');
      await service.ledgerChanged(
        budgets: [],
        transactions: [spend('t', 100, date: now)],
      );
      expect(sink.cancelled, contains(Notifications.reminderId));
      expect(sink.scheduled.last.$2, DateTime(2026, 10, 16, 20));
      await service.setReminderTime(7, 45, transactions: []);
      expect(sink.scheduled.last.$2, DateTime(2026, 10, 16, 7, 45));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notify.reminderTime'), '07:45');
      final cancels = sink.cancelled.length;
      await service.setReminder(false, transactions: []);
      expect(sink.cancelled.length, cancels + 1);
      expect(service.reminder, isFalse);
    });
  });
}
