// Large-ledger benchmark on a real Sembast file. Not part of `flutter test`
// (it lives outside test/); run it explicitly:
//
//   flutter test tool/benchmark/ledger_benchmark_test.dart
//
// Sizes can be overridden: BALANCE_BENCH_SIZES=1000,10000 flutter test ...
// BALANCE_BENCH_MEMORY=1 uses in-memory storage instead of a Sembast file.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';

import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/app_store.dart';
import 'package:balance_flutter/services/storage.dart';
import 'package:balance_flutter/services/sync_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sizes =
      (Platform.environment['BALANCE_BENCH_SIZES'] ?? '1000,10000,50000')
          .split(',')
          .map(int.parse);

  for (final size in sizes) {
    test('ledger with $size transactions', () async {
      final results = await _run(size);
      final line = results.entries.map((e) => '${e.key}=${e.value}').join('  ');
      // ignore: avoid_print
      print('BENCH n=$size  $line');
    }, timeout: const Timeout(Duration(minutes: 30)));
  }
}

Future<Map<String, String>> _run(int size) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('balance-bench');
  final path = '${dir.path}/balance.sembast';
  // BALANCE_BENCH_MEMORY=1 isolates CPU cost (sync JSON, merging) from disk.
  final SnapshotStorage storage =
      Platform.environment['BALANCE_BENCH_MEMORY'] == '1'
      ? MemorySnapshotStorage()
      : await LedgerStorage.open(
          opener: () => databaseFactoryIo.openDatabase(path),
        );
  final start = DateTime.utc(2024);
  // Seed the guest scope directly, as an existing installation would have it.
  await storage.write('|guest', {
    'transactions': [
      for (var i = 0; i < size; i++)
        TransactionRecord(
          id: 'seed-$i',
          amountMinor: 100 + i % 50000,
          date: start.add(Duration(hours: i * 3)),
          categoryName: i % 3 == 0 ? 'Продукты' : 'Транспорт',
          note: 'Операция $i',
          kindRawValue: i % 10 == 0 ? 'income' : 'expense',
          updatedAt: start,
        ).toJson(),
    ],
    'categories': [],
    'budgets': [],
    'dirty': [],
    'tombstones': [],
    'cursor': 0,
  });
  final results = <String, String>{};
  String ms(Duration d) => '${d.inMicroseconds ~/ 1000}ms';
  Future<Duration> time(Future<void> Function() body) async {
    final watch = Stopwatch()..start();
    await body();
    return watch.elapsed;
  }

  final store = AppStore(
    storage: storage,
    background: true,
    apiFactory: (url) => SyncApi(serverUrl: url, client: _server(size)),
  );
  results['open'] = ms(await time(store.initialize));

  const edits = 20;
  final each = <int>[];
  final edit = await time(() async {
    for (var i = 0; i < edits; i++) {
      final one = Stopwatch()..start();
      await store.saveTransaction(
        TransactionRecord(
          id: 'edit-$i',
          amountMinor: 1234,
          date: DateTime.now(),
          categoryName: 'Продукты',
          updatedAt: DateTime.now(),
        ),
      );
      each.add(one.elapsedMilliseconds);
    }
  });
  results['edit'] = ms(edit ~/ edits);
  // The first edit after opening a legacy snapshot migrates it.
  results['editEach'] = each.join(',');

  // What one overview build asks of the store.
  const builds = 20;
  final build = await time(() async {
    for (var i = 0; i < builds; i++) {
      final now = DateTime.now();
      final month = DateTime(now.year, now.month);
      FinanceMath.totalBalance(store.transactions);
      FinanceMath.summary(
        store.transactions,
        month,
        FinanceMath.nextMonth(month),
      );
      FinanceMath.spending(
        store.transactions,
        month,
        FinanceMath.nextMonth(month),
      );
      store.transactions.take(5).toList();
    }
  });
  results['overview'] = ms(build ~/ builds);

  results['import500'] = ms(
    await time(
      () => store.importTransactions([
        for (var i = 0; i < 500; i++)
          TransactionRecord(
            id: 'import-$i',
            amountMinor: 500,
            date: DateTime.now(),
            categoryName: 'Транспорт',
            updatedAt: DateTime.now(),
          ),
      ]),
    ),
  );

  // Sign in and pull 5 pages of 100 server changes, with a full resync of
  // every local record queued first (the guest import does that).
  await store.setServerUrl('https://bench.example.com');
  results['signInSync'] = ms(
    await time(() => store.signIn('bench@example.com', 'password')),
  );
  await store.close();
  if (File(path).existsSync()) {
    results['file'] =
        '${(File(path).lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB';
  }
  await dir.delete(recursive: true);
  return results;
}

/// Login plus a sync endpoint that accepts pushes and serves 5 pull pages.
http.Client _server(int size) {
  return MockClient((request) async {
    final body = jsonDecode(request.body) as Map;
    final json = {'content-type': 'application/json; charset=utf-8'};
    if (request.url.path.endsWith('/login')) {
      return http.Response(
        jsonEncode({
          'accessToken': 'a',
          'refreshToken': 'r',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .toIso8601String(),
          'user': {'id': 'bench', 'email': 'bench@example.com'},
        }),
        200,
        headers: json,
      );
    }
    final cursor = body['cursor'] as int;
    final pull = body['pull'] == true && cursor < 500;
    final now = DateTime.now().toUtc().toIso8601String();
    return http.Response(
      jsonEncode({
        'cursor': pull ? cursor + 100 : cursor,
        'hasMore': pull && cursor + 100 < 500,
        'serverTime': now,
        'changes': pull
            ? [
                for (var i = 1; i <= 100; i++)
                  {
                    'entity': 'transaction',
                    'id': 'remote-${cursor + i}',
                    'deleted': false,
                    'updatedAt': now,
                    'sequence': cursor + i,
                    'payload': TransactionRecord(
                      id: 'remote',
                      amountMinor: 999,
                      date: DateTime.utc(2025),
                      categoryName: 'Продукты',
                      updatedAt: DateTime.utc(2025),
                    ).payload(),
                  },
              ]
            : [],
      }),
      200,
      headers: json,
    );
  });
}
