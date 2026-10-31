import 'dart:convert';
import 'dart:typed_data';

import 'package:balance_flutter/domain/backup.dart';
import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/domain/records.dart';
import 'package:balance_flutter/domain/recurring.dart';
import 'package:balance_flutter/domain/statement_import.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/attachment_cache.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/services/sync_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_balance_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  // Fixed calendar: tests never depend on the current date.
  final today = DateTime.utc(2026, 3, 10, 12);
  final day = DateTime.utc(2026, 3, 1);
  Object? json(Object? value) => jsonDecode(jsonEncode(value));

  Future<AppStore> open(
    MemorySnapshotStorage storage, {
    FakeBalanceServer? server,
    AttachmentCache? cache,
    DateTime Function()? clock,
  }) async {
    final store = AppStore(
      storage: storage,
      apiFactory: server == null
          ? null
          : (url) => SyncApi(serverUrl: url, client: server.client),
      attachmentCache: cache,
      clock: clock ?? () => today,
      background: true,
    );
    await store.initialize();
    return store;
  }

  Future<AppStore> signedIn(
    FakeBalanceServer server, {
    MemorySnapshotStorage? storage,
    AttachmentCache? cache,
    DateTime Function()? clock,
  }) async {
    final store = await open(
      storage ?? MemorySnapshotStorage(),
      server: server,
      cache: cache,
      clock: clock,
    );
    await store.setServerUrl('https://balance.example.com');
    await store.signIn('user@example.com', 'password');
    return store;
  }

  TransactionRecord tx(
    String id, {
    int minor = 1000,
    bool income = false,
    String? accountId,
    String? currency,
    List<String> tags = const [],
  }) => TransactionRecord(
    id: id,
    amountMinor: minor,
    date: day,
    categoryName: 'Еда',
    updatedAt: day,
    kindRawValue: income ? 'income' : 'expense',
    accountId: accountId,
    currency: currency,
    tags: tags,
  );

  AccountRecord account(String id, {String? currency}) => AccountRecord(
    id: id,
    name: 'Счёт $id',
    createdAt: day,
    updatedAt: day,
    currency: currency,
  );

  RecurringRecord rule(
    String id, {
    String mode = 'auto',
    DateTime? start,
    String? through,
  }) => RecurringRecord(
    id: id,
    amountMinor: 99000,
    categoryName: 'Подписки',
    startDate: start ?? DateTime.utc(2026, 1, 5, 9),
    updatedAt: day,
    modeRawValue: mode,
    generatedThrough: through,
  );

  group('CRUD, tombstones and restart', () {
    test('every v2 entity survives a restart; deletions are queued', () async {
      final storage = MemorySnapshotStorage();
      final store = await open(storage);
      await store.saveAccount(account('a'));
      await store.saveAccount(account('b', currency: 'USD'));
      await store.saveTransfer(
        TransferRecord(
          id: 'tr',
          fromAccountId: 'a',
          toAccountId: 'b',
          amountMinor: 9000,
          toAmountMinor: 100,
          date: day,
          updatedAt: day,
        ),
      );
      await store.saveGoal(
        GoalRecord(
          id: 'g',
          name: ' Отпуск ',
          targetMinor: 100000,
          createdAt: day,
          updatedAt: day,
        ),
      );
      await store.saveDebt(
        DebtRecord(
          id: 'd',
          person: 'Иван',
          amountMinor: 5000,
          date: day,
          updatedAt: day,
        ),
      );
      await store.saveRate(
        RateRecord(
          id: 'r',
          from: 'USD',
          to: 'RUB',
          rate: '90',
          date: day,
          updatedAt: day,
        ),
      );
      await store.saveRecurring(rule('rc', mode: 'remind'));
      await store.setBaseCurrency('rub');
      await store.deleteDebt('d');

      final reopened = await open(storage);
      expect(reopened.accounts.map((a) => a.id), ['a', 'b']);
      expect(reopened.transfers.single.toAmountMinor, 100);
      expect(reopened.goals.single.name, 'Отпуск');
      expect(reopened.debts, isEmpty);
      expect(reopened.rates.single.rateMicros, BigInt.from(90000000));
      expect(reopened.recurring.single.id, 'rc');
      expect(reopened.baseCurrency, 'RUB');
      expect(reopened.pendingChangeCount, 8);
      final snapshot = storage.values.values.firstWhere(
        (v) => v.containsKey('tombstones'),
      );
      expect(
        (snapshot['tombstones'] as List).single,
        containsPair('entity', 'debt'),
      );
      reopened.dispose();
      store.dispose();
    });

    test('validation rejects invalid records', () async {
      final store = await open(MemorySnapshotStorage());
      await expectLater(
        store.saveTransfer(
          TransferRecord(
            id: 't',
            fromAccountId: 'a',
            toAccountId: 'a',
            amountMinor: 1,
            date: day,
            updatedAt: day,
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.saveTransaction(tx('x', tags: ['y' * 33])),
        throwsArgumentError,
      );
      await expectLater(
        store.saveRate(
          RateRecord(
            id: 'r',
            from: 'RUB',
            to: 'RUB',
            rate: '1',
            date: day,
            updatedAt: day,
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.saveAccount(account('a').copyWith(name: '  ')),
        throwsArgumentError,
      );
      await expectLater(store.setBaseCurrency('рубль'), throwsArgumentError);
      await store.saveTransaction(tx('t', tags: [' Дом ', 'дом', 'Работа']));
      expect(store.transactions.single.tags, ['Дом', 'Работа']);
      expect(store.pendingChangeCount, 1);
      store.dispose();
    });

    test('deleting a transaction deletes its attachments', () async {
      final store = await open(MemorySnapshotStorage());
      await store.saveTransaction(tx('t'));
      final attachment = await store.addAttachment(
        transactionId: 't',
        bytes: Uint8List.fromList([1, 2, 3]),
        contentType: 'image/png',
        name: 'чек.png',
      );
      expect(store.attachmentsFor('t').single.id, attachment.id);
      expect(store.isUploadPending(attachment), isTrue);
      await store.deleteTransaction('t');
      expect(store.attachmentsFor('t'), isEmpty);
      expect(store.isUploadPending(attachment), isFalse);
      final backup = await store.exportBackup();
      final tombstones = (backup['data'] as Map)['tombstones'] as List;
      expect(tombstones.map((t) => (t as Map)['entity']).toSet(), {
        'transaction',
        'attachment',
      });
      store.dispose();
    });
  });

  group('balances and currencies', () {
    test('one currency and no accounts: v1 balance', () async {
      final store = await open(MemorySnapshotStorage());
      await store.saveTransaction(tx('1', minor: 10000, income: true));
      await store.saveTransaction(tx('2', minor: 2500));
      expect(store.balanceMinor, 7500);
      expect(store.balanceMinor, FinanceMath.totalBalance(store.transactions));
      expect(store.baseTransactions.items, store.transactions);
      expect(store.missingRates, isEmpty);
      store.dispose();
    });

    test('accounts, transfers, rates and the base currency setting', () async {
      final store = await open(MemorySnapshotStorage());
      // Explicit: an account without a currency follows the base currency.
      await store.saveAccount(account('rub', currency: 'RUB'));
      await store.saveAccount(account('usd', currency: 'USD'));
      await store.saveTransaction(
        tx('1', minor: 100000, income: true, accountId: 'rub'),
      );
      await store.saveTransaction(tx('2', minor: 2000, accountId: 'usd'));
      await store.saveTransfer(
        TransferRecord(
          id: 'tr',
          fromAccountId: 'rub',
          toAccountId: 'usd',
          amountMinor: 18000,
          toAmountMinor: 200,
          date: day,
          updatedAt: day,
        ),
      );
      expect(store.accountBalances, {'rub': 82000, 'usd': -1800});
      expect(store.missingRates, {'USD→RUB'});
      // Without a rate the USD amounts are left out.
      expect(store.balanceMinor, 100000 - 18000);
      await store.saveRate(
        RateRecord(
          id: 'r',
          from: 'USD',
          to: 'RUB',
          rate: '90',
          date: day,
          updatedAt: day,
        ),
      );
      expect(store.missingRates, isEmpty);
      expect(store.balanceMinor, 100000 - 180000 - 18000 + 18000);
      expect(
        store.baseTransactions.items.firstWhere((t) => t.id == '2').amountMinor,
        180000,
      );
      // A rate dated after the clock is not used yet.
      await store.saveRate(
        RateRecord(
          id: 'future',
          from: 'USD',
          to: 'RUB',
          rate: '1000',
          date: today.add(const Duration(days: 1)),
          updatedAt: day,
        ),
      );
      expect(store.balanceMinor, -80000);

      await store.setBaseCurrency('USD');
      expect(store.baseCurrency, 'USD');
      expect(store.balanceMinor, 1111 - 2000 - 200 + 200);
      await store.setBaseCurrency(null);
      expect(store.baseCurrency, store.currency);
      store.dispose();
    });

    test('adjustment of one account in its currency', () async {
      final store = await open(MemorySnapshotStorage());
      await store.saveAccount(account('usd', currency: 'USD'));
      await store.saveTransaction(
        tx('1', minor: 500, income: true, accountId: 'usd'),
      );
      await store.adjustBalance(1500, accountId: 'usd');
      expect(store.accountBalances['usd'], 1500);
      final adjustment = store.transactions.firstWhere(
        (t) => t.isBalanceAdjustment,
      );
      expect(adjustment.accountId, 'usd');
      expect(adjustment.currency, isNull);
      expect(adjustment.amountMinor, 1000);
      store.dispose();
    });

    test('goal progress follows its account', () async {
      final store = await open(MemorySnapshotStorage());
      await store.saveAccount(account('save'));
      await store.saveTransaction(
        tx('1', minor: 7000, income: true, accountId: 'save'),
      );
      final goal = GoalRecord(
        id: 'g',
        name: 'Отпуск',
        targetMinor: 100000,
        savedMinor: 100,
        accountId: 'save',
        createdAt: day,
        updatedAt: day,
      );
      await store.saveGoal(goal);
      expect(store.goalProgress(store.goals.single), 7000);
      expect(store.goalProgress(goal.copyWith(accountId: null)), 100);
      store.dispose();
    });
  });

  group('recurring (§4)', () {
    test('auto rule creates due occurrences once, deterministically', () async {
      final storage = MemorySnapshotStorage();
      final store = await open(storage);
      await store.saveRecurring(rule('rc'));
      expect(store.transactions.map((t) => t.occurrence).toList()..sort(), [
        '2026-01-05',
        '2026-02-05',
        '2026-03-05',
      ]);
      expect(
        store.transactions.map((t) => t.id),
        contains(RecurringEngine.transactionId('rc', '2026-03-05')),
      );
      expect(store.recurring.single.generatedThrough, '2026-03-05');
      expect(await store.generateRecurring(), 0);

      // A deleted occurrence is not created again.
      await store.deleteTransaction(
        RecurringEngine.transactionId('rc', '2026-02-05'),
      );
      expect(await store.generateRecurring(), 0);
      // The next month appears when the clock reaches it.
      expect(await store.generateRecurring(now: DateTime.utc(2026, 4, 5)), 1);
      expect(store.transactions, hasLength(3));
      store.dispose();
    });

    test('an unsigned device runs its rules at startup', () async {
      final storage = MemorySnapshotStorage();
      final first = await open(storage, clock: () => DateTime.utc(2026, 1, 6));
      await first.saveRecurring(rule('rc'));
      expect(first.transactions, hasLength(1));
      first.dispose();
      final later = await open(storage);
      expect(later.transactions, hasLength(3));
      later.dispose();
    });

    test('remind rule: pending, confirm and skip', () async {
      final store = await open(MemorySnapshotStorage());
      await store.saveRecurring(rule('rc', mode: 'remind'));
      expect(store.transactions, isEmpty);
      expect(store.pendingRecurring().map((o) => o.occurrence), [
        '2026-01-05',
        '2026-02-05',
        '2026-03-05',
      ]);
      // Recording a later one first keeps the earlier one waiting.
      final saved = await store.confirmRecurring(
        'rc',
        '2026-02-05',
        edit: (t) => t.copyWith(amountMinor: 95000, id: 'ignored'),
      );
      expect(saved.id, RecurringEngine.transactionId('rc', '2026-02-05'));
      expect(saved.amountMinor, 95000);
      expect(store.recurring.single.generatedThrough, isNull);
      expect(store.pendingRecurring().map((o) => o.occurrence), [
        '2026-01-05',
        '2026-03-05',
      ]);
      await store.skipRecurring('rc', '2026-01-05');
      // Skipped January, then the recorded February: through February.
      expect(store.recurring.single.generatedThrough, '2026-02-05');
      expect(store.pendingRecurring().map((o) => o.occurrence), ['2026-03-05']);
      await expectLater(
        store.confirmRecurring('rc', '2026-02-05'),
        throwsArgumentError,
      );
      await store.confirmRecurring('rc', '2026-03-05');
      expect(store.recurring.single.generatedThrough, '2026-03-05');
      expect(store.pendingRecurring(), isEmpty);
      expect(store.transactions, hasLength(2));
      store.dispose();
    });

    test('a category rename updates rules', () async {
      final store = await open(MemorySnapshotStorage());
      final category = CategoryRecord(
        id: 'c',
        name: 'Подписки',
        icon: 'repeat',
        colorName: 'cyan',
        createdAt: day,
        updatedAt: day,
      );
      await store.saveCategory(category);
      await store.saveRecurring(rule('rc', mode: 'remind'));
      await store.saveCategory(category.copyWith(name: 'Сервисы'));
      expect(store.recurring.single.categoryName, 'Сервисы');
      store.dispose();
    });

    test('progress pulled from another device prevents duplicates', () async {
      final server = FakeBalanceServer();
      final store = await signedIn(server);
      server.inject({
        'entity': 'recurring',
        'id': 'rc',
        'deleted': false,
        'updatedAt': '2020-01-01T00:00:00.000Z',
        'payload': rule('rc', through: '2026-03-05').payload(),
      });
      await store.sync();
      expect(store.transactions, isEmpty);
      server.inject({
        'entity': 'recurring',
        'id': 'rc',
        'deleted': false,
        'updatedAt': '2020-01-01T00:00:01.000Z',
        'payload': rule('rc', through: '2026-01-05').payload(),
      });
      await store.sync();
      // February and March are created after the pull and pushed next time.
      expect(store.transactions.map((t) => t.occurrence).toSet(), {
        '2026-02-05',
        '2026-03-05',
      });
      await store.sync();
      expect(
        server.pushed.where((c) => c['entity'] == 'transaction'),
        hasLength(2),
      );
      store.dispose();
    });
  });

  group('sync with capabilities', () {
    test('v2 server receives every entity', () async {
      final server = FakeBalanceServer();
      final store = await signedIn(server);
      await store.saveAccount(account('a'));
      await store.saveTransaction(tx('t', accountId: 'a', tags: ['Дом']));
      await store.setBaseCurrency('EUR');
      await store.sync();
      expect(store.capabilities!.contract, 2);
      expect(store.supportsLedgers, isTrue);
      expect(store.pendingChangeCount, 0);
      expect(server.pushed.map((c) => c['entity']).toSet(), {
        'account',
        'transaction',
        'setting',
      });
      final pushedTx = server.pushed.firstWhere(
        (c) => c['entity'] == 'transaction',
      );
      expect((pushedTx['payload'] as Map)['accountId'], 'a');
      expect((pushedTx['payload'] as Map)['tags'], ['Дом']);
      expect(
        server.pushed.firstWhere((c) => c['entity'] == 'setting')['id'],
        'baseCurrency',
      );
      store.dispose();
    });

    test('v1 server: new entities wait until the server is updated', () async {
      final server = FakeBalanceServer(v2: false);
      final store = await signedIn(server);
      await store.saveAccount(account('a'));
      await store.saveTransaction(tx('t'));
      await store.sync();
      expect(store.capabilities!.contract, 1);
      expect(store.supportsAttachments, isFalse);
      expect(server.pushed.map((c) => c['entity']), ['transaction']);
      expect(store.pendingChangeCount, 1);
      expect(store.syncMessage, 'Синхронизировано');

      server.v2 = true;
      await store.refreshCapabilities(force: true);
      await store.sync();
      expect(server.pushed.map((c) => c['entity']), ['transaction', 'account']);
      expect(store.pendingChangeCount, 0);
      store.dispose();
    });

    test('unknown entities are skipped, unknown fields kept', () async {
      final server = FakeBalanceServer();
      final store = await signedIn(server);
      server.inject({
        'entity': 'wallet',
        'id': 'w',
        'deleted': false,
        'updatedAt': '2026-03-01T00:00:00.000Z',
        'payload': {'anything': 1},
      });
      server.inject({
        'entity': 'account',
        'id': 'a',
        'deleted': false,
        'updatedAt': '2020-01-01T00:00:00.000Z',
        'payload': {
          'name': 'Карта',
          'kindRawValue': 'virtual',
          'futureField': {'x': 1},
        },
      });
      server.inject({
        'entity': 'transaction',
        'id': 't',
        'deleted': false,
        'updatedAt': '2020-01-01T00:00:00.000Z',
        'payload': {
          ...tx('t').payload(),
          'splitParts': [1, 2],
        },
      });
      await store.sync();
      expect(store.cursor, 3);
      expect(store.quarantine, isEmpty);
      expect(store.accounts.single.kind, AccountKind.other);
      await store.saveAccount(store.accounts.single.copyWith(name: 'Новая'));
      await store.saveTransaction(
        store.transactions.single.copyWith(note: 'x'),
      );
      await store.sync();
      final account = server.pushed.lastWhere((c) => c['entity'] == 'account');
      expect(account['payload'], containsPair('futureField', {'x': 1}));
      expect(account['payload'], containsPair('kindRawValue', 'virtual'));
      expect(account['payload'], containsPair('name', 'Новая'));
      final transaction = server.pushed.lastWhere(
        (c) => c['entity'] == 'transaction',
      );
      expect(transaction['payload'], containsPair('splitParts', [1, 2]));
      expect(transaction['payload'], containsPair('note', 'x'));
      store.dispose();
    });

    test('deletions of new entities sync as tombstones', () async {
      final server = FakeBalanceServer();
      final store = await signedIn(server);
      await store.saveGoal(
        GoalRecord(
          id: 'g',
          name: 'Цель',
          targetMinor: 100,
          createdAt: day,
          updatedAt: day,
        ),
      );
      await store.sync();
      await store.deleteGoal('g');
      await store.sync();
      expect(server.pushed.last, containsPair('deleted', true));
      expect(server.pushed.last, containsPair('entity', 'goal'));
      expect(store.goals, isEmpty);
      expect(store.pendingChangeCount, 0);
      store.dispose();
    });
  });

  group('shared ledgers (§7)', () {
    test('each ledger has its own records, cursor and queue', () async {
      final server = FakeBalanceServer();
      final storage = MemorySnapshotStorage();
      final store = await signedIn(server, storage: storage);
      await store.saveTransaction(tx('personal'));
      await store.sync();
      final ledger = await store.createLedger(' Семья ');
      expect(ledger.name, 'Семья');
      expect(store.ledgers.single.isOwner, isTrue);
      await store.refreshLedgers();
      // Members stay in memory across operations; only names are persisted.
      await store.generateRecurring();
      expect(store.ledgers.single.members.single.userId, 'user');
      await store.selectLedger(ledger.id);
      expect(store.activeLedgerId, ledger.id);
      expect(store.transactions, isEmpty);
      expect(store.cursor, 0);
      await store.saveTransaction(tx('shared'));
      await store.sync();
      expect(
        server.requests
            .where((r) => r.url.path == '/v1/sync')
            .last
            .headers[ledgerHeader],
        ledger.id,
      );
      expect(server.log(ledger.id).single['id'], 'shared');
      expect(server.log().single['id'], 'personal');

      // Another engine sees the same choice and data.
      final other = await open(storage, server: server);
      expect(other.activeLedgerId, ledger.id);
      expect(other.transactions.single.id, 'shared');
      other.dispose();

      await store.selectLedger(null);
      expect(store.transactions.single.id, 'personal');
      await store.selectLedger(ledger.id);
      expect(store.transactions.single.id, 'shared');
      store.dispose();
    });

    test('invite, join, leave and lost access', () async {
      final server = FakeBalanceServer();
      final owner = await signedIn(server);
      final ledger = await owner.createLedger('Семья');
      final invite = await owner.createLedgerInvite(ledger.id);
      expect(invite.code, hasLength(10));
      owner.dispose();

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      server.userId = 'member';
      final member = await signedIn(server);
      final joined = await member.joinLedger(invite.code);
      expect(joined.role, 'member');
      expect(member.activeLedgerId, ledger.id);
      // Waits for the sync that joining starts.
      await member.refreshCapabilities();
      await member.leaveLedger(ledger.id);
      expect(member.activeLedgerId, isNull);
      expect(member.ledgers, isEmpty);

      // Removed by the owner meanwhile: sync falls back to the personal ledger.
      server.invites['CODE000000'] = ledger.id;
      await member.joinLedger('CODE000000');
      await member.refreshCapabilities();
      server.syncStatus[ledger.id] = 403;
      await expectLater(member.sync(), throwsA(isA<SyncApiException>()));
      expect(member.activeLedgerId, isNull);
      expect(member.error, contains('Нет доступа'));
      member.dispose();
    });

    test('ledger calls need a server that supports them', () async {
      final server = FakeBalanceServer(v2: false);
      final store = await signedIn(server);
      await store.sync();
      await expectLater(store.createLedger('x'), throwsStateError);
      await expectLater(store.refreshLedgers(), throwsStateError);
      store.dispose();
    });
  });

  group('attachments (§8)', () {
    final bytes = Uint8List.fromList(utf8.encode('receipt bytes'));

    test(
      'bytes are uploaded before the record; others download lazily',
      () async {
        final server = FakeBalanceServer();
        final cache = MemoryAttachmentCache();
        final store = await signedIn(server, cache: cache);
        await store.sync();
        await store.saveTransaction(tx('t'));
        await expectLater(
          store.addAttachment(
            transactionId: 't',
            bytes: bytes,
            contentType: 'image/heic',
          ),
          throwsArgumentError,
        );
        await expectLater(
          store.addAttachment(
            transactionId: 't',
            bytes: Uint8List(2048),
            contentType: 'image/png',
          ),
          throwsArgumentError,
        );
        final attachment = await store.addAttachment(
          transactionId: 't',
          bytes: bytes,
          contentType: 'image/jpeg',
          name: 'чек.jpg',
        );
        await store.sync();
        final order = [
          for (final r in server.requests)
            if (r.method == 'PUT' ||
                (r.url.path == '/v1/sync' &&
                    r.body.contains('"entity":"attachment"')))
              r.method,
        ];
        expect(order, ['PUT', 'POST']);
        expect(store.isUploadPending(attachment), isFalse);
        expect(store.pendingChangeCount, 0);
        expect(server.files[null]!.keys.single, attachment.sha256);

        // Second device: metadata via sync, bytes on first view, then cached.
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final otherCache = MemoryAttachmentCache();
        final other = await signedIn(server, cache: otherCache);
        final pulled = other.attachmentsFor('t').single;
        expect(pulled.name, 'чек.jpg');
        final before = server.requests.length;
        expect(await other.attachmentBytes(pulled), bytes);
        expect(await other.attachmentBytes(pulled), bytes);
        expect(
          server.requests.skip(before).where((r) => r.method == 'GET'),
          hasLength(1),
        );
        expect(otherCache.files.keys, [attachment.sha256]);
        other.dispose();
        store.dispose();
      },
    );

    test(
      'attachment records wait while the server lacks attachments',
      () async {
        final server = FakeBalanceServer(v2: false);
        final store = await signedIn(server);
        await store.saveTransaction(tx('t'));
        final attachment = await store.addAttachment(
          transactionId: 't',
          bytes: bytes,
          contentType: 'application/pdf',
        );
        await store.sync();
        expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
        expect(store.isUploadPending(attachment), isTrue);
        expect(store.pendingChangeCount, 1);
        store.dispose();
      },
    );

    test('a guest attachment is uploaded after the first sign-in', () async {
      final server = FakeBalanceServer();
      final cache = MemoryAttachmentCache();
      final store = await open(
        MemorySnapshotStorage(),
        server: server,
        cache: cache,
      );
      await store.setServerUrl('https://balance.example.com');
      await store.saveTransaction(tx('t'));
      await store.addAttachment(
        transactionId: 't',
        bytes: bytes,
        contentType: 'image/png',
      );
      await store.signIn('user@example.com', 'password');
      expect(server.files[null], hasLength(1));
      expect(server.pushed.map((c) => c['entity']).toSet(), {
        'transaction',
        'attachment',
      });
      store.dispose();
    });

    test('corrupted download is rejected and not cached', () async {
      final server = FakeBalanceServer();
      final cache = MemoryAttachmentCache();
      final store = await signedIn(server, cache: cache);
      final sha = AttachmentCache.hash(bytes);
      server.files[null] = {
        sha: (Uint8List.fromList([9, 9]), 'image/png'),
      };
      server.inject({
        'entity': 'attachment',
        'id': 'att',
        'deleted': false,
        'updatedAt': '2026-03-01T00:00:00.000Z',
        'payload': {
          'transactionId': 't',
          'sha256': sha,
          'contentType': 'image/png',
          'size': bytes.length,
        },
      });
      await store.sync();
      await expectLater(
        store.attachmentBytes(store.attachmentsFor('t').single),
        throwsFormatException,
      );
      expect(cache.files, isEmpty);
      store.dispose();
    });
  });

  group('backup and CSV', () {
    test('backup restores every v2 entity into an empty device', () async {
      final source = await open(MemorySnapshotStorage());
      await source.saveAccount(account('a', currency: 'USD'));
      await source.saveTransaction(
        tx('t', accountId: 'a', currency: 'USD', tags: ['Дом']),
      );
      await source.saveTransfer(
        TransferRecord(
          id: 'tr',
          fromAccountId: 'a',
          toAccountId: 'b',
          amountMinor: 100,
          date: day,
          updatedAt: day,
        ),
      );
      await source.saveRecurring(rule('rc', mode: 'remind'));
      await source.saveGoal(
        GoalRecord(
          id: 'g',
          name: 'Цель',
          targetMinor: 100,
          createdAt: day,
          updatedAt: day,
        ),
      );
      await source.saveDebt(
        DebtRecord(
          id: 'd',
          person: 'Иван',
          amountMinor: 100,
          date: day,
          updatedAt: day,
        ),
      );
      await source.saveRate(
        RateRecord(
          id: 'r',
          from: 'USD',
          to: 'RUB',
          rate: '90.5',
          date: day,
          updatedAt: day,
        ),
      );
      await source.setBaseCurrency('RUB');
      await source.addAttachment(
        transactionId: 't',
        bytes: Uint8List.fromList([1]),
        contentType: 'image/png',
      );
      await source.saveAccount(account('gone'));
      await source.deleteAccount('gone');
      final backup = json(await source.exportBackup()) as Map<String, dynamic>;
      expect(backup['version'], 2);

      final target = await open(MemorySnapshotStorage());
      final plan = await target.previewBackup(backup);
      expect(target.accounts, isEmpty);
      expect(plan.actionable.map((i) => i.entity).toSet(), {
        'account',
        'transaction',
        'transfer',
        'recurring',
        'goal',
        'debt',
        'rate',
        'setting',
        'attachment',
      });
      final result = await target.restoreBackup(backup);
      expect(result.added, 9);
      expect(result.invalid, 0);
      expect(target.accounts.single.currency, 'USD');
      expect(target.transactions.single.tags, ['Дом']);
      expect(target.transactions.single.accountId, 'a');
      expect(target.transfers.single.id, 'tr');
      expect(target.recurring.single.modeRawValue, 'remind');
      expect(target.goals, hasLength(1));
      expect(target.debts, hasLength(1));
      expect(target.rates.single.rate, '90.5');
      expect(target.baseCurrency, 'RUB');
      expect(target.attachmentsFor('t'), hasLength(1));
      expect(
        (json(await target.exportBackup()) as Map)['data'],
        isNot(contains('uploads')),
      );
      // A second restore changes nothing.
      expect((await target.restoreBackup(backup)).changed, 0);
      source.dispose();
      target.dispose();
    });

    test('a version 1 backup still restores', () async {
      final store = await open(MemorySnapshotStorage());
      final result = await store.restoreBackup({
        'format': backupFormat,
        'version': 1,
        'data': {
          'transactions': [json(tx('old').toJson())],
        },
      });
      expect(result.added, 1);
      expect(store.transactions.single.id, 'old');
      store.dispose();
    });

    test('invalid v2 records in a backup are counted, not restored', () async {
      final store = await open(MemorySnapshotStorage());
      final result = await store.restoreBackup({
        'format': backupFormat,
        'version': 2,
        'data': {
          'rates': [
            {
              'id': 'r',
              'updatedAt': '2026-01-01T00:00:00Z',
              'from': 'USD',
              'to': 'USD',
              'rate': '1',
              'date': '2026-01-01T00:00:00Z',
            },
          ],
          'transfers': [
            {'id': 'x', 'updatedAt': '2026-01-01T00:00:00Z'},
          ],
        },
      });
      expect(result.invalid, 2);
      expect(store.rates, isEmpty);
      store.dispose();
    });

    test('CSV export and import keep v2 transaction fields', () async {
      final record = tx(
        'id-1',
        accountId: 'acc',
        currency: 'EUR',
        tags: ['Дом', 'с, запятой'],
      ).copyWith(recurringId: 'rule', occurrence: '2026-03-01');
      final table = StatementImport.parseCsv(
        FinanceMath.exportCsv([record]).substring(1),
      );
      expect(StatementImport.isBalanceExport(table.first), isTrue);
      final row = StatementImport.readBalanceCsv(table).rows.single;
      final restored = StatementImport.toTransaction(row, row.category!);
      expect(restored.id, 'id-1');
      expect(restored.accountId, 'acc');
      expect(restored.currency, 'EUR');
      expect(restored.tags, ['Дом', 'с, запятой']);
      expect(restored.recurringId, 'rule');
      expect(restored.occurrence, '2026-03-01');

      // A file exported before v2 has no such columns and still imports.
      final legacy = [
        FinanceMath.csvHeader,
        [
          '2026-03-01T00:00:00.000Z',
          'Расход',
          'Еда',
          '10.00',
          '',
          'old',
          'expense',
          'circle.fill',
          '',
          'auto',
          '2026-03-01T00:00:00.000Z',
        ],
      ];
      final old = StatementImport.readBalanceCsv(legacy).rows.single;
      expect(old.accountId, isNull);
      expect(old.tags, isEmpty);
    });
  });
}
