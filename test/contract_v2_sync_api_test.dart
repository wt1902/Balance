import 'dart:convert';
import 'dart:typed_data';

import 'package:balance_flutter/services/sync_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const time = '2026-01-01T00:00:00Z';
  http.Response json(Object value, {int status = 200}) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  http.Response error(int status, String code) => json({
    'error': {'code': code, 'message': code},
  }, status: status);

  SyncApi api(Future<http.Response> Function(http.Request) handler) =>
      SyncApi(serverUrl: 'https://example.com', client: MockClient(handler));

  group('capabilities', () {
    test('parses a v2 answer without authorization', () async {
      late http.Request seen;
      final caps = await api((request) async {
        seen = request;
        return json({
          'contract': 2,
          'entities': ['transaction', 'account', 'attachment'],
          'attachments': {
            'maxBytes': 10485760,
            'types': ['image/jpeg', 'application/pdf'],
          },
          'ledgers': true,
        });
      }).capabilities();
      expect(seen.method, 'GET');
      expect(seen.url.path, '/v1/capabilities');
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(caps.contract, 2);
      expect(caps.entities, {'transaction', 'account', 'attachment'});
      expect(caps.attachments, isTrue);
      expect(caps.attachmentMaxBytes, 10485760);
      expect(caps.attachmentTypes, contains('application/pdf'));
      expect(caps.ledgers, isTrue);
      final again = ServerCapabilities.fromJson(
        jsonDecode(jsonEncode(caps.toJson())) as Map<String, dynamic>,
      );
      expect(again.entities, caps.entities);
      expect(again.attachmentMaxBytes, caps.attachmentMaxBytes);
    });

    test('404 means a v1 server', () async {
      final caps = await api(
        (_) async => error(404, 'not_found'),
      ).capabilities();
      expect(caps.contract, 1);
      expect(caps.entities, {'transaction', 'category', 'budget'});
      expect(caps.attachments, isFalse);
      expect(caps.ledgers, isFalse);
    });

    test('other failures are reported', () async {
      await expectLater(
        api((_) async => error(500, 'internal')).capabilities(),
        throwsA(isA<SyncApiException>()),
      );
    });
  });

  group('sync', () {
    test('sends X-Balance-Ledger for a shared ledger only', () async {
      final headers = <String?>[];
      final client = api((request) async {
        headers.add(request.headers[ledgerHeader]);
        final body = jsonDecode(request.body) as Map;
        return json({
          'cursor': body['cursor'],
          'changes': [],
          'hasMore': false,
          'serverTime': time,
        });
      });
      Future<int> run(String? ledger) => client.synchronize(
        accessToken: () async => 'token',
        cursor: 0,
        deviceId: 'device',
        changes: [
          {
            'entity': 'account',
            'id': 'a',
            'deleted': false,
            'updatedAt': time,
            'payload': {'name': 'Карта'},
          },
        ],
        applyPage: (_, _) async {},
        ledgerId: ledger,
      );
      await run('shared');
      await run(null);
      expect(headers, ['shared', 'shared', null, null]);
    });

    test('accepts every v2 entity outgoing, rejects unknown ones', () async {
      final client = api((request) async {
        final body = jsonDecode(request.body) as Map;
        return json({
          'cursor': body['cursor'],
          'changes': [],
          'hasMore': false,
          'serverTime': time,
        });
      });
      for (final entity in syncEntities) {
        await client.sync(
          accessToken: 't',
          cursor: 0,
          deviceId: 'd',
          pull: false,
          changes: [
            {
              'entity': entity,
              'id': entity == 'setting' ? 'baseCurrency' : 'id',
              'deleted': true,
              'updatedAt': time,
            },
          ],
        );
      }
      await expectLater(
        client.sync(
          accessToken: 't',
          cursor: 0,
          deviceId: 'd',
          changes: [
            {'entity': 'future', 'id': 'x', 'deleted': true, 'updatedAt': time},
          ],
        ),
        throwsFormatException,
      );
    });

    test(
      'skips unknown pulled entities silently, cursor still moves',
      () async {
        final page = await api(
          (_) async => json({
            'cursor': 3,
            'hasMore': false,
            'serverTime': time,
            'changes': [
              {
                'entity': 'transfer',
                'id': 't',
                'deleted': false,
                'updatedAt': time,
                'payload': {'amount': 1},
                'sequence': 1,
              },
              {
                'entity': 'futureThing',
                'id': 'x',
                'deleted': false,
                'updatedAt': time,
                'payload': {'anything': true},
                'sequence': 3,
              },
            ],
          }),
        ).sync(accessToken: 't', cursor: 0, deviceId: 'd', changes: []);
        expect(page['cursor'], 3);
        expect((page['changes'] as List).map((c) => (c as Map)['entity']), [
          'transfer',
        ]);
      },
    );

    test('a page of only unknown entities is still validated', () async {
      await expectLater(
        api(
          (_) async => json({
            'cursor': 5,
            'hasMore': false,
            'serverTime': time,
            'changes': [
              {'entity': 'futureThing', 'id': 'x', 'sequence': 4},
            ],
          }),
        ).sync(accessToken: 't', cursor: 0, deviceId: 'd', changes: []),
        throwsFormatException,
      );
    });
  });

  group('ledgers', () {
    final ledger = {
      'id': 'L1',
      'name': 'Семья',
      'role': 'owner',
      'members': [
        {'userId': 'u1', 'email': 'a@example.com', 'role': 'owner'},
      ],
    };

    test('routes, methods and bodies', () async {
      final seen = <String>[];
      final bodies = <Object?>[];
      final client = api((request) async {
        seen.add('${request.method} ${request.url.path}');
        bodies.add(request.body.isEmpty ? null : jsonDecode(request.body));
        expect(request.headers['Authorization'], 'Bearer token');
        final path = request.url.path;
        if (request.method == 'GET') {
          return json({
            'ledgers': [ledger],
          });
        }
        if (path.endsWith('/invites')) {
          return json({'code': 'ABCDEFGHJK', 'expiresAt': time});
        }
        if (request.method == 'DELETE') return http.Response('', 204);
        return json({...ledger, if (path.endsWith('/join')) 'role': 'member'});
      });
      final listed = await client.ledgers('token');
      expect(listed.single.name, 'Семья');
      expect(listed.single.isOwner, isTrue);
      expect(listed.single.members.single.email, 'a@example.com');
      expect((await client.createLedger('token', 'Семья')).id, 'L1');
      expect((await client.renameLedger('token', 'L1', 'Дом'))!.id, 'L1');
      final invite = await client.createInvite('token', 'L1');
      expect(invite.code, 'ABCDEFGHJK');
      expect(invite.expiresAt, DateTime.parse(time));
      expect((await client.joinLedger('token', ' ABCDEFGHJK ')).role, 'member');
      await client.removeLedgerMember('token', 'L1', 'u/2');
      await client.deleteLedger('token', 'L1');
      expect(seen, [
        'GET /v1/ledgers',
        'POST /v1/ledgers',
        'PATCH /v1/ledgers/L1',
        'POST /v1/ledgers/L1/invites',
        'POST /v1/ledgers/join',
        'DELETE /v1/ledgers/L1/members/u%2F2',
        'DELETE /v1/ledgers/L1',
      ]);
      expect(bodies[1], {'name': 'Семья'});
      expect(bodies[2], {'name': 'Дом'});
      expect(bodies[4], {'code': 'ABCDEFGHJK'});
    });

    test('errors keep the server code', () async {
      await expectLater(
        api(
          (_) async => error(409, 'owner_cannot_leave'),
        ).removeLedgerMember('t', 'L1', 'u1'),
        throwsA(
          isA<SyncApiException>()
              .having((e) => e.code, 'code', 'owner_cannot_leave')
              .having((e) => e.statusCode, 'status', 409),
        ),
      );
    });
  });

  group('attachments', () {
    final bytes = Uint8List.fromList(utf8.encode('receipt'));
    final sha = sha256.convert(bytes).toString();

    test('PUT carries bytes, type, token and ledger', () async {
      late http.Request seen;
      var status = 201;
      final client = api((request) async {
        seen = request;
        return http.Response('', status);
      });
      expect(
        await client.uploadAttachment(
          accessToken: 'token',
          sha256: sha,
          bytes: bytes,
          contentType: 'image/jpeg',
          ledgerId: 'L1',
        ),
        isTrue,
      );
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/v1/attachments/$sha');
      expect(seen.bodyBytes, bytes);
      expect(seen.headers['Content-Type'], 'image/jpeg');
      expect(seen.headers['Authorization'], 'Bearer token');
      expect(seen.headers[ledgerHeader], 'L1');
      expect(seen.followRedirects, isFalse);
      status = 200;
      expect(
        await client.uploadAttachment(
          accessToken: 'token',
          sha256: sha,
          bytes: bytes,
          contentType: 'image/jpeg',
        ),
        isFalse,
      );
      expect(seen.headers.containsKey(ledgerHeader), isFalse);
    });

    test('GET returns bytes and type; errors are typed', () async {
      final client = api((request) async {
        if (request.url.path.endsWith(sha)) {
          return http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'image/png; charset=binary'},
          );
        }
        return error(404, 'not_found');
      });
      final file = await client.downloadAttachment(
        accessToken: 't',
        sha256: sha,
      );
      expect(file.bytes, bytes);
      expect(file.contentType, 'image/png');
      await expectLater(
        client.downloadAttachment(accessToken: 't', sha256: 'b' * 64),
        throwsA(
          isA<SyncApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      for (final code in [
        (413, 'payload_too_large'),
        (415, 'unsupported_media_type'),
        (400, 'hash_mismatch'),
      ]) {
        await expectLater(
          api((_) async => error(code.$1, code.$2)).uploadAttachment(
            accessToken: 't',
            sha256: sha,
            bytes: bytes,
            contentType: 'image/png',
          ),
          throwsA(
            isA<SyncApiException>().having((e) => e.code, 'code', code.$2),
          ),
        );
      }
    });

    test('rejects a malformed hash before any request', () async {
      var requests = 0;
      final client = api((_) async {
        requests++;
        return http.Response('', 200);
      });
      await expectLater(
        client.downloadAttachment(accessToken: 't', sha256: '../me'),
        throwsArgumentError,
      );
      expect(requests, 0);
    });
  });
}
