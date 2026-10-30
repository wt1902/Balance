import 'dart:convert';

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
  final date = DateTime.utc(2026, 1);
  TransactionRecord transaction(String id) => TransactionRecord(
    id: id,
    amountMinor: 12345,
    date: date,
    categoryName: 'Еда',
    updatedAt: date,
  );

  test('durable restart keeps edits and deletion tombstones', () async {
    final storage = MemorySnapshotStorage();
    final store = AppStore(storage: storage);
    await store.initialize();
    await store.saveTransaction(transaction('keep'));
    await store.saveTransaction(transaction('delete'));
    await store.deleteTransaction('delete');
    final reopened = AppStore(storage: storage);
    await reopened.initialize();
    expect(reopened.transactions.single.id, 'keep');
    expect(reopened.transactions.single.amountMinor, 12345);
    expect(reopened.pendingChangeCount, 2);
    expect(storage.values.values.single['tombstones'], hasLength(1));
    reopened.dispose();
    store.dispose();
  });

  test(
    'category rename cascades to transactions and budgets in one snapshot',
    () async {
      final storage = MemorySnapshotStorage();
      final store = AppStore(storage: storage);
      await store.initialize();
      final category = CategoryRecord(
        id: 'cat',
        name: 'Еда',
        icon: 'cart.fill',
        colorName: 'orange',
        createdAt: date,
        updatedAt: date,
      );
      await store.saveCategory(category);
      await store.saveTransaction(transaction('tx'));
      await store.saveBudget(
        BudgetRecord(
          id: 'budget',
          categoryName: 'Еда',
          limitMinor: 10000,
          monthStart: date,
          updatedAt: date,
        ),
      );
      await store.saveCategory(
        category.copyWith(name: 'Продукты', emoji: '🍏'),
      );
      expect(store.transactions.single.categoryName, 'Продукты');
      expect(store.budgets.single.categoryName, 'Продукты');
      expect(store.transactions.single.categoryEmoji, '🍏');
      expect(store.pendingChangeCount, 3);
      store.dispose();
    },
  );

  test(
    'pending delete survives newer remote edit and is queued with newer timestamp',
    () async {
      final storage = MemorySnapshotStorage();
      final remoteTime = DateTime.now().toUtc().add(const Duration(seconds: 2));
      var serveConflict = false;
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        if (request.url.path.endsWith('/login')) {
          return http.Response(
            jsonEncode({
              'accessToken': 'access',
              'refreshToken': 'refresh',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
              'user': {'id': 'user', 'email': 'test@example.com'},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final conflict = serveConflict && body['pull'] == true;
        return http.Response(
          jsonEncode({
            'cursor': conflict ? 1 : body['cursor'],
            'hasMore': false,
            'serverTime': DateTime.now().toUtc().toIso8601String(),
            'changes': conflict
                ? [
                    {
                      'entity': 'transaction',
                      'id': 'tx',
                      'deleted': false,
                      'updatedAt': remoteTime.toIso8601String(),
                      'sequence': 1,
                      'payload': transaction('tx').payload(),
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
        apiFactory: (server) => SyncApi(serverUrl: server, client: client),
      );
      await store.initialize();
      await store.setServerUrl('https://balance.example.com');
      await store.signIn('test@example.com', 'password');
      await store.saveTransaction(transaction('tx'));
      await store.deleteTransaction('tx');
      serveConflict = true;
      await store.sync();
      expect(store.transactions, isEmpty);
      expect(store.pendingChangeCount, 1);
      expect(store.cursor, 1);
      final saved = storage.values['https://balance.example.com|user']!;
      final pending = (saved['dirty'] as List).single as Map;
      expect(pending['deleted'], true);
      expect(
        DateTime.parse(pending['updatedAt'] as String).isAfter(remoteTime),
        true,
      );
      store.dispose();
      client.close();
    },
  );
  test(
    'expense category deletion removes budgets and preserves history',
    () async {
      final store = AppStore(storage: MemorySnapshotStorage());
      await store.initialize();
      await store.saveCategory(
        CategoryRecord(
          id: 'cat',
          name: 'Еда',
          icon: 'cart.fill',
          colorName: 'orange',
          createdAt: date,
          updatedAt: date,
        ),
      );
      await store.saveTransaction(transaction('tx'));
      await store.saveBudget(
        BudgetRecord(
          id: 'budget',
          categoryName: 'Еда',
          limitMinor: 10000,
          monthStart: date,
          updatedAt: date,
        ),
      );
      await store.deleteCategory('cat');
      expect(store.categories, isEmpty);
      expect(store.budgets, isEmpty);
      expect(store.transactions, hasLength(1));
      expect(store.pendingChangeCount, 3);
      store.dispose();
    },
  );

  test(
    'failed pull commit preserves old cursor and dirty local changes',
    () async {
      final storage = FailingStorage();
      var includeRemote = false;
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
        final pull = body['pull'] == true && includeRemote;
        return http.Response(
          jsonEncode({
            'cursor': pull ? 1 : body['cursor'],
            'hasMore': false,
            'serverTime': DateTime.now().toUtc().toIso8601String(),
            'changes': pull
                ? [
                    {
                      'entity': 'transaction',
                      'id': 'remote',
                      'deleted': false,
                      'updatedAt': DateTime.now().toUtc().toIso8601String(),
                      'sequence': 1,
                      'payload': transaction('remote').payload(),
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
      await store.saveTransaction(transaction('local'));
      includeRemote = true;
      storage.failPage = true;
      await expectLater(store.sync(), throwsStateError);
      expect(store.cursor, 0);
      expect(store.transactions.map((e) => e.id), ['local']);
      expect(store.pendingChangeCount, 1);
      expect(storage.values['https://example.com|u']!['cursor'], 0);
      storage.failPage = false;
      await store.sync();
      expect(store.cursor, 1);
      expect(store.transactions, hasLength(2));
      expect(store.pendingChangeCount, 0);
      store.dispose();
      client.close();
    },
  );

  test(
    'first account imports guest once; accounts and servers stay isolated',
    () async {
      final storage = MemorySnapshotStorage();
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
              'user': {'id': body['email'], 'email': body['email']},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path.endsWith('/logout')) {
          return http.Response('{}', 200);
        }
        return http.Response(
          jsonEncode({
            'cursor': body['cursor'],
            'changes': [],
            'hasMore': false,
            'serverTime': DateTime.now().toUtc().toIso8601String(),
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
      await store.setServerUrl('https://one.example.com');
      await store.saveTransaction(transaction('guest'));
      await store.signIn('one@example.com', 'password');
      expect(store.transactions.single.id, 'guest');
      await store.signOut();
      await store.signIn('two@example.com', 'password');
      expect(store.transactions, isEmpty);
      await store.saveTransaction(transaction('second'));
      await store.setServerUrl('https://two.example.com');
      expect(store.session, isNull);
      expect(store.cursor, 0);
      expect(store.transactions, isEmpty);
      await store.setServerUrl('https://one.example.com');
      await store.signIn('two@example.com', 'password');
      expect(store.transactions.single.id, 'second');
      store.dispose();
      client.close();
    },
  );
  test(
    'two stores reload latest ledger before writing instead of clobbering it',
    () async {
      final storage = MemorySnapshotStorage();
      final first = AppStore(storage: storage, background: true);
      final second = AppStore(storage: storage, background: true);
      await first.initialize();
      await second.initialize();
      await first.saveTransaction(transaction('one'));
      await second.saveTransaction(transaction('two'));
      await first.saveTransaction(transaction('three'));
      expect(first.transactions.map((t) => t.id).toSet(), {
        'one',
        'two',
        'three',
      });
      await second.sync();
      expect(second.transactions, hasLength(3));
      await first.close();
      await second.close();
      first.dispose();
      second.dispose();
    },
  );

  test(
    'headless initialization skips automatic sync and reloads another engine logout',
    () async {
      final storage = MemorySnapshotStorage();
      var syncRequests = 0;
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
          );
        }
        if (request.url.path.endsWith('/logout')) {
          return http.Response('{}', 200);
        }
        syncRequests++;
        return http.Response(
          jsonEncode({
            'cursor': body['cursor'],
            'changes': [],
            'hasMore': false,
            'serverTime': DateTime.now().toUtc().toIso8601String(),
          }),
          200,
        );
      });
      final first = AppStore(
        storage: storage,
        background: true,
        apiFactory: (url) => SyncApi(serverUrl: url, client: client),
      );
      await first.initialize();
      await first.setServerUrl('https://example.com');
      await first.signIn('u@example.com', 'password');
      await first.saveTransaction(transaction('private'));
      final countBeforeInitialize = syncRequests;
      final second = AppStore(
        storage: storage,
        background: true,
        apiFactory: (url) => SyncApi(serverUrl: url, client: client),
      );
      await second.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(syncRequests, countBeforeInitialize);
      expect(second.transactions.single.id, 'private');
      await first.signOut();
      await second.sync();
      expect(second.session, isNull);
      expect(second.transactions, isEmpty);
      expect(syncRequests, countBeforeInitialize);
      await first.close();
      await second.close();
      first.dispose();
      second.dispose();
      client.close();
    },
  );
  test(
    'second engine reloads rotated refresh session instead of reusing old token',
    () async {
      const server = 'https://example.com';
      Map<String, dynamic> sessionData(String suffix, DateTime expiry) => {
        'accessToken': 'access-$suffix',
        'refreshToken': 'refresh-$suffix',
        'expiresAt': expiry.toUtc().toIso8601String(),
        'user': {'id': 'u', 'email': 'u@example.com'},
      };
      SharedPreferences.setMockInitialValues({'serverUrl': server});
      FlutterSecureStorage.setMockInitialValues({
        'balance.session.${Uri.encodeComponent(server)}': jsonEncode(
          sessionData('old', DateTime.now().subtract(const Duration(hours: 1))),
        ),
      });
      var refreshes = 0;
      final authorization = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        if (request.url.path.endsWith('/refresh')) {
          refreshes++;
          expect(body['refreshToken'], 'refresh-old');
          return http.Response(
            jsonEncode(
              sessionData('new', DateTime.now().add(const Duration(hours: 1))),
            ),
            200,
          );
        }
        authorization.add(request.headers['authorization']!);
        return http.Response(
          jsonEncode({
            'cursor': body['cursor'],
            'changes': [],
            'hasMore': false,
            'serverTime': DateTime.now().toUtc().toIso8601String(),
          }),
          200,
        );
      });
      final storage = MemorySnapshotStorage();
      final first = AppStore(
        storage: storage,
        background: true,
        apiFactory: (url) => SyncApi(serverUrl: url, client: client),
      );
      final second = AppStore(
        storage: storage,
        background: true,
        apiFactory: (url) => SyncApi(serverUrl: url, client: client),
      );
      await first.initialize();
      await second.initialize();
      await first.sync();
      await second.sync();
      expect(refreshes, 1);
      expect(authorization, ['Bearer access-new', 'Bearer access-new']);
      expect(second.session!.refreshToken, 'refresh-new');
      await first.close();
      await second.close();
      first.dispose();
      second.dispose();
      client.close();
    },
  );
  test(
    'invalid server URL preserves the active account and its ledger',
    () async {
      final url = 'https://good.example';
      SharedPreferences.setMockInitialValues({'serverUrl': url});
      final credentials = {
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
        'user': {'id': 'account', 'email': 'a@example.com'},
      };
      FlutterSecureStorage.setMockInitialValues({
        'balance.session.${Uri.encodeComponent(url)}': jsonEncode(credentials),
      });
      final store = AppStore(
        storage: MemorySnapshotStorage(),
        background: true,
      );
      await store.initialize();
      await store.saveTransaction(transaction('preserved'));
      for (final invalid in [
        'http://remote.example',
        'https://name:secret@remote.example',
        'https://remote.example?x=1',
        'https://remote.example#fragment',
        '/relative',
      ]) {
        await expectLater(store.setServerUrl(invalid), throwsArgumentError);
        expect(store.serverUrl, url);
        expect(store.session!.userId, 'account');
        expect(store.transactions.single.id, 'preserved');
      }
      await store.close();
      store.dispose();
    },
  );
}

class FailingStorage extends MemorySnapshotStorage {
  bool failPage = false;
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (failPage && value['cursor'] == 1) throw StateError('Disk full');
    await super.write(key, value);
  }
}
