import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory BalanceServer for tests: auth, `/v1/sync` with last-write-wins
/// and per-ledger sequences, capabilities, ledgers and attachments
/// (contract v2). With [v2] false it behaves like a v1 server: no
/// capabilities route and only v1 entities accepted.
class FakeBalanceServer {
  FakeBalanceServer({this.v2 = true});

  bool v2;
  final requests = <http.Request>[];

  /// Every accepted change in push order, with `ledger` (null: personal).
  final pushed = <Map<String, dynamic>>[];

  /// Ledger id → stored changes with `sequence`.
  final _logs = <String?, List<Map<String, dynamic>>>{};
  final files = <String?, Map<String, (Uint8List, String)>>{};
  final ledgers = <String, Map<String, dynamic>>{};
  final invites = <String, String>{};
  String userId = 'user';
  int _ledgerCount = 0;

  /// Status forced for `/v1/sync` of a ledger (e.g. 403 after removal).
  final syncStatus = <String, int>{};

  late final MockClient client = MockClient(_handle);

  List<Map<String, dynamic>> log([String? ledger]) =>
      _logs.putIfAbsent(ledger, () => []);

  /// Adds a change as if another device pushed it.
  void inject(Map<String, dynamic> change, {String? ledger}) {
    final entries = log(ledger);
    entries.removeWhere(
      (e) => e['entity'] == change['entity'] && e['id'] == change['id'],
    );
    entries.add({...change, 'sequence': _nextSequence(ledger)});
  }

  final _sequences = <String?, int>{};

  http.Response _json(Object value, {int status = 200}) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _error(int status, String code) => _json({
    'error': {'code': code, 'message': code},
  }, status: status);

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    final ledger = request.headers['x-balance-ledger'];
    if (path.startsWith('/v1/auth/')) {
      if (path.endsWith('/logout')) return http.Response('', 204);
      return _json({
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'user': {'id': userId, 'email': '$userId@example.com'},
      });
    }
    if (path == '/v1/capabilities') {
      if (!v2) return _error(404, 'not_found');
      return _json({
        'contract': 2,
        'entities': [
          'transaction',
          'category',
          'budget',
          'account',
          'transfer',
          'recurring',
          'goal',
          'debt',
          'rate',
          'setting',
          'attachment',
        ],
        'attachments': {
          'maxBytes': 1024,
          'types': ['image/jpeg', 'image/png', 'application/pdf'],
        },
        'ledgers': true,
      });
    }
    if (request.headers['authorization'] != 'Bearer access') {
      return _error(401, 'unauthorized');
    }
    if (ledger != null && !ledgers.containsKey(ledger)) {
      return _error(404, 'not_found');
    }
    if (path == '/v1/sync') return _sync(request, ledger);
    if (path.startsWith('/v1/attachments/')) {
      final sha = path.substring('/v1/attachments/'.length);
      final store = files.putIfAbsent(ledger, () => {});
      if (request.method == 'PUT') {
        if (sha256.convert(request.bodyBytes).toString() != sha) {
          return _error(400, 'hash_mismatch');
        }
        final existed = store.containsKey(sha);
        store[sha] = (request.bodyBytes, request.headers['content-type'] ?? '');
        return http.Response('', existed ? 200 : 201);
      }
      final file = store[sha];
      if (file == null) return _error(404, 'not_found');
      return http.Response.bytes(
        file.$1,
        200,
        headers: {'content-type': file.$2},
      );
    }
    if (path.startsWith('/v1/ledgers')) return _ledgers(request);
    return _error(404, 'not_found');
  }

  http.Response _sync(http.Request request, String? ledger) {
    if (ledger != null && syncStatus.containsKey(ledger)) {
      return _error(syncStatus[ledger]!, 'forbidden');
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final entries = log(ledger);
    for (final raw in body['changes'] as List) {
      final change = Map<String, dynamic>.from(raw as Map);
      if (!v2 &&
          !{'transaction', 'category', 'budget'}.contains(change['entity'])) {
        return _error(400, 'invalid_entity');
      }
      final existing = entries.lastWhere(
        (e) => e['entity'] == change['entity'] && e['id'] == change['id'],
        orElse: () => const {},
      );
      if (existing.isNotEmpty &&
          !DateTime.parse(
            change['updatedAt'] as String,
          ).isAfter(DateTime.parse(existing['updatedAt'] as String))) {
        continue;
      }
      pushed.add({...change, 'ledger': ledger});
      entries.removeWhere(
        (e) => e['entity'] == change['entity'] && e['id'] == change['id'],
      );
      entries.add({...change, 'sequence': _nextSequence(ledger)});
    }
    final cursor = body['cursor'] as int;
    final pull = body['pull'] == true;
    final changes = pull
        ? (entries.where((e) => (e['sequence'] as int) > cursor).toList()..sort(
            (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int),
          ))
        : <Map<String, dynamic>>[];
    return _json({
      'cursor': changes.isEmpty ? cursor : changes.last['sequence'],
      'changes': changes,
      'hasMore': false,
      'serverTime': DateTime.now().toUtc().toIso8601String(),
    });
  }

  int _nextSequence(String? ledger) =>
      _sequences[ledger] = (_sequences[ledger] ?? 0) + 1;

  http.Response _ledgers(http.Request request) {
    final segments = request.url.pathSegments.skip(2).toList();
    Map<String, dynamic> view(Map<String, dynamic> ledger) => {
      'id': ledger['id'],
      'name': ledger['name'],
      'role': ledger['owner'] == userId ? 'owner' : 'member',
      'members': [
        for (final m in ledger['members'] as List)
          {
            'userId': m,
            'email': '$m@example.com',
            'role': m == ledger['owner'] ? 'owner' : 'member',
          },
      ],
    };
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (segments.isEmpty) {
      if (request.method == 'GET') {
        return _json({
          'ledgers': [
            for (final l in ledgers.values)
              if ((l['members'] as List).contains(userId)) view(l),
          ],
        });
      }
      final id = 'ledger-${++_ledgerCount}';
      ledgers[id] = {
        'id': id,
        'name': body['name'],
        'owner': userId,
        'members': [userId],
      };
      return _json(view(ledgers[id]!));
    }
    if (segments.first == 'join') {
      final id = invites.remove(body['code']);
      if (id == null) return _error(400, 'invalid_code');
      (ledgers[id]!['members'] as List).add(userId);
      return _json(view(ledgers[id]!));
    }
    final ledger = ledgers[segments.first];
    if (ledger == null) return _error(404, 'not_found');
    if (segments.length == 1) {
      if (request.method == 'PATCH') {
        ledger['name'] = body['name'];
        return _json(view(ledger));
      }
      ledgers.remove(ledger['id']);
      return http.Response('', 204);
    }
    if (segments[1] == 'invites') {
      const code = 'ABCDEFGHJK';
      invites[code] = ledger['id'] as String;
      return _json({'code': code, 'expiresAt': '2026-11-07T00:00:00Z'});
    }
    if (segments[1] == 'members') {
      final member = segments[2];
      if (member == ledger['owner'] && (ledger['members'] as List).length > 1) {
        return _error(409, 'owner_cannot_leave');
      }
      (ledger['members'] as List).remove(member);
      return http.Response('', 204);
    }
    return _error(404, 'not_found');
  }
}
