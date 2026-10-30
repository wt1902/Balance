import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:balance_flutter/services/sync_api.dart';

void main() {
  const time = '2026-01-01T00:00:00Z';
  WireMap change(int sequence) => {
    'entity': 'transaction',
    'id': 'id-$sequence',
    'deleted': false,
    'updatedAt': time,
    'payload': {'amount': 1.23},
    'sequence': sequence,
  };
  http.Response response(Object value, {int status = 200}) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  WireMap page(
    int cursor, {
    bool more = false,
    List<WireMap> changes = const [],
  }) => {
    'cursor': cursor,
    'hasMore': more,
    'changes': changes,
    'serverTime': time,
  };
  Future<WireMap> pull(SyncApi api, {int cursor = 0}) => api.sync(
    accessToken: 'test-token',
    cursor: cursor,
    deviceId: 'test-device',
    changes: [],
  );

  test('auth uses native routes, trims email and preserves password', () async {
    final requests = <http.Request>[];
    final session = {
      'accessToken': 'access',
      'refreshToken': 'refresh',
      'expiresAt': time,
      'user': {'id': 'user', 'email': 'test@example.com'},
    };
    final api = SyncApi(
      serverUrl: 'https://example.com/base/',
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/me')) return response(session['user']!);
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        return response(session);
      }),
    );
    expect(
      (await api.register(' test@example.com ', ' password '))['accessToken'],
      'access',
    );
    await api.login('test@example.com', ' password ');
    await api.refresh('refresh');
    await api.me('access');
    await api.logout('refresh');
    expect(requests.map((r) => r.url.path), [
      '/base/v1/auth/register',
      '/base/v1/auth/login',
      '/base/v1/auth/refresh',
      '/base/v1/me',
      '/base/v1/auth/logout',
    ]);
    expect(jsonDecode(requests.first.body), {
      'email': 'test@example.com',
      'password': ' password ',
    });
    expect(requests[3].method, 'GET');
    expect(requests[3].headers['Authorization'], 'Bearer access');
    expect(requests.every((r) => !r.followRedirects), isTrue);
  });

  test(
    'synchronize batches push-only by 100 then applies ordered pull pages',
    () async {
      final sent = <WireMap>[];
      var pullCount = 0;
      final api = SyncApi(
        serverUrl: 'https://example.com',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as WireMap;
          sent.add(body);
          if (body['pull'] == false) return response(page(0));
          pullCount++;
          return response(
            page(pullCount, more: pullCount == 1, changes: [change(pullCount)]),
          );
        }),
      );
      final applied = <int>[];
      final outgoing = List.generate(205, (i) => change(i)..remove('sequence'));
      final result = await api.synchronize(
        accessToken: () async => 'token',
        cursor: 0,
        deviceId: 'device',
        changes: outgoing,
        applyPage: (changes, cursor) async {
          expect(changes.single['sequence'], cursor);
          applied.add(cursor);
        },
      );
      expect(sent.take(3).map((p) => (p['changes'] as List).length), [
        100,
        100,
        5,
      ]);
      expect(
        sent.take(3).every((p) => p['pull'] == false && p['cursor'] == 0),
        isTrue,
      );
      expect(sent.skip(3).map((p) => p['cursor']), [0, 1]);
      expect(applied, [1, 2]);
      expect(result, 2);
    },
  );

  test('failed durable apply stops pagination', () async {
    var calls = 0;
    final api = SyncApi(
      serverUrl: 'https://example.com',
      client: MockClient((_) async {
        calls++;
        return response(page(1, more: true, changes: [change(1)]));
      }),
    );
    await expectLater(
      api.synchronize(
        accessToken: () async => 'token',
        cursor: 0,
        deviceId: 'device',
        changes: [],
        applyPage: (_, _) async => throw StateError('disk full'),
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });

  test('invalid response cursors, sequence and shape are rejected', () async {
    final invalidPages = <Object>[
      page(0, more: true),
      page(1),
      page(2, changes: [change(1)]),
      page(1, changes: [change(1), change(1)]),
      {...page(0), 'hasMore': 'yes'},
      {...page(0), 'cursor': 0.5},
      {...page(0), 'serverTime': 'not-a-date'},
      [],
    ];
    for (final invalid in invalidPages) {
      final api = SyncApi(
        serverUrl: 'https://example.com',
        client: MockClient((_) async => response(invalid)),
      );
      await expectLater(pull(api), throwsFormatException, reason: '$invalid');
    }
    final api = SyncApi(
      serverUrl: 'https://example.com',
      client: MockClient((_) async => response(page(0))),
    );
    await expectLater(pull(api, cursor: 1), throwsFormatException);
  });

  test(
    'HTTP errors preserve structured status and discard raw proxy bodies',
    () async {
      final api = SyncApi(
        serverUrl: 'https://example.com',
        client: MockClient(
          (_) async => response({
            'error': {'code': 'invalid_token', 'message': 'Expired'},
          }, status: 401),
        ),
      );
      await expectLater(
        pull(api),
        throwsA(
          isA<SyncApiException>()
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.code, 'code', 'invalid_token'),
        ),
      );
      final proxy = SyncApi(
        serverUrl: 'https://example.com',
        client: MockClient(
          (_) async =>
              http.Response('<html>private proxy diagnostics</html>', 502),
        ),
      );
      await expectLater(
        pull(proxy),
        throwsA(
          isA<SyncApiException>().having(
            (e) => e.toString().contains('private'),
            'no raw response body',
            isFalse,
          ),
        ),
      );
    },
  );

  test('malformed sessions and unsafe server addresses are rejected', () async {
    final api = SyncApi(
      serverUrl: 'https://example.com',
      client: MockClient((_) async => response({'accessToken': 'token'})),
    );
    await expectLater(api.login('a@b.com', 'password'), throwsFormatException);
    for (final url in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com?token=x',
      'file:///tmp/test',
    ]) {
      expect(() => SyncApi(serverUrl: url), throwsArgumentError);
    }
    expect(
      SyncApi(
        serverUrl: 'http://127.0.0.1:8080',
        allowInsecureHttp: true,
      ).baseUri.scheme,
      'http',
    );
  });

  test('invalid outgoing changes fail before any HTTP call', () async {
    var calls = 0;
    final api = SyncApi(
      serverUrl: 'https://example.com',
      client: MockClient((_) async {
        calls++;
        return response(page(0));
      }),
    );
    final invalid = change(1)..['entity'] = 'unknown';
    await expectLater(
      api.sync(
        accessToken: 'token',
        cursor: 0,
        deviceId: 'device',
        changes: [invalid],
      ),
      throwsFormatException,
    );
    expect(calls, 0);
  });
}
