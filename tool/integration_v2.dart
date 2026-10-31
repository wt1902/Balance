// Contract v2 checks against a disposable BalanceServer instance:
// dart run tool/integration_v2.dart http://127.0.0.1:18080
// Creates three test accounts; never use a production database.
import 'dart:convert';
import 'dart:io';

import 'package:balance_flutter/domain/recurring.dart';
import 'package:balance_flutter/services/sync_api.dart';
import 'package:crypto/crypto.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> fails(
  Future<Object?> Function() action,
  int status,
  String message, {
  String? code,
}) async {
  try {
    await action();
  } on SyncApiException catch (error) {
    check(
      error.statusCode == status,
      '$message: expected HTTP $status, got ${error.statusCode}',
    );
    if (code != null) {
      check(error.code == code, '$message: expected $code, got ${error.code}');
    }
    return;
  }
  throw StateError('$message: unexpectedly accepted');
}

Map<String, dynamic> change(
  String entity,
  String id,
  DateTime updatedAt,
  Map<String, dynamic> payload,
) => {
  'entity': entity,
  'id': id,
  'updatedAt': updatedAt.toUtc().toIso8601String(),
  'deleted': false,
  'payload': payload,
};

/// Every record of a space, keyed by `entity:id`.
Future<Map<String, Map<String, dynamic>>> pullAll(
  SyncApi api,
  String token, {
  String? ledgerId,
}) async {
  final records = <String, Map<String, dynamic>>{};
  var cursor = 0;
  while (true) {
    final page = await api.sync(
      accessToken: token,
      cursor: cursor,
      deviceId: 'integration-v2',
      changes: const [],
      ledgerId: ledgerId,
    );
    for (final c in (page['changes'] as List).cast<Map<String, dynamic>>()) {
      records['${c['entity']}:${c['id']}'] = c;
    }
    final next = page['cursor'] as int;
    if (page['hasMore'] != true || next == cursor) return records;
    cursor = next;
  }
}

Future<void> main(List<String> arguments) async {
  final url = arguments.isEmpty ? 'http://127.0.0.1:18080' : arguments.single;
  check(
    ['localhost', '127.0.0.1', '::1'].contains(Uri.parse(url).host),
    'Integration accounts must use a local disposable server',
  );
  final owner = SyncApi(serverUrl: url, allowInsecureHttp: true);
  final member = SyncApi(serverUrl: url, allowInsecureHttp: true);
  final stranger = SyncApi(serverUrl: url, allowInsecureHttp: true);
  final suffix = DateTime.now().microsecondsSinceEpoch;
  const password = 'Balance integration password 2026!';
  try {
    // Capabilities.
    final caps = await owner.capabilities();
    check(caps.contract == 2, 'capabilities: contract 2');
    check(caps.ledgers, 'capabilities: ledgers');
    check(caps.entities.length == 11, 'capabilities: 11 entities');
    check(caps.attachmentMaxBytes == 10485760, 'capabilities: 10 MiB');

    final a =
        (await owner.register(
              'v2-owner-$suffix@example.com',
              password,
            ))['accessToken']
            as String;
    final b =
        (await member.register(
              'v2-member-$suffix@example.com',
              password,
            ))['accessToken']
            as String;
    final c =
        (await stranger.register(
              'v2-stranger-$suffix@example.com',
              password,
            ))['accessToken']
            as String;
    final now = DateTime.now().toUtc().subtract(const Duration(seconds: 5));

    // All v2 entities round-trip with unknown fields preserved.
    final payloads = <String, Map<String, dynamic>>{
      'account': {
        'name': 'Карта',
        'kindRawValue': 'card',
        'icon': 'creditcard.fill',
        'colorName': 'blue',
        'currency': 'RUB',
        'createdAt': now.toIso8601String(),
        'isArchived': false,
        'sortOrder': 0,
        'futureField': {'x': 1},
      },
      'transfer': {
        'fromAccountId': 'acc-1',
        'toAccountId': 'acc-2',
        'amount': 1000.0,
        'toAmount': 10.5,
        'date': now.toIso8601String(),
        'note': '',
      },
      'recurring': {
        'kindRawValue': 'expense',
        'amount': 990.0,
        'currency': 'RUB',
        'categoryName': 'Подписки',
        'frequency': 'monthly',
        'interval': 1,
        'startDate': '2026-01-05T09:00:00Z',
        'mode': 'auto',
        'isPaused': false,
        'generatedThrough': '2026-10-05',
      },
      'goal': {
        'name': 'Отпуск',
        'target': 150000.0,
        'saved': 20000.0,
        'currency': 'RUB',
      },
      'debt': {
        'person': 'Иван',
        'direction': 'owedToMe',
        'amount': 5000.0,
        'repaid': 1000.0,
        'isClosed': false,
        'date': now.toIso8601String(),
      },
      'rate': {
        'from': 'USD',
        'to': 'RUB',
        'rate': '92.35',
        'date': now.toIso8601String(),
      },
      'setting': {'value': 'RUB'},
      'transaction': {
        'amount': 12.34,
        'date': now.toIso8601String(),
        'note': 'v2',
        'categoryName': 'Продукты',
        'kindRawValue': 'expense',
        'isBalanceAdjustment': false,
        'accountId': 'acc-1',
        'currency': 'USD',
        'tags': ['еда', 'дом'],
        'unknownV3': true,
      },
    };
    final ids = {
      for (final e in payloads.keys)
        e: e == 'setting' ? 'baseCurrency' : 'v2-$e-$suffix',
    };
    await owner.sync(
      accessToken: a,
      cursor: 0,
      deviceId: 'device-1',
      changes: [
        for (final e in payloads.keys) change(e, ids[e]!, now, payloads[e]!),
      ],
      pull: false,
    );
    final pulled = await pullAll(owner, a);
    for (final e in payloads.keys) {
      final record = pulled['$e:${ids[e]}'];
      check(record != null, 'round-trip: $e missing');
      check(
        jsonEncode(record!['payload']) == jsonEncode(payloads[e]),
        'round-trip: $e payload changed',
      );
    }

    // Two devices create the same recurring occurrence: one record.
    final occurrenceId = RecurringEngine.transactionId(
      'rule-$suffix',
      '2026-10-05',
    );
    check(
      occurrenceId ==
          RecurringEngine.transactionId('rule-$suffix', '2026-10-05'),
      'recurring id is not deterministic',
    );
    final occurrence = {
      'amount': 990.0,
      'date': '2026-10-05T09:00:00Z',
      'categoryName': 'Подписки',
      'kindRawValue': 'expense',
      'recurringId': 'rule-$suffix',
      'occurrence': '2026-10-05',
    };
    for (final device in ['phone', 'desktop']) {
      await owner.sync(
        accessToken: a,
        cursor: 0,
        deviceId: device,
        pull: false,
        changes: [change('transaction', occurrenceId, now, occurrence)],
      );
    }
    final afterRecurring = await pullAll(owner, a);
    check(
      afterRecurring.keys
              .where((k) => k == 'transaction:$occurrenceId')
              .length ==
          1,
      'recurring occurrence duplicated',
    );

    // Attachments in the personal space.
    final bytes = utf8.encode('fake jpeg bytes $suffix');
    final hash = sha256.convert(bytes).toString();
    check(
      await owner.uploadAttachment(
        accessToken: a,
        sha256: hash,
        bytes: bytes,
        contentType: 'image/jpeg',
      ),
      'attachment: first upload must be 201',
    );
    check(
      !await owner.uploadAttachment(
        accessToken: a,
        sha256: hash,
        bytes: bytes,
        contentType: 'image/jpeg',
      ),
      'attachment: repeat upload must be 200',
    );
    final file = await owner.downloadAttachment(accessToken: a, sha256: hash);
    check(
      utf8.decode(file.bytes) == utf8.decode(bytes),
      'attachment: bytes differ',
    );
    check(file.contentType == 'image/jpeg', 'attachment: content type');
    await fails(
      () => owner.uploadAttachment(
        accessToken: a,
        sha256: hash,
        bytes: [1, 2, 3],
        contentType: 'image/jpeg',
      ),
      400,
      'attachment: hash mismatch',
      code: 'hash_mismatch',
    );
    await fails(
      () => owner.uploadAttachment(
        accessToken: a,
        sha256: hash,
        bytes: bytes,
        contentType: 'text/plain',
      ),
      415,
      'attachment: type',
      code: 'unsupported_media_type',
    );
    final big = List<int>.filled(10485761, 7);
    await fails(
      () => owner.uploadAttachment(
        accessToken: a,
        sha256: sha256.convert(big).toString(),
        bytes: big,
        contentType: 'image/png',
      ),
      413,
      'attachment: size',
      code: 'payload_too_large',
    );
    await fails(
      () => stranger.downloadAttachment(accessToken: c, sha256: hash),
      404,
      'attachment: other user must not see it',
    );

    // Shared ledger between owner and member.
    final ledger = await owner.createLedger(a, 'Семья $suffix');
    check(ledger.role == 'owner', 'ledger: creator is owner');
    final invite = await owner.createInvite(a, ledger.id);
    check(invite.code.length == 10, 'ledger: invite code length');
    await fails(
      () => member.joinLedger(b, 'WRONGCODE1'),
      400,
      'ledger: bad code',
      code: 'invalid_code',
    );
    final joined = await member.joinLedger(b, invite.code);
    check(joined.id == ledger.id && joined.role == 'member', 'ledger: join');
    await fails(
      () => stranger.joinLedger(c, invite.code),
      400,
      'ledger: code is single use',
      code: 'invalid_code',
    );

    await member.sync(
      accessToken: b,
      cursor: 0,
      deviceId: 'member',
      pull: false,
      ledgerId: ledger.id,
      changes: [
        change('transaction', 'shared-$suffix', now, payloads['transaction']!),
      ],
    );
    final shared = await pullAll(owner, a, ledgerId: ledger.id);
    check(
      shared.containsKey('transaction:shared-$suffix'),
      'ledger: owner sees member record',
    );
    check(
      !shared.containsKey('account:${ids['account']}'),
      'ledger: personal data leaked into ledger',
    );
    check(
      !(await pullAll(member, b)).containsKey('transaction:shared-$suffix'),
      'ledger: shared record leaked into personal space',
    );
    await fails(
      () => pullAll(stranger, c, ledgerId: ledger.id),
      403,
      'ledger: outsider sync',
      code: 'forbidden',
    );
    check(
      await member.uploadAttachment(
        accessToken: b,
        sha256: hash,
        bytes: bytes,
        contentType: 'image/jpeg',
        ledgerId: ledger.id,
      ),
      'ledger: attachment is stored per space (201)',
    );
    final members = (await owner.ledgers(
      a,
    )).singleWhere((l) => l.id == ledger.id).members;
    check(members.length == 2, 'ledger: two members');
    final memberId = members.singleWhere((m) => m.role == 'member').userId;
    final ownerId = members.singleWhere((m) => m.role == 'owner').userId;
    await fails(
      () => owner.removeLedgerMember(a, ledger.id, ownerId),
      409,
      'ledger: owner cannot leave',
      code: 'owner_cannot_leave',
    );
    await member.removeLedgerMember(b, ledger.id, memberId);
    await fails(
      () => pullAll(member, b, ledgerId: ledger.id),
      403,
      'ledger: left member',
      code: 'forbidden',
    );
    await owner.deleteLedger(a, ledger.id);
    await fails(
      () => pullAll(owner, a, ledgerId: ledger.id),
      404,
      'ledger: deleted',
      code: 'not_found',
    );

    stdout.writeln(
      jsonEncode({
        'result': 'PASS',
        'server': url,
        'capabilities': true,
        'entitiesRoundTrip': payloads.length,
        'unknownFieldsPreserved': true,
        'recurringDeterministicId': true,
        'attachments': true,
        'ledgers': true,
      }),
    );
  } finally {
    owner.close();
    member.close();
    stranger.close();
  }
}
