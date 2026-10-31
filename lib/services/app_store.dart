import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/backup.dart';
import '../domain/currency.dart';
import '../domain/finance.dart';
import '../domain/records.dart';
import '../domain/recurring.dart';
import '../domain/templates.dart';
import '../domain/appearance.dart';
import 'attachment_cache.dart';
import 'launch_actions.dart';
import 'storage.dart';
import 'runtime_lock.dart';
import 'sync_api.dart';
import 'widget_summary.dart';

class AuthSession {
  AuthSession(this.data) {
    if (userId.isEmpty ||
        email.isEmpty ||
        accessToken.isEmpty ||
        refreshToken.isEmpty ||
        expiresAt.millisecondsSinceEpoch <= 0) {
      throw const FormatException('Invalid saved session');
    }
  }
  final Map<String, dynamic> data;
  String get userId => (data['user'] as Map)['id'] as String;
  String get email => (data['user'] as Map)['email'] as String;
  String get accessToken => data['accessToken'] as String;
  String get refreshToken => data['refreshToken'] as String;
  DateTime get expiresAt => DateTime.parse(data['expiresAt'] as String);
}

/// All durable mutations and account transitions share one queue. A pull page
/// writes records, tombstones, dirty changes and cursor in one database commit.
class AppStore extends ChangeNotifier with WidgetsBindingObserver {
  AppStore({
    SnapshotStorage? storage,
    FlutterSecureStorage? secureStorage,
    SyncApi Function(String serverUrl)? apiFactory,
    AttachmentCache? attachmentCache,
    DateTime Function()? clock,
    this.background = false,
  }) : _storage = storage,
       _injectedStorage = storage != null,
       _apiFactory = apiFactory,
       _attachmentCache =
           attachmentCache ??
           (storage != null ? MemoryAttachmentCache() : null),
       _clock = clock ?? DateTime.now,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();
  SnapshotStorage? _storage;
  AttachmentCache? _attachmentCache;

  /// Calendar time for recurring operations and the rate date (§2, §4);
  /// injectable so tests do not depend on the current date.
  final DateTime Function() _clock;
  final bool background;
  final bool _injectedStorage;
  final RuntimeLock _runtimeLock = RuntimeLock();
  AuthSession? _volatileSession;
  String? _volatileRevision;
  String? _volatileServer;
  final SyncApi Function(String serverUrl)? _apiFactory;
  final FlutterSecureStorage _secureStorage;
  SharedPreferences? _preferences;
  Future<void> _tail = Future<void>.value();
  Timer? _timer;
  bool _disposed = false;
  bool ready = false;
  bool syncing = false;
  String? error;
  String? syncMessage;
  DateTime? lastSyncAt;
  String serverUrl = '';
  String currency = 'RUB';
  String theme = 'system';
  String themePreset = 'forest';
  AuthSession? session;
  String? sessionPersistenceWarning;
  String get email => session?.email ?? '';
  String _deviceId = '';
  String _scope = '';
  int _cursor = 0;
  final Map<String, TransactionRecord> _transactions = {};
  final Map<String, CategoryRecord> _categories = {};
  final Map<String, BudgetRecord> _budgets = {};
  final Map<String, AccountRecord> _accounts = {};
  final Map<String, TransferRecord> _transfers = {};
  final Map<String, RecurringRecord> _recurring = {};
  final Map<String, GoalRecord> _goals = {};
  final Map<String, DebtRecord> _debts = {};
  final Map<String, RateRecord> _rates = {};
  final Map<String, SettingRecord> _settings = {};
  final Map<String, AttachmentRecord> _attachments = {};

  /// Attachment files saved locally but not uploaded yet, by sha256:
  /// `{sha256, contentType}`. Their records are pushed only after the PUT.
  final Map<String, Map<String, dynamic>> _uploads = {};

  /// Records of every entity by entity name (see [entityCodecs]).
  late final Map<String, Map<String, SyncRecord>> _collections = {
    'transaction': _transactions,
    'category': _categories,
    'budget': _budgets,
    'account': _accounts,
    'transfer': _transfers,
    'recurring': _recurring,
    'goal': _goals,
    'debt': _debts,
    'rate': _rates,
    'setting': _settings,
    'attachment': _attachments,
  };

  /// What the server supports; null until checked (see [refreshCapabilities]).
  ServerCapabilities? capabilities;
  DateTime? _capabilitiesCheckedAt;

  /// Shared ledgers of the account (§7), as last listed by the server.
  List<Ledger> ledgers = const [];
  String? _ledgersSource;

  /// The shared ledger in use; null for the personal one.
  String? activeLedgerId;
  final Map<String, Map<String, dynamic>> _tombstones = {};
  final Map<String, Map<String, dynamic>> _dirty = {};
  final List<QuarantineEntry> _quarantine = [];
  final List<TransactionTemplate> _templates = [];
  Map<String, String>? _widgetSummary;
  int _skippedFromServer = 0;

  /// Last `ledgerRevision` this engine wrote or loaded. Every storage write
  /// first sets a new one, so an unchanged value means the data in memory and
  /// the open database are current and need no reload.
  String? _ledgerRevision;
  String? _sessionCheckedRevision, _sessionCheckedServer;
  DateTime? _latestChangeAt;
  List<TransactionRecord>? _sortedTransactions;
  BaseTransactions? _baseTransactions;
  BaseAmount? _totalBalance;

  /// Objects as last written, by ledger record key. Records are immutable and
  /// replaced on change, so identity tells what a write must include.
  final Map<String, Object> _persisted = {};
  bool _persistFull = true;

  /// Newest first; cached until the next notification or reload.
  List<TransactionRecord> get transactions =>
      _sortedTransactions ??= List.unmodifiable(
        _transactions.values.toList()..sort((a, b) => b.date.compareTo(a.date)),
      );
  List<CategoryRecord> get categories =>
      _categories.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  List<BudgetRecord> get budgets =>
      _budgets.values.toList()
        ..sort((a, b) => b.monthStart.compareTo(a.monthStart));

  /// By `sortOrder`, then name; archived accounts included.
  List<AccountRecord> get accounts => _accounts.values.toList()
    ..sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
    });

  /// Accounts offered for selection: archived ones are hidden (§3).
  List<AccountRecord> get activeAccounts =>
      accounts.where((a) => !a.isArchived).toList();
  AccountRecord? account(String? id) => _accounts[id];

  /// Newest first.
  List<TransferRecord> get transfers =>
      _transfers.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  List<RecurringRecord> get recurring =>
      _recurring.values.toList()
        ..sort((a, b) => a.startDate.compareTo(b.startDate));
  List<GoalRecord> get goals =>
      _goals.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  List<DebtRecord> get debts =>
      _debts.values.toList()..sort((a, b) => b.date.compareTo(a.date));

  /// Newest first by date.
  List<RateRecord> get rates =>
      _rates.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  List<AttachmentRecord> attachmentsFor(String transactionId) =>
      _attachments.values
          .where((a) => a.transactionId == transactionId)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// True while the file of [attachment] waits for upload.
  bool isUploadPending(AttachmentRecord attachment) =>
      _uploads.containsKey(attachment.sha256);

  /// The synchronized `baseCurrency` setting, else the device currency
  /// (v1 behavior).
  String get baseCurrency {
    final value = _settings[SettingRecord.baseCurrencyKey]?.value;
    return value is String && isCurrencyCode(value) ? value : currency;
  }

  /// Converter with the rates known now (latest rate on the calculation date).
  CurrencyConverter get converter => CurrencyConverter(
    baseCurrency: baseCurrency,
    rates: _rates.values,
    asOf: _clock(),
  );

  /// Transactions in the base currency for analytics and budgets (§2–3);
  /// amounts without a rate are left out. Identical to [transactions]
  /// when everything is in one currency.
  BaseTransactions get baseTransactions => _baseTransactions ??= () {
    final converted = LedgerMath.inBase(
      transactions: transactions,
      accounts: _accounts,
      converter: converter,
    );
    return BaseTransactions(
      List.unmodifiable(converted.items),
      converted.missingRates,
    );
  }();

  /// Total balance in the base currency, with currency pairs that had no rate.
  BaseAmount get totalBalance => _totalBalance ??= LedgerMath.totalBalance(
    transactions: _transactions.values,
    transfers: _transfers.values,
    accounts: _accounts,
    converter: converter,
  );
  int get balanceMinor => totalBalance.minor;

  /// `C→B` pairs without a rate in the balance or analytics.
  Set<String> get missingRates => {
    ...totalBalance.missingRates,
    ...baseTransactions.missingRates,
  };

  /// Balances by account id in each account's currency, including ids of
  /// deleted accounts.
  Map<String, int> get accountBalances =>
      LedgerMath.accountBalances(_transactions.values, _transfers.values);

  /// «Без счёта» by currency.
  Map<String, int> get unassignedBalances =>
      LedgerMath.unassignedBalances(_transactions.values, baseCurrency);
  int goalProgress(GoalRecord goal) =>
      LedgerMath.goalProgress(goal, accountBalances);

  bool get supportsAttachments => capabilities?.attachments ?? false;
  bool get supportsLedgers => capabilities?.ledgers ?? false;
  Ledger? get activeLedger =>
      ledgers.where((l) => l.id == activeLedgerId).firstOrNull;
  int get pendingChangeCount => _dirty.length;

  /// Device-local quick-entry presets, newest first.
  List<TransactionTemplate> get templates => List.unmodifiable(_templates);

  /// Records set aside because they could not be read (see QuarantineEntry).
  List<QuarantineEntry> get quarantine => List.unmodifiable(_quarantine);

  /// True when an imported or restored transaction id is already known,
  /// including one the user deleted afterwards.
  bool knowsTransaction(String id) =>
      _transactions.containsKey(id) ||
      _tombstones.containsKey('transaction:$id');
  int get cursor => _cursor;
  static String newId() => const Uuid().v4();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final result = _tail.then((_) async {
      if (_disposed) throw StateError('AppStore is closed');
      if (!_injectedStorage) await _runtimeLock.acquire();
      try {
        if (ready) await _reloadSharedState();
        final value = await body();
        await _publishWidgetSummary();
        return value;
      } finally {
        if (!_injectedStorage) await _runtimeLock.release();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _notify() {
    _sortedTransactions = null;
    _baseTransactions = null;
    _totalBalance = null;
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    error = null;
    _notify();
  }

  Future<void> initialize() => _exclusive(() async {
    if (ready) return;
    _preferences = await SharedPreferences.getInstance();
    await _preferences!.reload();
    serverUrl = _preferences!.getString('serverUrl') ?? serverUrl;
    currency = _preferences!.getString('currency') ?? currency;
    theme = _preferences!.getString('theme') ?? theme;
    themePreset = ColorPreset.fromId(_preferences!.getString('themePreset')).id;
    _deviceId = _preferences!.getString('deviceId') ?? newId();
    await _preferences!.setString('deviceId', _deviceId);
    _loadTemplates();
    _storage ??= await LedgerStorage.open();
    _attachmentCache ??= await AttachmentCache.open();
    await _restoreSession();
    _loadServerState();
    await _loadScope();
    // Without an account nothing is pulled first; with one, the first sync
    // runs the rules after it pulled other devices' progress.
    if (session == null && _generateRecurring(_clock()) > 0) {
      await _persist();
    }
    if (!background) {
      WidgetsBinding.instance.addObserver(this);
      _timer = Timer.periodic(const Duration(minutes: 2), (_) {
        _backgroundSync();
      });
    }
    ready = true;
    _notify();
    if (!background) _backgroundSync();
  });

  Future<void> _reloadSharedState() async {
    await _preferences!.reload();
    final nextServer = _preferences!.getString('serverUrl') ?? '';
    if (nextServer != serverUrl) {
      _apiInstance?.close();
      _apiInstance = null;
      serverUrl = nextServer;
    }
    currency = _preferences!.getString('currency') ?? 'RUB';
    theme = _preferences!.getString('theme') ?? 'system';
    themePreset = ColorPreset.fromId(_preferences!.getString('themePreset')).id;
    _deviceId = _preferences!.getString('deviceId') ?? _deviceId;
    _loadTemplates();
    await _restoreSession();
    _loadServerState();
    final revision = _preferences!.getString('ledgerRevision');
    if (revision == null || revision != _ledgerRevision) {
      await _storage!.invalidate();
      await _loadScope();
    } else if (_scopeFor(session?.userId) != _scope) {
      await _loadScope();
    }
    _notify();
  }

  Future<void> _restoreSession() async {
    final revision = _preferences!.getString('sessionRevision.$serverUrl');
    // Every credential change sets a new revision; skip the secure read
    // (Keychain/Keystore) when nothing changed since the last check.
    if (revision != null &&
        revision == _sessionCheckedRevision &&
        serverUrl == _sessionCheckedServer) {
      return;
    }
    _sessionCheckedRevision = revision;
    _sessionCheckedServer = serverUrl;
    session = null;
    if (_volatileServer == serverUrl &&
        _volatileRevision == revision &&
        _volatileSession != null) {
      session = _volatileSession;
      return;
    }
    _volatileSession = null;
    _volatileRevision = null;
    _volatileServer = null;
    String? saved;
    try {
      if (!(_preferences!.getBool('sessionDisabled.$serverUrl') ?? false)) {
        saved = await _secureStorage.read(key: _credentialKey);
      }
    } catch (_) {
      _sessionStorageUnavailable();
    }
    if (saved != null) {
      try {
        session = AuthSession(
          Map<String, dynamic>.from(jsonDecode(saved) as Map),
        );
      } catch (_) {
        await _deleteCredentials();
      }
    }
  }

  void _sessionStorageUnavailable() {
    sessionPersistenceWarning =
        'Защищённое хранилище недоступно. Вход действует до закрытия приложения.';
    syncMessage = sessionPersistenceWarning;
  }

  Future<void> _saveCredentials(Map<String, dynamic> value) async {
    try {
      await _secureStorage.write(key: _credentialKey, value: jsonEncode(value));
      await _preferences!.setBool('sessionDisabled.$serverUrl', false);
      await _preferences!.setString('sessionRevision.$serverUrl', newId());
      _volatileSession = null;
      _volatileRevision = null;
      _volatileServer = null;
    } catch (_) {
      await _preferences!.setBool('sessionDisabled.$serverUrl', true);
      _volatileRevision = newId();
      await _preferences!.setString(
        'sessionRevision.$serverUrl',
        _volatileRevision!,
      );
      _volatileSession = AuthSession(value);
      _volatileServer = serverUrl;
      _sessionStorageUnavailable();
    }
  }

  Future<void> _deleteCredentials() async {
    // A failed secure delete must not restore a signed-out account next launch.
    await _preferences!.setBool('sessionDisabled.$serverUrl', true);
    await _preferences!.setString('sessionRevision.$serverUrl', newId());
    _volatileSession = null;
    _volatileRevision = null;
    _volatileServer = null;
    try {
      await _secureStorage.delete(key: _credentialKey);
    } catch (_) {
      _sessionStorageUnavailable();
    }
  }

  String get _credentialKey =>
      'balance.session.${Uri.encodeComponent(serverUrl)}';

  /// Data scope: server + user + ledger (§7). The personal ledger keeps the
  /// v1 key, so existing data stays where it was.
  String _scopeFor(String? userId) {
    final personal = '$serverUrl|${userId ?? 'guest'}';
    final ledger = userId == null ? null : _savedLedger(userId);
    return ledger == null ? personal : '$personal|ledger:$ledger';
  }

  String _ledgerPreference(String userId) => 'activeLedger.$serverUrl|$userId';
  String? _savedLedger(String userId) =>
      _preferences?.getString(_ledgerPreference(userId));

  /// Capabilities and the ledger list cached per server and account.
  void _loadServerState() {
    final prefs = _preferences!;
    try {
      final raw = prefs.getString('capabilities.$serverUrl');
      capabilities = raw == null
          ? null
          : ServerCapabilities.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map),
            );
    } catch (_) {
      capabilities = null;
    }
    final user = session?.userId;
    activeLedgerId = user == null ? null : _savedLedger(user);
    final key = user == null ? null : 'ledgers.$serverUrl|$user';
    final raw = key == null ? null : prefs.getString(key);
    // Unchanged since loaded or saved here: keep the list with its members.
    if ('$key=$raw' == _ledgersSource) return;
    _ledgersSource = '$key=$raw';
    try {
      ledgers = raw == null
          ? const []
          : [
              for (final item in jsonDecode(raw) as List)
                Ledger.fromJson(Map<String, dynamic>.from(item as Map)),
            ];
    } catch (_) {
      ledgers = const [];
    }
  }

  SyncApi? _apiInstance;
  SyncApi get _api => _apiInstance ??=
      _apiFactory?.call(serverUrl) ??
      SyncApi(
        serverUrl: serverUrl,
        allowInsecureHttp: [
          'localhost',
          '127.0.0.1',
          '::1',
          '10.0.2.2',
        ].contains(Uri.parse(serverUrl).host),
      );

  List<CategoryRecord> categoriesForKind(Object kind) {
    final raw = kind is TransactionKind ? kind.name : kind.toString();
    final combined = <String, CategoryRecord>{
      for (final category in BuiltInCategories.forKind(raw))
        category.name: category,
      for (final category in categories.where((c) => c.kindRawValue == raw))
        category.name: category,
    };
    return combined.values.toList();
  }

  Future<void> _loadScope() async {
    _scope = _scopeFor(session?.userId);
    _ledgerRevision = _preferences?.getString('ledgerRevision');
    _sortedTransactions = null;
    _baseTransactions = null;
    _totalBalance = null;
    _persisted.clear();
    _persistFull = true;
    final raw = await _storage!.read(_scope);
    for (final collection in _collections.values) {
      collection.clear();
    }
    _uploads.clear();
    _dirty.clear();
    _tombstones.clear();
    _cursor = 0;
    _latestChangeAt = null;
    lastSyncAt = null;
    _quarantine
      ..clear()
      ..addAll(await _readQuarantine());
    if (raw == null) return;
    // A damaged record is set aside instead of failing startup for the whole
    // ledger. It stays in the snapshot until the quarantine copy is durable.
    final damaged = <QuarantineEntry>[];
    void load(String section, void Function(Map<String, dynamic>) apply) {
      final items = raw[section];
      if (items == null) return;
      if (items is! List) {
        damaged.add(
          _damaged('local', section, const FormatException('Не список'), items),
        );
        return;
      }
      for (final item in items) {
        try {
          apply(Map<String, dynamic>.from(item as Map));
        } catch (e) {
          damaged.add(_damaged('local', section, e, item));
        }
      }
    }

    for (final codec in entityCodecs.values) {
      final target = _collections[codec.entity]!;
      load(codec.section, (json) {
        final record = codec.fromJson(json);
        target[record.id] = record;
      });
    }
    load('uploads', (json) {
      final sha = json['sha256'];
      if (sha is! String || !AttachmentRecord.isSha256(sha)) {
        throw const FormatException('Неверный SHA-256');
      }
      _uploads[sha] = json;
    });
    load('dirty', (json) {
      _dirty[_key(_validChange(json))] = json;
      _noteChangeTime(json);
    });
    load('tombstones', (json) => _tombstones[_key(_validChange(json))] = json);
    final cursor = raw['cursor'];
    // An unreadable cursor only costs a full pull, never local records.
    _cursor = cursor is num && cursor >= 0 ? cursor.toInt() : 0;
    final syncedAt = raw['lastSyncAt'];
    lastSyncAt = syncedAt is String ? DateTime.tryParse(syncedAt) : null;
    // A legacy single snapshot is rewritten per record on the next write;
    // damaged records are dropped by a full rewrite too.
    if (raw[ledgerLayoutKey] == ledgerLayout && damaged.isEmpty) {
      _persisted.addAll(_ledgerObjects());
      _persistFull = false;
    }
    if (damaged.isEmpty) return;
    try {
      await _addQuarantine(damaged);
    } catch (_) {
      // Keep the snapshot untouched; the next load retries the quarantine.
      return;
    }
    try {
      await _persist();
    } catch (_) {}
    error =
        'Повреждённые записи отложены: ${damaged.length}. Подробности — в Настройках, раздел «Данные».';
  }

  Map<String, dynamic> _validChange(Map<String, dynamic> change) {
    final id = change['id'];
    if (!syncEntities.contains(change['entity']) ||
        id is! String ||
        id.isEmpty ||
        change['deleted'] is! bool ||
        (change['deleted'] == false && change['payload'] is! Map)) {
      throw const FormatException('Некорректное изменение синхронизации');
    }
    DateTime.parse(change['updatedAt'] as String);
    return change;
  }

  QuarantineEntry _damaged(
    String source,
    String section,
    Object error,
    Object? raw,
  ) => QuarantineEntry(
    source: source,
    section: section,
    reason: describeRecordError(error),
    detectedAt: DateTime.now().toUtc(),
    raw: raw,
  );

  String get _quarantineKey => '$_scope#quarantine';

  Future<List<QuarantineEntry>> _readQuarantine() async {
    try {
      final raw = await _storage!.read(_quarantineKey);
      return [
        for (final item in (raw?['items'] as List? ?? []))
          QuarantineEntry.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _addQuarantine(List<QuarantineEntry> entries) async {
    String identity(QuarantineEntry entry) {
      try {
        return '${entry.source}|${entry.section}|${jsonEncode(entry.raw)}';
      } catch (_) {
        return '${entry.source}|${entry.section}|${entry.raw}';
      }
    }

    final next = [..._quarantine];
    final seen = {for (final entry in next) identity(entry)};
    for (final entry in entries) {
      if (seen.add(identity(entry))) next.add(entry);
    }
    await _write(_quarantineKey, {
      'items': next.map((entry) => entry.toJson()).toList(),
    });
    _quarantine
      ..clear()
      ..addAll(next);
  }

  /// Report for the user to keep or repair by hand. Contains finance data only.
  Map<String, dynamic> quarantineReport() => {
    'format': 'balance-quarantine',
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'items': _quarantine.map((entry) => entry.toJson()).toList(),
  };

  Future<void> clearQuarantine() => _exclusive(() async {
    await _write(_quarantineKey, {'items': <Object>[]});
    _quarantine.clear();
    _notify();
  });

  Map<String, dynamic> _snapshot() => {
    for (final codec in entityCodecs.values)
      codec.section: _collections[codec.entity]!.values
          .map((e) => e.toJson())
          .toList(),
    'uploads': _uploads.values.toList(),
    'dirty': _dirty.values.toList(),
    'tombstones': _tombstones.values.toList(),
    'cursor': _cursor,
    'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
  };
  Map<String, Object> _ledgerObjects() => {
    for (final codec in entityCodecs.values)
      for (final e in _collections[codec.entity]!.entries)
        '${codec.prefix}:${e.key}': e.value,
    for (final e in _uploads.entries) 'u:${e.key}': e.value,
    for (final e in _dirty.entries) 'd:${e.key}': e.value,
    for (final e in _tombstones.entries) 'x:${e.key}': e.value,
  };

  /// Writes only records that changed since the last write, with the cursor,
  /// in one storage transaction.
  Future<void> _persist() async {
    final current = _ledgerObjects();
    final full = _persistFull;
    final upserts = <String, Map<String, dynamic>>{};
    for (final entry in current.entries) {
      if (!full && identical(_persisted[entry.key], entry.value)) continue;
      upserts[entry.key] = switch (entry.value) {
        final SyncRecord r => r.toJson(),
        final value => value as Map<String, dynamic>,
      };
    }
    final delta = LedgerDelta(
      upserts: upserts,
      deletes: full
          ? const []
          : [
              for (final key in _persisted.keys)
                if (!current.containsKey(key)) key,
            ],
      meta: {
        'cursor': _cursor,
        'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
      },
      replace: full,
    );
    await _announceWrite();
    await _storage!.writeLedger(_scope, delta);
    _persisted
      ..clear()
      ..addAll(current);
    _persistFull = false;
  }

  Future<void> _announceWrite() async {
    final revision = newId();
    await _preferences!.setString('ledgerRevision', revision);
    _ledgerRevision = revision;
  }

  /// Every storage write announces a new revision first, so other engines
  /// reload even if this process dies before the write lands.
  Future<void> _write(String key, Map<String, dynamic> value) async {
    await _announceWrite();
    await _storage!.write(key, value);
  }

  /// A complete ledger for another or a new scope, stored per record.
  Future<void> _writeSnapshot(
    String scope,
    Map<String, dynamic> snapshot,
  ) async {
    await _announceWrite();
    await _storage!.writeLedger(scope, LedgerDelta.fromSnapshot(snapshot));
  }

  String _key(Map<String, dynamic> change) =>
      '${change['entity']}:${change['id']}';
  Map<String, dynamic> _change(
    String entity,
    String id,
    DateTime time,
    Map<String, dynamic>? payload,
  ) => {
    'entity': entity,
    'id': id,
    'updatedAt': time.toUtc().toIso8601String(),
    'deleted': payload == null,
    'payload': ?payload,
  };
  DateTime _now() {
    // Strictly advance local timestamps even for successive edits in one tick.
    var now = DateTime.now().toUtc();
    final latest = _latestChangeAt;
    if (latest != null && !now.isAfter(latest)) {
      now = latest.add(const Duration(microseconds: 1));
    }
    return now;
  }

  /// Tracks the newest queued timestamp, so [_now] needs no scan of the queue.
  void _noteChangeTime(Map<String, dynamic> change) {
    final at = DateTime.parse(change['updatedAt'] as String);
    if (_latestChangeAt == null || at.isAfter(_latestChangeAt!)) {
      _latestChangeAt = at;
    }
  }

  void _queueChange(Map<String, dynamic> change) {
    _noteChangeTime(change);
    final key = _key(change);
    _dirty[key] = change;
    if (change['deleted'] == true) {
      _tombstones[key] = change;
    } else {
      _tombstones.remove(key);
    }
  }

  Future<void> _edited() async {
    try {
      await _persist();
    } catch (_) {
      await _loadScope();
      rethrow;
    }
    _notify();
  }

  /// Puts [record] with a fresh `updatedAt` and queues it for sync.
  T _put<T extends SyncRecord>(String entity, T record, {DateTime? at}) {
    final saved = record.stamped(at ?? _now()) as T;
    _collections[entity]![saved.id] = saved;
    _queueChange(_change(entity, saved.id, saved.updatedAt, saved.payload()));
    return saved;
  }

  void _check(bool valid, String message) {
    if (!valid) throw ArgumentError(message);
  }

  /// Rules shared by saving and restoring a record. Returns the record in
  /// its normalized form; throws [ArgumentError] when it is not valid.
  SyncRecord _validated(SyncRecord record) {
    switch (record) {
      case TransactionRecord r:
        _check(r.amountMinor > 0, 'Сумма должна быть больше нуля');
        _check(
          r.currency == null || isCurrencyCode(r.currency!),
          'Неверный код валюты',
        );
        return r.copyWith(tags: TagRules.validate(r.tags));
      case AccountRecord r:
        _check(r.name.trim().isNotEmpty, 'Введите название счёта');
        _check(
          r.currency == null || isCurrencyCode(r.currency!),
          'Неверный код валюты',
        );
        return r.copyWith(name: r.name.trim());
      case TransferRecord r:
        _check(
          r.fromAccountId.isNotEmpty && r.toAccountId.isNotEmpty,
          'Выберите оба счёта',
        );
        _check(r.fromAccountId != r.toAccountId, 'Счета должны различаться');
        _check(
          r.amountMinor > 0 && r.toAmountMinor > 0,
          'Сумма должна быть больше нуля',
        );
        return r;
      case RecurringRecord r:
        _check(r.amountMinor > 0, 'Сумма должна быть больше нуля');
        _check(r.categoryName.trim().isNotEmpty, 'Выберите категорию');
        _check(r.frequency != null, 'Неизвестная периодичность');
        _check(r.interval >= 1, 'Интервал — не меньше 1');
        _check(r.mode != null, 'Неизвестный режим');
        _check(
          r.endDate == null || !r.endDate!.isBefore(r.startDate),
          'Дата окончания раньше начала',
        );
        _check(
          r.currency == null || isCurrencyCode(r.currency!),
          'Неверный код валюты',
        );
        return r.copyWith(tags: TagRules.validate(r.tags));
      case GoalRecord r:
        _check(r.name.trim().isNotEmpty, 'Введите название цели');
        _check(r.targetMinor > 0, 'Цель должна быть больше нуля');
        _check(r.savedMinor >= 0, 'Накоплено не может быть меньше нуля');
        return r.copyWith(name: r.name.trim());
      case DebtRecord r:
        _check(r.person.trim().isNotEmpty, 'Укажите, кто должен');
        _check(r.amountMinor > 0, 'Сумма должна быть больше нуля');
        _check(r.repaidMinor >= 0, 'Возвращено не может быть меньше нуля');
        _check(r.direction != null, 'Неизвестное направление долга');
        return r.copyWith(person: r.person.trim());
      case RateRecord r:
        _check(
          isCurrencyCode(r.from) && isCurrencyCode(r.to),
          'Неверный код валюты',
        );
        _check(r.from != r.to, 'Валюты должны различаться');
        return r;
      case AttachmentRecord r:
        _check(AttachmentRecord.isSha256(r.sha256), 'Неверный SHA-256');
        _check(r.transactionId.isNotEmpty, 'Нет операции');
        _check(r.size >= 0, 'Неверный размер');
        return r;
      default:
        return record;
    }
  }

  Future<void> saveTransaction(TransactionRecord record) =>
      _exclusive(() async {
        _put('transaction', _validated(record) as TransactionRecord);
        await _edited();
      });
  Future<void> deleteTransaction(String id) => _delete('transaction', id);
  Future<void> deleteBudget(String id) => _delete('budget', id);
  Future<void> deleteCategory(String id) => _delete('category', id);

  /// Transactions and transfers of a deleted account stay (§3).
  Future<void> deleteAccount(String id) => _delete('account', id);
  Future<void> deleteTransfer(String id) => _delete('transfer', id);

  /// Transactions the rule already created stay.
  Future<void> deleteRecurring(String id) => _delete('recurring', id);
  Future<void> deleteGoal(String id) => _delete('goal', id);
  Future<void> deleteDebt(String id) => _delete('debt', id);
  Future<void> deleteRate(String id) => _delete('rate', id);
  Future<void> deleteAttachment(String id) => _delete('attachment', id);
  Future<void> _delete(String entity, String id) => _exclusive(() async {
    if (entity == 'category') {
      final category = _categories[id];
      if (category != null && category.kindRawValue == 'expense') {
        for (final budget
            in _budgets.values
                .where((b) => b.categoryName == category.name)
                .toList()) {
          _budgets.remove(budget.id);
          _queueChange(_change('budget', budget.id, _now(), null));
        }
      }
    }
    if (entity == 'transaction') {
      for (final attachment
          in _attachments.values.where((a) => a.transactionId == id).toList()) {
        _removeAttachment(attachment);
      }
    }
    if (entity == 'attachment') {
      final attachment = _attachments[id];
      if (attachment != null) {
        _removeAttachment(attachment);
        await _edited();
        return;
      }
    }
    _collections[entity]!.remove(id);
    _queueChange(_change(entity, id, _now(), null));
    await _edited();
  });

  /// A file never uploaded is not uploaded after its record is gone. The
  /// local copy stays: another ledger may use the same file.
  void _removeAttachment(AttachmentRecord attachment) {
    _attachments.remove(attachment.id);
    _queueChange(_change('attachment', attachment.id, _now(), null));
    if (!_attachments.values.any((a) => a.sha256 == attachment.sha256)) {
      _uploads.remove(attachment.sha256);
    }
  }

  Future<void> saveCategory(CategoryRecord record) => _exclusive(() async {
    if (record.name.trim().isEmpty) {
      throw ArgumentError('Введите название категории');
    }
    final saved = record.copyWith(name: record.name.trim(), updatedAt: _now());
    if (_categories.values.any(
      (c) =>
          c.id != saved.id &&
          c.name == saved.name &&
          c.kindRawValue == saved.kindRawValue,
    )) {
      throw ArgumentError('Такая категория уже существует');
    }
    final previous = _categories[saved.id];
    _categories[saved.id] = saved;
    _queueChange(
      _change('category', saved.id, saved.updatedAt, saved.payload()),
    );
    if (previous != null) {
      for (final tx in _transactions.values.toList()) {
        if (tx.categoryName != previous.name ||
            tx.kindRawValue != previous.kindRawValue) {
          continue;
        }
        final changed = tx.copyWith(
          categoryName: saved.name,
          categoryIcon: saved.icon,
          categoryEmoji: saved.emoji,
          categoryColorName: saved.colorName,
          updatedAt: saved.updatedAt,
        );
        _transactions[tx.id] = changed;
        _queueChange(
          _change('transaction', tx.id, changed.updatedAt, changed.payload()),
        );
      }
      for (final budget in _budgets.values.toList()) {
        if (budget.categoryName != previous.name) continue;
        final changed = budget.copyWith(
          categoryName: saved.name,
          categoryIcon: saved.icon,
          categoryEmoji: saved.emoji,
          updatedAt: saved.updatedAt,
        );
        _budgets[budget.id] = changed;
        _queueChange(
          _change('budget', budget.id, changed.updatedAt, changed.payload()),
        );
      }
      // Recurring rules carry the same category snapshot as transactions.
      for (final rule in _recurring.values.toList()) {
        if (rule.categoryName != previous.name ||
            rule.kindRawValue != previous.kindRawValue) {
          continue;
        }
        _put(
          'recurring',
          rule.copyWith(
            categoryName: saved.name,
            categoryIcon: saved.icon,
            categoryEmoji: saved.emoji,
            categoryColorName: saved.colorName,
          ),
          at: saved.updatedAt,
        );
      }
    }
    await _edited();
  });
  Future<void> saveBudget(BudgetRecord record) => _exclusive(() async {
    if (record.limitMinor <= 0) {
      throw ArgumentError('Лимит должен быть больше нуля');
    }
    final localMonth = record.monthStart.toLocal();
    final month = DateTime(localMonth.year, localMonth.month);
    if (_budgets.values.any(
      (b) =>
          b.id != record.id &&
          b.categoryName == record.categoryName &&
          b.monthStart.toLocal().year == month.year &&
          b.monthStart.toLocal().month == month.month,
    )) {
      throw ArgumentError('Бюджет для этой категории уже существует');
    }
    final saved = record.copyWith(monthStart: month, updatedAt: _now());
    _budgets[saved.id] = saved;
    _queueChange(_change('budget', saved.id, saved.updatedAt, saved.payload()));
    await _edited();
  });

  /// Creates an adjustment so the total balance — or, with [accountId], that
  /// account's balance in its currency — becomes [targetMinor].
  Future<void> adjustBalance(
    int targetMinor, {
    String note = '',
    String? accountId,
  }) => _exclusive(() async {
    final current = accountId == null
        ? balanceMinor
        : accountBalances[accountId] ?? 0;
    final delta = targetMinor - current;
    if (delta == 0) return;
    final now = _now();
    final record = TransactionRecord(
      id: newId(),
      amountMinor: delta.abs(),
      date: now,
      categoryName: 'Корректировка',
      updatedAt: now,
      note: note.isEmpty ? 'Ручная корректировка баланса' : note,
      isBalanceAdjustment: true,
      kindRawValue: delta > 0 ? 'income' : 'expense',
      accountId: accountId,
    );
    _transactions[record.id] = record;
    _queueChange(_change('transaction', record.id, now, record.payload()));
    await _edited();
  });

  Future<void> saveAccount(AccountRecord record) => _exclusive(() async {
    _put('account', _validated(record) as AccountRecord);
    await _edited();
  });

  Future<void> saveTransfer(TransferRecord record) => _exclusive(() async {
    _put('transfer', _validated(record) as TransferRecord);
    await _edited();
  });

  Future<void> saveGoal(GoalRecord record) => _exclusive(() async {
    _put('goal', _validated(record) as GoalRecord);
    await _edited();
  });

  Future<void> saveDebt(DebtRecord record) => _exclusive(() async {
    _put('debt', _validated(record) as DebtRecord);
    await _edited();
  });

  Future<void> saveRate(RateRecord record) => _exclusive(() async {
    _put('rate', _validated(record) as RateRecord);
    await _edited();
  });

  /// Saves the rule and, in `auto` mode, creates its occurrences due by now.
  Future<void> saveRecurring(RecurringRecord record) => _exclusive(() async {
    _put('recurring', _validated(record) as RecurringRecord);
    _generateRecurring(_clock(), only: record.id);
    await _edited();
  });

  /// Synchronized base currency (§1 setting); null returns to the device
  /// currency.
  Future<void> setBaseCurrency(String? code) => _exclusive(() async {
    const key = SettingRecord.baseCurrencyKey;
    if (code == null) {
      if (_settings.remove(key) == null) return;
      _queueChange(_change('setting', key, _now(), null));
    } else {
      final normalized = code.trim().toUpperCase();
      _check(isCurrencyCode(normalized), 'Неверный код валюты');
      final current = _settings[key];
      _put(
        'setting',
        current?.copyWith(value: normalized) ??
            SettingRecord(id: key, value: normalized, updatedAt: _now()),
      );
    }
    await _edited();
  });

  /// Creates transactions of `auto` rules due by [now] (the clock by
  /// default) and returns how many were created.
  Future<int> generateRecurring({DateTime? now}) => _exclusive(() async {
    final created = _generateRecurring(now ?? _clock());
    if (created > 0) await _edited();
    return created;
  });

  /// Creates the due occurrences of `auto` rules (§4) and moves each rule's
  /// `generatedThrough` to the last processed one. An id already known —
  /// created by another device or deleted by the user — is not created again.
  int _generateRecurring(DateTime now, {String? only}) {
    var created = 0;
    for (final rule in _recurring.values.toList()) {
      if (only != null && rule.id != only) continue;
      if (rule.mode != RecurringMode.auto || rule.amountMinor <= 0) continue;
      final due = RecurringEngine.due(rule, now);
      if (due.isEmpty) continue;
      for (final occurrence in due) {
        if (knowsTransaction(occurrence.transactionId)) continue;
        _put('transaction', occurrence.toTransaction(_now()));
        created++;
      }
      _put('recurring', rule.copyWith(generatedThrough: due.last.occurrence));
    }
    return created;
  }

  /// Occurrences of `remind` rules waiting for «Записать» or «Пропустить»,
  /// oldest first.
  List<RecurringOccurrence> pendingRecurring({DateTime? now}) => [
    for (final rule in recurring)
      if (rule.mode == RecurringMode.remind)
        for (final occurrence in RecurringEngine.due(rule, now ?? _clock()))
          if (!knowsTransaction(occurrence.transactionId)) occurrence,
  ];

  RecurringOccurrence _dueOccurrence(
    String recurringId,
    String occurrence,
    DateTime now,
  ) {
    final rule = _recurring[recurringId];
    if (rule == null) throw ArgumentError('Регулярная операция не найдена');
    final match = RecurringEngine.due(
      rule,
      now,
    ).where((o) => o.occurrence == occurrence).firstOrNull;
    if (match == null) throw ArgumentError('Повторение не ожидает решения');
    return match;
  }

  /// «Записать»: creates the occurrence's transaction with its deterministic
  /// id. [edit] may change the amount, date or note before it is saved.
  Future<TransactionRecord> confirmRecurring(
    String recurringId,
    String occurrence, {
    TransactionRecord Function(TransactionRecord)? edit,
    DateTime? now,
  }) => _exclusive(() async {
    final at = now ?? _clock();
    final due = _dueOccurrence(recurringId, occurrence, at);
    if (knowsTransaction(due.transactionId)) {
      throw ArgumentError('Повторение уже записано');
    }
    var record = due.toTransaction(_now());
    if (edit != null) record = edit(record).copyWith(id: record.id);
    final saved = _put('transaction', _validated(record) as TransactionRecord);
    _advanceReminder(recurringId, at);
    await _edited();
    return saved;
  });

  /// «Пропустить»: moves `generatedThrough` to [occurrence], so it and any
  /// earlier waiting occurrence are no longer offered.
  Future<void> skipRecurring(
    String recurringId,
    String occurrence, {
    DateTime? now,
  }) => _exclusive(() async {
    final at = now ?? _clock();
    _dueOccurrence(recurringId, occurrence, at);
    _put(
      'recurring',
      _recurring[recurringId]!.copyWith(generatedThrough: occurrence),
    );
    _advanceReminder(recurringId, at);
    await _edited();
  });

  /// Moves `generatedThrough` over occurrences already recorded, so it
  /// always marks the end of a fully handled prefix.
  void _advanceReminder(String recurringId, DateTime now) {
    final rule = _recurring[recurringId]!;
    String? through;
    for (final occurrence in RecurringEngine.due(rule, now)) {
      if (!knowsTransaction(occurrence.transactionId)) break;
      through = occurrence.occurrence;
    }
    if (through != null) {
      _put('recurring', rule.copyWith(generatedThrough: through));
    }
  }

  /// Default limits of §0 capabilities until the server reports its own.
  static const attachmentTypes = {
    'image/jpeg',
    'image/png',
    'image/heic',
    'application/pdf',
  };
  static const attachmentMaxBytes = 10485760;

  /// Saves the file locally and its record; the bytes are uploaded on the
  /// next sync before the record is pushed (§8).
  Future<AttachmentRecord> addAttachment({
    required String transactionId,
    required Uint8List bytes,
    required String contentType,
    String name = '',
  }) => _exclusive(() async {
    if (!_transactions.containsKey(transactionId)) {
      throw ArgumentError('Операция не найдена');
    }
    final caps = capabilities;
    final types = caps != null && caps.attachments
        ? caps.attachmentTypes
        : attachmentTypes;
    final maxBytes = caps != null && caps.attachments
        ? caps.attachmentMaxBytes
        : attachmentMaxBytes;
    final type = contentType.split(';').first.trim().toLowerCase();
    _check(types.contains(type), 'Такой тип файла не поддерживается');
    _check(bytes.isNotEmpty, 'Пустой файл');
    _check(bytes.length <= maxBytes, 'Файл больше допустимого размера');
    final sha = AttachmentCache.hash(bytes);
    await _attachmentCache!.write(sha, bytes);
    final now = _now();
    final record = _put(
      'attachment',
      AttachmentRecord(
        id: newId(),
        transactionId: transactionId,
        sha256: sha,
        contentType: type,
        size: bytes.length,
        name: name,
        createdAt: now,
        updatedAt: now,
      ),
      at: now,
    );
    _uploads[sha] = {'sha256': sha, 'contentType': type};
    await _edited();
    return record;
  });

  /// The file of [attachment]: from the device, else downloaded from the
  /// active ledger and kept (§8).
  Future<Uint8List> attachmentBytes(AttachmentRecord attachment) =>
      _exclusive(() async {
        final cached = await _attachmentCache!.read(attachment.sha256);
        if (cached != null) return cached;
        if (session == null) {
          throw StateError('Файл ещё не загружен на это устройство');
        }
        final file = await _authorized(
          (token) => _api.downloadAttachment(
            accessToken: token,
            sha256: attachment.sha256,
            ledgerId: activeLedgerId,
          ),
        );
        if (AttachmentCache.hash(file.bytes) != attachment.sha256) {
          throw const FormatException('Файл повреждён: SHA-256 не совпадает');
        }
        await _attachmentCache!.write(attachment.sha256, file.bytes);
        return file.bytes;
      });

  /// Lossless copy of the current ledger's records, including deletions.
  /// Sync state (queue, cursor, pending uploads) is per device and
  /// deliberately not included; attachment files are not either.
  Future<Map<String, dynamic>> exportBackup() => _exclusive(
    () async => {
      'format': backupFormat,
      'version': backupVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'data': {
        for (final codec in entityCodecs.values)
          codec.section: _collections[codec.entity]!.values
              .map((e) => e.toJson())
              .toList(),
        'tombstones': _tombstones.values.toList(),
      },
    },
  );

  /// Dry run of [restoreBackup]: what each record would do, without changes.
  Future<BackupPlan> previewBackup(Object? decoded) => _exclusive(() async {
    final data = backupData(decoded);
    final collections = {
      for (final entry in _collections.entries) entry.key: Map.of(entry.value),
    };
    final dirty = Map.of(_dirty);
    final tombstones = Map.of(_tombstones);
    final latest = _latestChangeAt;
    final plan = <BackupPlanItem>[];
    final BackupRestoreResult result;
    try {
      result = _restoreRecords(data, plan: plan);
    } finally {
      for (final entry in collections.entries) {
        // Copied entry by entry: each map keeps its own record type.
        final target = _collections[entry.key]!..clear();
        entry.value.forEach((id, record) => target[id] = record);
      }
      _dirty
        ..clear()
        ..addAll(dirty);
      _tombstones
        ..clear()
        ..addAll(tombstones);
      _latestChangeAt = latest;
    }
    return BackupPlan(
      plan,
      invalid: result.invalid,
      unchanged:
          result.skipped -
          plan.where((i) => i.action == BackupAction.skip).length,
    );
  });

  /// Merges a backup by last-write-wins on updatedAt, keeping the backup's
  /// timestamps: newer device records and later deletions win, and the server
  /// resolves the queued changes with the same rule on the next sync. With
  /// [only], records whose `entity:id` key is not listed are left out.
  Future<BackupRestoreResult> restoreBackup(
    Object? decoded, {
    Set<String>? only,
  }) => _exclusive(() async {
    final result = _restoreRecords(backupData(decoded), only: only);
    if (result.changed > 0) await _edited();
    return result;
  });

  /// Why a restored record would duplicate another one, or null.
  String? _duplicate(SyncRecord record) => switch (record) {
    CategoryRecord r =>
      _categories.values.any(
            (c) =>
                c.id != r.id &&
                c.name == r.name &&
                c.kindRawValue == r.kindRawValue,
          )
          ? 'Категория с таким названием уже есть'
          : null,
    BudgetRecord r => () {
      final month = r.monthStart.toLocal();
      return _budgets.values.any(
            (b) =>
                b.id != r.id &&
                b.categoryName == r.categoryName &&
                b.monthStart.toLocal().year == month.year &&
                b.monthStart.toLocal().month == month.month,
          )
          ? 'Бюджет на этот месяц уже есть'
          : null;
    }(),
    _ => null,
  };

  BackupRestoreResult _restoreRecords(
    Map<String, dynamic> data, {
    List<BackupPlanItem>? plan,
    Set<String>? only,
  }) {
    final result = BackupRestoreResult();
    List<Map<String, dynamic>> items(String section) {
      final value = data[section];
      if (value is! List) {
        if (value != null) result.invalid++;
        return const [];
      }
      return [
        for (final item in value)
          if (item is Map)
            Map<String, dynamic>.from(item)
          else
            <String, dynamic>{},
      ];
    }

    String? older(String key, DateTime? local, DateTime incoming) {
      final tombstone = _tombstones[key];
      if (tombstone != null &&
          !incoming.isAfter(DateTime.parse(tombstone['updatedAt'] as String))) {
        return 'Удалено на устройстве позже';
      }
      return local == null || incoming.isAfter(local)
          ? null
          : 'На устройстве та же или более новая версия';
    }

    // Categories, budgets and transactions keep the v1 order; v2 entities
    // follow, settings and rates first.
    const order = [
      'category',
      'budget',
      'transaction',
      'setting',
      'rate',
      'account',
      'transfer',
      'recurring',
      'goal',
      'debt',
      'attachment',
    ];
    for (final entity in order) {
      final codec = entityCodecs[entity]!;
      final target = _collections[entity]!;
      for (final json in items(codec.section)) {
        final SyncRecord record;
        try {
          final parsed = codec.fromJson(json);
          if (parsed is CategoryRecord && parsed.name.trim().isEmpty) {
            throw const FormatException('Пустое название');
          }
          if (parsed is BudgetRecord && parsed.limitMinor <= 0) {
            throw const FormatException('Лимит должен быть больше нуля');
          }
          // Validation may normalize; the backup's updatedAt is kept.
          record = _validated(parsed).stamped(parsed.updatedAt);
        } catch (_) {
          result.invalid++;
          continue;
        }
        final key = '$entity:${record.id}';
        final local = target[record.id];
        final reason =
            older(key, local?.updatedAt, record.updatedAt) ??
            _duplicate(record);
        if (reason != null || (only != null && !only.contains(key))) {
          result.skipped++;
          if (reason != null) {
            plan?.add(
              BackupPlanItem(
                entity: entity,
                id: record.id,
                action: BackupAction.skip,
                record: record,
                reason: reason,
              ),
            );
          }
          continue;
        }
        target[record.id] = record;
        _queueChange(
          _change(entity, record.id, record.updatedAt, record.payload()),
        );
        local == null ? result.added++ : result.updated++;
        plan?.add(
          BackupPlanItem(
            entity: entity,
            id: record.id,
            action: local == null ? BackupAction.add : BackupAction.update,
            record: record,
          ),
        );
      }
    }
    for (final json in items('tombstones')) {
      try {
        final change = _validChange(json);
        if (change['deleted'] != true) {
          throw const FormatException('Not a deletion');
        }
        final entity = change['entity'] as String;
        final id = change['id'] as String;
        final at = DateTime.parse(change['updatedAt'] as String);
        final target = _collections[entity]!;
        final local = target[id];
        final localAt = local?.updatedAt;
        // A deletion of a record this device never had changes nothing.
        if (localAt == null) {
          result.skipped++;
          continue;
        }
        final key = '$entity:$id';
        if (!at.isAfter(localAt) || (only != null && !only.contains(key))) {
          result.skipped++;
          if (!at.isAfter(localAt)) {
            plan?.add(
              BackupPlanItem(
                entity: entity,
                id: id,
                action: BackupAction.skip,
                record: local,
                reason: 'Изменено на устройстве после удаления',
              ),
            );
          }
          continue;
        }
        target.remove(id);
        _queueChange(_change(entity, id, at, null));
        result.deleted++;
        plan?.add(
          BackupPlanItem(
            entity: entity,
            id: id,
            action: BackupAction.delete,
            record: local,
          ),
        );
      } catch (_) {
        result.invalid++;
      }
    }
    return result;
  }

  /// Adds new transactions in one snapshot write. Already known ids, including
  /// deleted ones, are skipped so a re-imported statement adds nothing twice.
  Future<int> importTransactions(Iterable<TransactionRecord> records) =>
      _exclusive(() async {
        var added = 0;
        for (final record in records) {
          if (record.amountMinor <= 0 || knowsTransaction(record.id)) continue;
          final saved = record.copyWith(updatedAt: _now());
          _transactions[saved.id] = saved;
          _queueChange(
            _change('transaction', saved.id, saved.updatedAt, saved.payload()),
          );
          added++;
        }
        if (added > 0) await _edited();
        return added;
      });

  void _loadTemplates() {
    _templates.clear();
    try {
      final raw = _preferences!.getString('quickTemplates');
      for (final item in raw == null ? const [] : jsonDecode(raw) as List) {
        try {
          _templates.add(
            TransactionTemplate.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _saveTemplates() => _preferences!.setString(
    'quickTemplates',
    jsonEncode(_templates.map((t) => t.toJson()).toList()),
  );

  /// Adds or moves a template to the front; an identical preset is replaced.
  Future<void> saveTemplate(TransactionTemplate template) => _exclusive(
    () async {
      if (template.categoryName.trim().isEmpty) {
        throw ArgumentError('Выберите категорию');
      }
      _templates.removeWhere(
        (t) => t.id == template.id || t.signature == template.signature,
      );
      _templates.insert(0, template);
      if (_templates.length > 12) _templates.removeRange(12, _templates.length);
      await _saveTemplates();
      _notify();
    },
  );

  Future<void> deleteTemplate(String id) => _exclusive(() async {
    _templates.removeWhere((t) => t.id == id);
    await _saveTemplates();
    _notify();
  });

  /// Never fails the operation it follows: the widget is a convenience.
  Future<void> _publishWidgetSummary() async {
    if (_preferences == null) return;
    try {
      final next = widgetSummary(
        transactions: baseTransactions.items,
        budgets: _budgets.values,
        currency: baseCurrency,
        now: DateTime.now(),
        balanceMinor: balanceMinor,
      );
      if (mapEquals(next, _widgetSummary)) return;
      for (final entry in next.entries) {
        await _preferences!.setString(entry.key, entry.value);
      }
      _widgetSummary = next;
      // Not awaited: the reply may never come (background engine, tests), and
      // the serialized store queue must not wait on a widget refresh.
      unawaited(LaunchActions.updateWidgets());
    } catch (_) {}
  }

  Future<void> setCurrency(String value) => _exclusive(() async {
    currency = value;
    await _preferences!.setString('currency', value);
    _notify();
  });
  Future<void> setTheme(String value) => _exclusive(() async {
    if (!const ['system', 'light', 'dark'].contains(value)) {
      throw ArgumentError('Неизвестный режим темы');
    }
    theme = value;
    await _preferences!.setString('theme', value);
    _notify();
  });
  Future<void> setThemePreset(String value) => _exclusive(() async {
    if (!ColorPreset.values.any((preset) => preset.id == value)) {
      throw ArgumentError('Неизвестный пресет');
    }
    await _preferences!.setString('themePreset', value);
    themePreset = value;
    if (value == ColorPreset.oled.id) {
      await _preferences!.setString('theme', 'dark');
      theme = 'dark';
    }
    _notify();
  });

  Future<void> setServerUrl(String value) => _exclusive(() async {
    final normalized = value.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme)) {
      throw ArgumentError('Укажите полный адрес сервера');
    }
    // Validate the transport before clearing an existing account or changing its scope.
    final validation = SyncApi(
      serverUrl: normalized,
      allowInsecureHttp: const [
        'localhost',
        '127.0.0.1',
        '::1',
        '10.0.2.2',
      ].contains(uri.host),
    );
    validation.close();
    if (normalized == serverUrl) return;
    final unconfiguredGuest = serverUrl.isEmpty && session == null
        ? _snapshot()
        : null;
    await _deleteCredentials();
    session = null;
    _apiInstance?.close();
    _apiInstance = null;
    serverUrl = normalized;
    await _preferences!.setString('serverUrl', normalized);
    // Credentials are deliberately not restored when switching servers.
    await _deleteCredentials();
    _capabilitiesCheckedAt = null;
    _loadServerState();
    if (unconfiguredGuest != null &&
        await _storage!.read(_scopeFor(null)) == null) {
      await _writeSnapshot(_scopeFor(null), unconfiguredGuest);
    }
    await _loadScope();
    error = null;
    syncMessage = null;
    _notify();
  });

  Future<void> signIn(String email, String password) =>
      _authenticate(email, password, false);
  Future<void> register(String email, String password) =>
      _authenticate(email, password, true);
  Future<void> _authenticate(
    String email,
    String password,
    bool register,
  ) => _exclusive(() async {
    final response = register
        ? await _api.register(email, password)
        : await _api.login(email, password);
    final nextSession = AuthSession(response);
    // A sign-in starts in the personal ledger, where guest records go.
    await _preferences!.remove(_ledgerPreference(nextSession.userId));
    final nextScope = _scopeFor(nextSession.userId);
    final exists = await _storage!.read(nextScope);
    final marker = 'importedGuest.$serverUrl';
    final guest =
        session == null &&
            exists == null &&
            !(_preferences!.getBool(marker) ?? false)
        ? _snapshot()
        : null;
    session = nextSession;
    await _saveCredentials(response);
    _loadServerState();
    _capabilitiesCheckedAt = null;
    await _loadScope();
    if (guest != null) {
      await _writeSnapshot(_scope, guest);
      await _loadScope();
      _cursor = 0;
      // Imported rows may have been synced under another prior guest snapshot.
      _queueAllRecords();
      await _persist();
      await _preferences!.setBool(marker, true);
    }
    error = null;
    _notify();
    await _syncLocked();
  });
  Future<void> signOut() => _exclusive(() async {
    final old = session;
    // Local logout succeeds even if the network is unavailable.
    session = null;
    await _deleteCredentials();
    _loadServerState();
    await _loadScope();
    error = null;
    syncMessage = null;
    _notify();
    if (old != null) {
      try {
        await _api.logout(old.refreshToken);
      } catch (_) {}
    }
  });

  Future<String> _accessToken({bool force = false}) async {
    final current = session;
    if (current == null) throw StateError('Войдите в аккаунт');
    if (!force &&
        current.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 1)),
        )) {
      return current.accessToken;
    }
    final refreshed = await _api.refresh(current.refreshToken);
    session = AuthSession(refreshed);
    await _saveCredentials(refreshed);
    return session!.accessToken;
  }

  Future<void> sync() => _exclusive(_syncLocked);
  void _queueAllRecords() {
    for (final entry in _collections.entries) {
      for (final r in entry.value.values) {
        _queueChange(_change(entry.key, r.id, r.updatedAt, r.payload()));
      }
    }
  }

  Future<void> resetAndSync() => _exclusive(() async {
    _cursor = 0;
    _queueAllRecords();
    for (final tombstone in _tombstones.values.toList()) {
      _queueChange(tombstone);
    }
    await _persist();
    await _syncLocked();
  });

  /// Runs [call] with a valid access token, refreshing once after a 401.
  Future<T> _authorized<T>(Future<T> Function(String token) call) async {
    try {
      return await call(await _accessToken());
    } on SyncApiException catch (e) {
      if (e.statusCode != 401) rethrow;
      return call(await _accessToken(force: true));
    }
  }

  /// Asks the server what it supports (§0). A server without the route is
  /// v1. A failed check keeps the last known answer (v1 if none): records the
  /// server may not know then simply wait in the queue.
  Future<ServerCapabilities> refreshCapabilities({bool force = false}) =>
      _exclusive(() => _refreshCapabilities(force: force));

  Future<ServerCapabilities> _refreshCapabilities({bool force = false}) async {
    final checked = _capabilitiesCheckedAt;
    if (!force &&
        capabilities != null &&
        checked != null &&
        DateTime.now().difference(checked) < const Duration(minutes: 10)) {
      return capabilities!;
    }
    try {
      final next = await _api.capabilities();
      capabilities = next;
      _capabilitiesCheckedAt = DateTime.now();
      await _preferences!.setString(
        'capabilities.$serverUrl',
        jsonEncode(next.toJson()),
      );
    } catch (_) {
      // Unknown until the next successful check.
    }
    return capabilities ?? ServerCapabilities.v1;
  }

  /// Uploads files of new attachments before their records are pushed. A
  /// file lost from the device cannot be uploaded; its record is removed.
  Future<void> _uploadPending(ServerCapabilities caps) async {
    if (!caps.attachments || _uploads.isEmpty) return;
    for (final upload in _uploads.values.toList()) {
      final sha = upload['sha256'] as String;
      final bytes = await _attachmentCache!.read(sha);
      if (bytes == null) {
        for (final attachment
            in _attachments.values.where((a) => a.sha256 == sha).toList()) {
          _removeAttachment(attachment);
        }
        _uploads.remove(sha);
        continue;
      }
      await _authorized(
        (token) => _api.uploadAttachment(
          accessToken: token,
          sha256: sha,
          bytes: bytes,
          contentType: upload['contentType'] as String,
          ledgerId: activeLedgerId,
        ),
      );
      _uploads.remove(sha);
      await _persist();
    }
  }

  /// A queued change the server can take now: its entity is supported and,
  /// for an attachment, its file is already uploaded.
  bool _sendable(Map<String, dynamic> change, ServerCapabilities caps) {
    final entity = change['entity'] as String;
    if (!caps.entities.contains(entity)) return false;
    if (entity == 'attachment' && change['deleted'] != true) {
      final sha = (change['payload'] as Map)['sha256'];
      return !_uploads.containsKey(sha);
    }
    return true;
  }

  Future<void> _syncLocked() async {
    if (session == null || syncing) return;
    syncing = true;
    error = null;
    syncMessage = 'Синхронизация…';
    _skippedFromServer = 0;
    _notify();
    try {
      final caps = await _refreshCapabilities();
      await _uploadPending(caps);
      final sent = {
        for (final entry in _dirty.entries)
          if (_sendable(entry.value, caps)) entry.key: entry.value,
      };
      Future<int> run() => _api.synchronize(
        accessToken: _accessToken,
        cursor: _cursor,
        deviceId: _deviceId,
        changes: sent.values.toList(),
        applyPage: _applyPage,
        ledgerId: activeLedgerId,
      );
      try {
        await run();
      } on SyncApiException catch (e) {
        if (e.statusCode != 401) rethrow;
        await _accessToken(force: true);
        await run();
      }
      // Only acknowledge precisely the pushed revision, never a newer local edit.
      for (final entry in sent.entries) {
        if (_dirty[entry.key]?['updatedAt'] == entry.value['updatedAt']) {
          _dirty.remove(entry.key);
        }
      }
      // After the pull: other devices' progress is known, so a rule does
      // not create what they already created or the user deleted.
      _generateRecurring(_clock());
      lastSyncAt = DateTime.now();
      await _persist();
      final waiting = _dirty.values.any((c) => _sendable(c, caps));
      syncMessage =
          sessionPersistenceWarning ??
          (_skippedFromServer > 0
              ? 'Синхронизировано. Пропущено записей с ошибками: $_skippedFromServer — см. Настройки → Данные'
              : !waiting
              ? 'Синхронизировано'
              : 'Есть изменения для следующей синхронизации');
    } catch (e) {
      if (e is SyncApiException &&
          activeLedgerId != null &&
          (e.statusCode == 403 || e.statusCode == 404)) {
        // Removed from the shared ledger or it was deleted: back to personal.
        await _switchLedger(null);
        error = 'Нет доступа к общему пространству. Открыто личное.';
      } else {
        error = e is SyncApiException
            ? e.message
            : 'Не удалось синхронизировать: $e';
      }
      syncMessage = 'Изменения сохранены на устройстве';
      rethrow;
    } finally {
      syncing = false;
      _notify();
    }
  }

  Future<void> _applyPage(
    List<Map<String, dynamic>> changes,
    int cursor,
  ) async {
    try {
      // A change the client cannot read is set aside so it does not block
      // every later page. A full sync pulls it again after an app update.
      final damaged = <QuarantineEntry>[];
      for (final change in changes) {
        try {
          _merge(change);
        } catch (e) {
          damaged.add(
            _damaged('server', change['entity'] as String, e, change),
          );
        }
      }
      if (damaged.isNotEmpty) {
        await _addQuarantine(damaged);
        _skippedFromServer += damaged.length;
      }
      _cursor = cursor;
      await _persist();
    } catch (_) {
      // Disk failure must not advance the in-memory cursor past an uncommitted page.
      await _loadScope();
      rethrow;
    }
  }

  void _merge(Map<String, dynamic> change) {
    final entity = change['entity'] as String;
    final codec = entityCodecs[entity];
    // An entity of a newer contract is skipped silently (§0.1).
    if (codec == null) return;
    final target = _collections[entity]!;
    final key = _key(change);
    final id = change['id'] as String;
    final incoming = DateTime.parse(change['updatedAt'] as String);
    final pending = _dirty[key];
    // Preserve the user's pending deletion. A newer server edit means its LWW
    // delete needs a newer revision, which remains dirty for the next push.
    if (pending?['deleted'] == true && change['deleted'] != true) {
      if (!DateTime.parse(pending!['updatedAt'] as String).isAfter(incoming)) {
        _queueChange(
          _change(
            entity,
            id,
            incoming.add(const Duration(microseconds: 1)),
            null,
          ),
        );
      }
      return;
    }
    if (pending != null &&
        !incoming.isAfter(DateTime.parse(pending['updatedAt'] as String))) {
      return;
    }
    final tombstone = _tombstones[key];
    if (tombstone != null &&
        !incoming.isAfter(DateTime.parse(tombstone['updatedAt'] as String))) {
      return;
    }
    final local = target[id]?.updatedAt;
    if (local != null && incoming.isBefore(local)) return;
    if (change['deleted'] == true) {
      target.remove(id);
      _tombstones[key] = Map<String, dynamic>.from(change);
    } else {
      target[id] = codec.fromPayload(
        id: id,
        updatedAt: incoming,
        payload: Map<String, dynamic>.from(change['payload'] as Map),
      );
      _tombstones.remove(key);
    }
    if (pending != null &&
        incoming.isAfter(DateTime.parse(pending['updatedAt'] as String))) {
      _dirty.remove(key);
    }
  }

  // Shared ledgers (§7). Each has its own records, cursor and queue on the
  // device; switching never moves records between ledgers.

  void _requireLedgers() {
    if (session == null) throw StateError('Войдите в аккаунт');
    if (!supportsLedgers) {
      throw StateError('Сервер не поддерживает общие пространства');
    }
  }

  Future<void> _saveLedgers(List<Ledger> next) async {
    ledgers = List.unmodifiable(next);
    // Names and roles only: member e-mails are not kept on the device.
    final key = 'ledgers.$serverUrl|${session!.userId}';
    final raw = jsonEncode([
      for (final l in next) {'id': l.id, 'name': l.name, 'role': l.role},
    ]);
    await _preferences!.setString(key, raw);
    _ledgersSource = '$key=$raw';
  }

  /// Lists the shared ledgers; falls back to the personal ledger when the
  /// active one is no longer listed.
  Future<List<Ledger>> refreshLedgers() => _exclusive(() async {
    await _refreshCapabilities();
    _requireLedgers();
    final next = await _authorized(_api.ledgers);
    await _saveLedgers(next);
    if (activeLedgerId != null && !next.any((l) => l.id == activeLedgerId)) {
      await _switchLedger(null);
    }
    _notify();
    return ledgers;
  });

  Future<Ledger> createLedger(String name) => _exclusive(() async {
    _requireLedgers();
    _check(name.trim().isNotEmpty, 'Введите название пространства');
    final ledger = await _authorized(
      (token) => _api.createLedger(token, name.trim()),
    );
    await _saveLedgers([...ledgers, ledger]);
    _notify();
    return ledger;
  });

  Future<void> renameLedger(String id, String name) => _exclusive(() async {
    _requireLedgers();
    _check(name.trim().isNotEmpty, 'Введите название пространства');
    final renamed = await _authorized(
      (token) => _api.renameLedger(token, id, name.trim()),
    );
    await _saveLedgers([
      for (final l in ledgers)
        if (l.id != id)
          l
        else
          renamed ??
              Ledger(
                id: l.id,
                name: name.trim(),
                role: l.role,
                members: l.members,
              ),
    ]);
    _notify();
  });

  /// Owner: deletes the ledger on the server with all its records. The copy
  /// on this device stays but is no longer shown.
  Future<void> deleteLedger(String id) => _exclusive(() async {
    _requireLedgers();
    await _authorized((token) => _api.deleteLedger(token, id));
    await _forgetLedger(id);
  });

  /// Owner: a one-time invitation code.
  Future<LedgerInvite> createLedgerInvite(String id) => _exclusive(() async {
    _requireLedgers();
    return _authorized((token) => _api.createInvite(token, id));
  });

  /// Joins by code and opens the ledger.
  Future<Ledger> joinLedger(String code) => _exclusive(() async {
    _requireLedgers();
    final ledger = await _authorized((token) => _api.joinLedger(token, code));
    await _saveLedgers([
      for (final l in ledgers)
        if (l.id != ledger.id) l,
      ledger,
    ]);
    await _switchLedger(ledger.id);
    _notify();
    unawaited(Future(_backgroundSync));
    return ledger;
  });

  /// A member leaves; the owner of a ledger with members cannot
  /// (`owner_cannot_leave`) and deletes it instead.
  Future<void> leaveLedger(String id) => _exclusive(() async {
    _requireLedgers();
    final user = session!.userId;
    await _authorized((token) => _api.removeLedgerMember(token, id, user));
    await _forgetLedger(id);
  });

  /// Owner: removes another member.
  Future<void> removeLedgerMember(String id, String userId) => _exclusive(
    () async {
      _requireLedgers();
      await _authorized((token) => _api.removeLedgerMember(token, id, userId));
      await _saveLedgers([
        for (final l in ledgers)
          if (l.id != id)
            l
          else
            Ledger(
              id: l.id,
              name: l.name,
              role: l.role,
              members: [
                for (final m in l.members)
                  if (m.userId != userId) m,
              ],
            ),
      ]);
      _notify();
    },
  );

  Future<void> _forgetLedger(String id) async {
    await _saveLedgers([
      for (final l in ledgers)
        if (l.id != id) l,
    ]);
    if (activeLedgerId == id) await _switchLedger(null);
    _notify();
  }

  /// Opens a shared ledger, or the personal one with null, and syncs it.
  Future<void> selectLedger(String? id) => _exclusive(() async {
    if (id != null) {
      if (session == null) throw StateError('Войдите в аккаунт');
      if (!ledgers.any((l) => l.id == id)) {
        throw ArgumentError('Пространство не найдено');
      }
    }
    if (id == activeLedgerId) return;
    await _switchLedger(id);
    _notify();
    unawaited(Future(_backgroundSync));
  });

  Future<void> _switchLedger(String? id) async {
    final user = session?.userId;
    if (user == null) return;
    if (id == null) {
      await _preferences!.remove(_ledgerPreference(user));
    } else {
      await _preferences!.setString(_ledgerPreference(user), id);
    }
    activeLedgerId = id;
    await _loadScope();
  }

  void _backgroundSync() {
    if (ready && session != null) unawaited(sync().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgroundSync();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _timer?.cancel();
      _timer = null;
    } else if (state == AppLifecycleState.resumed) {
      _timer ??= Timer.periodic(const Duration(minutes: 2), (_) {
        _backgroundSync();
      });
    }
  }

  /// Wait for all serialized work before a headless engine exits.
  Future<void> close() async {
    await _tail;
    _apiInstance?.close();
    _apiInstance = null;
    await _storage?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (!background) WidgetsBinding.instance.removeObserver(this);
    unawaited(close());
    super.dispose();
  }
}
