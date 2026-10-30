import 'dart:convert';

import 'package:balance_flutter/domain/backup.dart';
import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/services/sync_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  final date = DateTime.utc(2026, 1, 10);
  TransactionRecord transaction(String id, {DateTime? updatedAt}) =>
      TransactionRecord(
        id: id,
        amountMinor: 12345,
        date: date,
        categoryName: 'Еда',
        updatedAt: updatedAt ?? date,
      );
  // Backups and snapshots round-trip through JSON in real use.
  Object? json(Object? value) => jsonDecode(jsonEncode(value));

  Future<AppStore> open(MemorySnapshotStorage storage) async {
    final store = AppStore(storage: storage);
    await store.initialize();
    return store;
  }

  group('backup', () {
    test('restores every record kind into an empty device', () async {
      final source = await open(MemorySnapshotStorage());
      await source.saveCategory(
        CategoryRecord(
          id: 'cat',
          name: 'Еда',
          icon: 'cart.fill',
          emoji: '🍔',
          colorName: 'orange',
          createdAt: date,
          updatedAt: date,
        ),
      );
      await source.saveTransaction(transaction('tx'));
      await source.adjustBalance(-20000);
      await source.saveBudget(
        BudgetRecord(
          id: 'budget',
          categoryName: 'Еда',
          limitMinor: 50000,
          monthStart: DateTime(2026, 1),
          updatedAt: date,
        ),
      );
      await source.saveTransaction(transaction('gone'));
      await source.deleteTransaction('gone');
      final backup = json(await source.exportBackup());

      final target = await open(MemorySnapshotStorage());
      final result = await target.restoreBackup(backup);
      expect(result.added, 4);
      // The deletion has no local record to remove.
      expect(result.skipped, 1);
      expect(result.invalid, 0);
      expect(target.categories.single.emoji, '🍔');
      expect(target.budgets.single.limitMinor, 50000);
      final adjustment = target.transactions.firstWhere(
        (t) => t.isBalanceAdjustment,
      );
      expect(adjustment.kind, TransactionKind.expense);
      expect(target.balanceMinor, source.balanceMinor);
      expect(target.pendingChangeCount, 4);
      source.dispose();
      target.dispose();
    });

    test('merges by updatedAt and applies newer deletions', () async {
      final storage = MemorySnapshotStorage();
      final store = await open(storage);
      await store.saveTransaction(transaction('newer-here'));
      await store.saveTransaction(transaction('older-here'));
      await store.saveTransaction(transaction('deleted-later'));
      final later = DateTime.now().toUtc().add(const Duration(days: 1));
      final backup = {
        'format': backupFormat,
        'version': backupVersion,
        'data': {
          'transactions': [
            transaction(
              'newer-here',
              updatedAt: DateTime.utc(2020),
            ).copyWith(amountMinor: 1).toJson(),
            transaction(
              'older-here',
              updatedAt: later,
            ).copyWith(amountMinor: 777).toJson(),
            {'id': 'broken'},
            'not an object',
          ],
          'tombstones': [
            {
              'entity': 'transaction',
              'id': 'deleted-later',
              'deleted': true,
              'updatedAt': later.toIso8601String(),
            },
          ],
        },
      };
      final result = await store.restoreBackup(json(backup));
      expect(result.updated, 1);
      expect(result.deleted, 1);
      expect(result.skipped, 1);
      expect(result.invalid, 2);
      final byId = {for (final t in store.transactions) t.id: t};
      expect(byId['newer-here']!.amountMinor, 12345);
      expect(byId['older-here']!.amountMinor, 777);
      expect(byId.containsKey('deleted-later'), isFalse);
      // A second restore of the same file changes nothing.
      final again = await store.restoreBackup(json(backup));
      expect(again.changed, 0);
      final reopened = await open(storage);
      expect(
        reopened.transactions.map((t) => t.id),
        isNot(contains('deleted-later')),
      );
      store.dispose();
      reopened.dispose();
    });

    test('rejects foreign files and newer formats', () async {
      final store = await open(MemorySnapshotStorage());
      await expectLater(
        store.restoreBackup({'transactions': []}),
        throwsFormatException,
      );
      await expectLater(
        store.restoreBackup({
          'format': backupFormat,
          'version': backupVersion + 1,
          'data': {},
        }),
        throwsFormatException,
      );
      store.dispose();
    });

    test('skips a category that would duplicate a local name', () async {
      final store = await open(MemorySnapshotStorage());
      CategoryRecord category(String id) => CategoryRecord(
        id: id,
        name: 'Кафе',
        icon: 'cup.and.saucer.fill',
        colorName: 'brown',
        createdAt: date,
        updatedAt: date,
      );
      await store.saveCategory(category('local'));
      final result = await store.restoreBackup(
        json({
          'format': backupFormat,
          'version': backupVersion,
          'data': {
            'categories': [category('other').toJson()],
          },
        }),
      );
      expect(result.skipped, 1);
      expect(store.categories.single.id, 'local');
      store.dispose();
    });
  });

  group('quarantine', () {
    test('damaged local records are set aside and startup continues', () async {
      final storage = MemorySnapshotStorage();
      final store = await open(storage);
      await store.saveTransaction(transaction('good'));
      store.dispose();
      final key = storage.values.keys.single;
      final snapshot = json(storage.values[key]) as Map<String, dynamic>;
      (snapshot['transactions'] as List).add({'id': 'bad', 'amount': 'many'});
      (snapshot['dirty'] as List).add({'entity': 'spaceship', 'id': 'x'});
      snapshot['budgets'] = 'not a list';
      storage.values[key] = snapshot;

      final reopened = await open(storage);
      expect(reopened.transactions.map((t) => t.id), ['good']);
      expect(reopened.pendingChangeCount, 1);
      expect(reopened.quarantine, hasLength(3));
      expect(
        reopened.quarantine.map((e) => e.section),
        containsAll(['transactions', 'dirty', 'budgets']),
      );
      expect(reopened.quarantine.first.source, 'local');
      expect(reopened.error, contains('Повреждённые записи отложены: 3'));
      // The cleaned snapshot is durable and the copy is not duplicated.
      expect(storage.values[key]!['transactions'], hasLength(1));
      final third = await open(storage);
      expect(third.quarantine, hasLength(3));
      expect(third.error, isNull);
      final report = json(third.quarantineReport()) as Map;
      expect((report['items'] as List).first['raw'], isNotNull);
      await third.clearQuarantine();
      expect(third.quarantine, isEmpty);
      final fourth = await open(storage);
      expect(fourth.quarantine, isEmpty);
      for (final s in [reopened, third, fourth]) {
        s.dispose();
      }
    });

    test('unreadable pulled change is skipped and sync continues', () async {
      final storage = MemorySnapshotStorage();
      final now = DateTime.now().toUtc().toIso8601String();
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        if (request.url.path.endsWith('/login')) {
          return http.Response(
            jsonEncode({
              'accessToken': 'a',
              'refreshToken': 'r',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
              'user': {'id': 'u', 'email': 'u@example.com'},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final pull = body['pull'] == true && body['cursor'] == 0;
        return http.Response(
          jsonEncode({
            'cursor': pull ? 2 : body['cursor'],
            'hasMore': false,
            'serverTime': now,
            'changes': pull
                ? [
                    {
                      'entity': 'transaction',
                      'id': 'broken',
                      'deleted': false,
                      'updatedAt': now,
                      'sequence': 1,
                      'payload': {'amount': 'NaN', 'date': 'yesterday'},
                    },
                    {
                      'entity': 'transaction',
                      'id': 'fine',
                      'deleted': false,
                      'updatedAt': now,
                      'sequence': 2,
                      'payload': transaction('fine').payload(),
                    },
                  ]
                : [],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final store = AppStore(
        storage: storage,
        apiFactory: (url) => SyncApi(serverUrl: url, client: client),
      );
      await store.initialize();
      await store.setServerUrl('https://example.com');
      await store.signIn('u@example.com', 'password');
      expect(store.cursor, 2);
      expect(store.transactions.map((t) => t.id), ['fine']);
      expect(store.quarantine.single.source, 'server');
      expect(store.quarantine.single.recordId, 'broken');
      expect(store.syncMessage, contains('Пропущено записей с ошибками: 1'));
      expect(store.error, isNull);
      store.dispose();
      client.close();
    });
  });

  test('statement import adds new ids once and respects deletions', () async {
    final store = await open(MemorySnapshotStorage());
    expect(
      await store.importTransactions([transaction('a'), transaction('b')]),
      2,
    );
    await store.deleteTransaction('b');
    expect(store.knowsTransaction('b'), isTrue);
    expect(
      await store.importTransactions([
        transaction('a'),
        transaction('b'),
        transaction('c'),
      ]),
      1,
    );
    expect(store.transactions.map((t) => t.id).toSet(), {'a', 'c'});
    store.dispose();
  });
}
