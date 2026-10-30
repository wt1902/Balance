import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// JSON wire objects, deliberately independent of local database models.
typedef WireMap = Map<String, dynamic>;
typedef AccessTokenProvider = Future<String> Function();

class SyncApiException implements Exception {
  const SyncApiException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  // Do not include response bodies, request headers or tokens in diagnostics.
  @override
  String toString() => 'SyncApiException($code, HTTP $statusCode): $message';
}

/// Stateless HTTP transport. Session persistence belongs to the caller's secure
/// store. Never persist returned session maps in preferences or browser storage.
class SyncApi {
  SyncApi({
    required String serverUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    bool allowInsecureHttp = false,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       baseUri = _normalizeServer(serverUrl, allowInsecureHttp);

  final Uri baseUri;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  /// Register/login/refresh return {accessToken, refreshToken, expiresAt,
  /// user: {id, email}}. Refresh rotates both tokens; save the result atomically.
  Future<WireMap> register(String email, String password) =>
      _authenticate('register', email, password);

  Future<WireMap> login(String email, String password) =>
      _authenticate('login', email, password);

  Future<WireMap> _authenticate(
    String action,
    String email,
    String password,
  ) async => _session(await _request('POST', 'v1/auth/$action', body: {
    'email': email.trim(),
    'password': password,
  }));

  Future<WireMap> refresh(String refreshToken) async =>
      _session(await _request('POST', 'v1/auth/refresh', body: {
        'refreshToken': refreshToken,
      }));

  /// Clear the external local session in a finally block, even when offline.
  /// An offline logout cannot revoke the server refresh token.
  Future<void> logout(String refreshToken) async {
    await _request('POST', 'v1/auth/logout', body: {
      'refreshToken': refreshToken,
    });
  }

  Future<WireMap> me(String accessToken) async {
    final result = await _request('GET', 'v1/me', accessToken: accessToken);
    _string(result, 'id');
    _string(result, 'email');
    return result;
  }

  /// One wire request. Push-only calls leave cursor unchanged. The caller must
  /// merge a pulled page durably before committing its returned cursor.
  Future<WireMap> sync({
    required String accessToken,
    required int cursor,
    required String deviceId,
    required List<WireMap> changes,
    bool pull = true,
  }) async {
    _cursor(cursor);
    if (changes.length > 5000) {
      throw ArgumentError('A sync request supports at most 5000 changes');
    }
    for (final change in changes) {
      _validateChange(change, outgoing: true);
    }
    final page = await _request('POST', 'v1/sync', accessToken: accessToken,
      body: _syncBody(cursor, deviceId, changes, pull));
    final next = _integer(page, 'cursor');
    _cursor(next);
    if (next < cursor || page['hasMore'] is! bool || page['changes'] is! List) {
      throw const FormatException('Invalid sync page');
    }
    if (page['hasMore'] == true && next <= cursor) {
      throw const FormatException('Sync cursor did not advance');
    }
    DateTime.parse(_string(page, 'serverTime'));
    final records = <WireMap>[];
    var previousSequence = cursor;
    for (final raw in page['changes'] as List) {
      final change = _object(raw);
      _validateChange(change);
      final sequence = _integer(change, 'sequence');
      if (sequence <= previousSequence || sequence > next) {
        throw const FormatException('Invalid change sequence');
      }
      previousSequence = sequence;
      records.add(change);
    }
    if (records.isNotEmpty && previousSequence != next) {
      throw const FormatException('Cursor does not match the last change');
    }
    if (records.isEmpty && next != cursor) {
      throw const FormatException('Empty page advanced the cursor');
    }
    return {...page, 'changes': records};
  }

  /// Pushes a stable snapshot in bounded batches, then pulls all pages. The
  /// provider may refresh expired tokens through an external session manager.
  /// applyPage must atomically merge changes and persist cursor, and must throw
  /// on failure. Keep the push watermark unchanged until this method succeeds.
  Future<int> synchronize({
    required AccessTokenProvider accessToken,
    required int cursor,
    required String deviceId,
    required List<WireMap> changes,
    required Future<void> Function(List<WireMap> changes, int cursor) applyPage,
  }) async {
    // Copy the complete JSON snapshot before the first await so concurrent edits
    // cannot mutate a batch while it is being uploaded.
    final snapshot = (jsonDecode(jsonEncode(changes)) as List)
        .map(_object).toList(growable: false);
    _cursor(cursor);
    for (final change in snapshot) {
      _validateChange(change, outgoing: true);
    }
    for (var start = 0; start < snapshot.length; start += 100) {
      final end = start + 100 < snapshot.length ? start + 100 : snapshot.length;
      await _pushBatch(accessToken, cursor, deviceId, snapshot.sublist(start, end));
    }
    var next = cursor;
    while (true) {
      final page = await sync(accessToken: await accessToken(), cursor: next,
        deviceId: deviceId, changes: const []);
      next = page['cursor'] as int;
      await applyPage((page['changes'] as List).cast<WireMap>(), next);
      if (page['hasMore'] == false) return next;
    }
  }

  Future<void> _pushBatch(AccessTokenProvider token, int cursor, String deviceId,
      List<WireMap> changes) async {
    final size = utf8.encode(jsonEncode(_syncBody(cursor, deviceId, changes, false))).length;
    if (size > 1500000 && changes.length > 1) {
      final middle = changes.length ~/ 2;
      await _pushBatch(token, cursor, deviceId, changes.sublist(0, middle));
      await _pushBatch(token, cursor, deviceId, changes.sublist(middle));
      return;
    }
    await sync(accessToken: await token(), cursor: cursor, deviceId: deviceId,
      changes: changes, pull: false);
  }

  Future<WireMap> _request(String method, String path, {
    WireMap? body,
    String? accessToken,
  }) async {
    final request = http.Request(method, baseUri.resolve(path));
    request.followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (accessToken != null) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
      if (request.bodyBytes.length > 2 * 1024 * 1024) {
        throw ArgumentError('Request exceeds the server 2 MiB limit');
      }
    }
    final response = await (() async {
      final stream = await _client.send(request);
      return http.Response.fromStream(stream);
    })().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var code = 'http_error';
      var message = 'Server request failed';
      try {
        final detail = _object(_object(jsonDecode(response.body))['error']);
        code = _string(detail, 'code');
        message = _string(detail, 'message');
      } on FormatException {
        // Proxies may return HTML. Never surface raw bodies containing secrets.
      }
      throw SyncApiException(code, message, statusCode: response.statusCode);
    }
    if (response.statusCode == 204) return <String, dynamic>{};
    return _object(jsonDecode(utf8.decode(response.bodyBytes)));
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  static WireMap _syncBody(int cursor, String deviceId,
      List<WireMap> changes, bool pull) => {
    'cursor': cursor, 'deviceId': deviceId, 'changes': changes, 'pull': pull,
  };

  static WireMap _session(WireMap value) {
    _string(value, 'accessToken');
    _string(value, 'refreshToken');
    DateTime.parse(_string(value, 'expiresAt'));
    final user = _object(value['user']);
    _string(user, 'id');
    _string(user, 'email');
    return value;
  }

  static void _validateChange(WireMap change, {bool outgoing = false}) {
    if (!const {'transaction', 'category', 'budget'}.contains(change['entity'])) {
      throw const FormatException('Unknown sync entity');
    }
    final id = _string(change, 'id');
    if (utf8.encode(id).length > 128 || change['deleted'] is! bool) {
      throw const FormatException('Invalid record ID or deletion flag');
    }
    DateTime.parse(_string(change, 'updatedAt'));
    if (change['deleted'] == false) {
      _object(change['payload']);
    }
    if (outgoing) {
      const keys = {'entity', 'id', 'deleted', 'updatedAt', 'payload', 'version', 'sequence'};
      if (change.keys.any((key) => !keys.contains(key))) {
        throw const FormatException('Unknown change property');
      }
      if (change.containsKey('payload') &&
          utf8.encode(jsonEncode(change['payload'])).length > 256 * 1024) {
        throw const FormatException('Payload exceeds 256 KiB');
      }
    }
  }

  static WireMap _object(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return value;
  }

  static String _string(WireMap value, String key) {
    final result = value[key];
    if (result is! String || result.isEmpty) {
      throw FormatException('Missing or invalid $key');
    }
    return result;
  }

  static int _integer(WireMap value, String key) {
    final result = value[key];
    if (result is! int) throw FormatException('Missing or invalid $key');
    return result;
  }

  static void _cursor(int value) {
    // JS numbers cannot faithfully round-trip the full server int64 range.
    if (value < 0 || value > 9007199254740991) {
      throw ArgumentError('Cursor is outside the portable integer range');
    }
  }

  static Uri _normalizeServer(String value, bool allowInsecureHttp) {
    final uri = Uri.parse(value.trim());
    if (!uri.hasAuthority || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment ||
        !(uri.scheme == 'https' || (allowInsecureHttp && uri.scheme == 'http'))) {
      throw ArgumentError('Use an HTTPS server URL without credentials, query or fragment');
    }
    return uri.replace(path: '${uri.path.replaceAll(RegExp(r'/+$'), '')}/');
  }
}
