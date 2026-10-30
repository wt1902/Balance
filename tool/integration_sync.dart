// Run against a disposable BalanceServer instance:
// dart run tool/integration_sync.dart http://127.0.0.1:18080
// Creates two test accounts; never use a production database.
import 'dart:convert';
import 'dart:io';

import 'package:balance_flutter/domain/finance.dart';
import 'package:balance_flutter/services/sync_api.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> unauthorized(
  Future<Object?> Function() action,
  String message,
) async {
  try {
    await action();
  } on SyncApiException catch (error) {
    check(error.statusCode == 401, '$message: expected HTTP 401');
    return;
  }
  throw StateError('$message: unexpectedly accepted');
}

Map<String, dynamic> wire(
  String entity,
  String id,
  DateTime updatedAt,
  Map<String, dynamic>? payload,
) => {
  'entity': entity,
  'id': id,
  'updatedAt': updatedAt.toUtc().toIso8601String(),
  'deleted': payload == null,
  'payload': ?payload,
};

Future<void> main(List<String> arguments) async {
  final url = arguments.isEmpty ? 'http://127.0.0.1:18080' : arguments.single;
  final uri = Uri.parse(url);
  check(
    ['localhost', '127.0.0.1', '::1'].contains(uri.host),
    'Integration accounts must use a local disposable server',
  );
  final primary = SyncApi(serverUrl: url, allowInsecureHttp: true);
  final secondDevice = SyncApi(serverUrl: url, allowInsecureHttp: true);
  final outsider = SyncApi(serverUrl: url, allowInsecureHttp: true);
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final email = 'flutter-integration-$suffix@example.com';
  const password = 'Balance integration password 2026!';
  final ledger = <String, Map<String, dynamic>>{};
  final pages = <int>[];
  var cursor = 0;
  try {
    final registered = await primary.register(email, password);
    final user = await primary.me(registered['accessToken'] as String);
    check(user['email'] == email, 'register/me account mismatch');
    var session = await secondDevice.login(email, password);
    check(
      (session['user'] as Map)['id'] == user['id'],
      'login account mismatch',
    );
    final other = await outsider.register(
      'other-$suffix@example.com',
      password,
    );
    final timestamp = DateTime.now().toUtc().subtract(
      const Duration(seconds: 5),
    );
    final transactions = List.generate(
      1100,
      (index) => TransactionRecord(
        id: 'transaction-$index',
        amountMinor: 10000 + index,
        date: timestamp,
        categoryName: 'Тестовая категория 🍏',
        updatedAt: timestamp,
        note: 'UTF-8 roundtrip $index',
        kindRawValue: index.isEven ? 'expense' : 'income',
      ),
    );
    final category = CategoryRecord(
      id: 'integration-category',
      name: 'Тестовая категория 🍏',
      icon: 'cart.fill',
      colorName: 'green',
      emoji: '🍏',
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    final budget = BudgetRecord(
      id: 'integration-budget',
      categoryName: category.name,
      limitMinor: 999999,
      monthStart: DateTime.utc(timestamp.year, timestamp.month),
      updatedAt: timestamp,
    );
    final changes = [
      for (final record in transactions)
        wire('transaction', record.id, record.updatedAt, record.payload()),
      wire('category', category.id, category.updatedAt, category.payload()),
      wire('budget', budget.id, budget.updatedAt, budget.payload()),
    ];
    await primary.synchronize(
      accessToken: () async => registered['accessToken'] as String,
      cursor: 0,
      deviceId: 'integration-device-one',
      changes: changes,
      applyPage: (_, _) async {},
    );
    cursor = await secondDevice.synchronize(
      accessToken: () async => session['accessToken'] as String,
      cursor: 0,
      deviceId: 'integration-device-two',
      changes: [],
      applyPage: (page, nextCursor) async {
        check(nextCursor > cursor, 'Non-advancing pagination cursor');
        pages.add(page.length);
        for (final change in page) {
          ledger['${change['entity']}:${change['id']}'] = change;
        }
        cursor = nextCursor;
      },
    );
    check(
      jsonEncode(pages) == '[500,500,102]',
      'Expected 3 pages [500,500,102], got $pages',
    );
    check(ledger.length == 1102, 'Missing records after pagination');
    final roundtrip = ledger['transaction:transaction-99']!;
    final decoded = TransactionRecord.fromPayload(
      id: roundtrip['id'] as String,
      updatedAt: DateTime.parse(roundtrip['updatedAt'] as String),
      payload: Map<String, dynamic>.from(roundtrip['payload'] as Map),
    );
    check(
      decoded.amountMinor == 10099 && decoded.categoryName == category.name,
      'Money or UTF-8 payload changed',
    );
    final changedAt = DateTime.now().toUtc();
    final edited = transactions.first.copyWith(
      amountMinor: 1234567,
      updatedAt: changedAt,
    );
    final updates = [
      wire('transaction', edited.id, edited.updatedAt, edited.payload()),
      wire('transaction', transactions[1].id, changedAt, null),
    ];
    await primary.synchronize(
      accessToken: () async => registered['accessToken'] as String,
      cursor: cursor,
      deviceId: 'integration-device-one',
      changes: updates,
      applyPage: (_, _) async {},
    );
    var updateCount = 0;
    cursor = await secondDevice.synchronize(
      accessToken: () async => session['accessToken'] as String,
      cursor: cursor,
      deviceId: 'integration-device-two',
      changes: [],
      applyPage: (page, nextCursor) async {
        updateCount += page.length;
        for (final change in page) {
          ledger['${change['entity']}:${change['id']}'] = change;
        }
        cursor = nextCursor;
      },
    );
    check(updateCount == 2, 'Expected update and tombstone');
    check(
      ledger['transaction:transaction-1']!['deleted'] == true,
      'Deletion was not propagated',
    );
    final updatedPayload =
        ledger['transaction:transaction-0']!['payload'] as Map;
    check(
      moneyToMinor(updatedPayload['amount'] as num) == 1234567,
      'Update was not propagated',
    );
    final oldCursor = cursor;
    // Replaying stale active rows must not overwrite the newer value/tombstone.
    await primary.synchronize(
      accessToken: () async => registered['accessToken'] as String,
      cursor: cursor,
      deviceId: 'integration-device-one',
      changes: changes.take(2).toList(),
      applyPage: (page, nextCursor) async {
        check(
          page.isEmpty && nextCursor == oldCursor,
          'Stale replay changed LWW state',
        );
      },
    );
    // The second account shares record IDs but must see no first-account rows.
    final isolated = await outsider.sync(
      accessToken: other['accessToken'] as String,
      cursor: 0,
      deviceId: 'integration-outsider',
      changes: [],
    );
    check(
      (isolated['changes'] as List).isEmpty && isolated['cursor'] == 0,
      'Cross-account data leak',
    );
    await outsider.sync(
      accessToken: other['accessToken'] as String,
      cursor: 0,
      deviceId: 'integration-outsider',
      pull: false,
      changes: [
        wire(
          'transaction',
          transactions.first.id,
          changedAt,
          transactions.first.copyWith(amountMinor: 1).payload(),
        ),
      ],
    );
    final unchanged = await primary.sync(
      accessToken: registered['accessToken'] as String,
      cursor: cursor,
      deviceId: 'integration-device-one',
      changes: [],
    );
    check(
      (unchanged['changes'] as List).isEmpty,
      'Other-account edit affected first account',
    );
    final oldRefresh = session['refreshToken'] as String;
    session = await secondDevice.refresh(oldRefresh);
    check(
      session['refreshToken'] != oldRefresh,
      'Refresh token was not rotated',
    );
    await unauthorized(
      () => secondDevice.refresh(oldRefresh),
      'Rotated refresh token',
    );
    check(
      (await secondDevice.me(session['accessToken'] as String))['id'] ==
          user['id'],
      'Refreshed token invalid',
    );
    await secondDevice.logout(session['refreshToken'] as String);
    await unauthorized(
      () => secondDevice.refresh(session['refreshToken'] as String),
      'Logged-out refresh token',
    );
    await primary.logout(registered['refreshToken'] as String);
    await outsider.logout(other['refreshToken'] as String);
    stdout.writeln(
      jsonEncode({
        'result': 'PASS',
        'server': url,
        'records': 1102,
        'pullPages': pages,
        'updateAndDelete': true,
        'staleReplayLww': true,
        'twoAccountIsolation': true,
        'refreshRotation': true,
        'logoutRevocation': true,
      }),
    );
  } finally {
    primary.close();
    secondDevice.close();
    outsider.close();
  }
}
