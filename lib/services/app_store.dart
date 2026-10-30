import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/backup.dart';
import '../domain/finance.dart';
import '../domain/appearance.dart';
import 'storage.dart';
import 'runtime_lock.dart';
import 'sync_api.dart';

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
    this.background = false,
  }) : _storage = storage,
       _injectedStorage = storage != null,
       _apiFactory = apiFactory,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();
  SnapshotStorage? _storage;
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
  final Map<String, Map<String, dynamic>> _tombstones = {};
  final Map<String, Map<String, dynamic>> _dirty = {};
  final List<QuarantineEntry> _quarantine = [];
  int _skippedFromServer = 0;

  List<TransactionRecord> get transactions =>
      _transactions.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  List<CategoryRecord> get categories =>
      _categories.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  List<BudgetRecord> get budgets =>
      _budgets.values.toList()
        ..sort((a, b) => b.monthStart.compareTo(a.monthStart));
  int get balanceMinor => _transactions.values.fold(
    0,
    (sum, t) =>
        sum + (t.kindRawValue == 'income' ? t.amountMinor : -t.amountMinor),
  );
  int get pendingChangeCount => _dirty.length;

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
        return await body();
      } finally {
        if (!_injectedStorage) await _runtimeLock.release();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _notify() {
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
    _storage ??= await LedgerStorage.open();
    await _restoreSession();
    await _loadScope();
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
    await _restoreSession();
    await _loadScope();
    _notify();
  }

  Future<void> _restoreSession() async {
    session = null;
    final revision = _preferences!.getString('sessionRevision.$serverUrl');
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
  String _scopeFor(String? userId) => '$serverUrl|${userId ?? 'guest'}';
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
    final raw = await _storage!.read(_scope);
    _transactions.clear();
    _categories.clear();
    _budgets.clear();
    _dirty.clear();
    _tombstones.clear();
    _cursor = 0;
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

    load('transactions', (json) {
      final record = TransactionRecord.fromJson(json);
      _transactions[record.id] = record;
    });
    load('categories', (json) {
      final record = CategoryRecord.fromJson(json);
      _categories[record.id] = record;
    });
    load('budgets', (json) {
      final record = BudgetRecord.fromJson(json);
      _budgets[record.id] = record;
    });
    load('dirty', (json) => _dirty[_key(_validChange(json))] = json);
    load('tombstones', (json) => _tombstones[_key(_validChange(json))] = json);
    final cursor = raw['cursor'];
    // An unreadable cursor only costs a full pull, never local records.
    _cursor = cursor is num && cursor >= 0 ? cursor.toInt() : 0;
    final syncedAt = raw['lastSyncAt'];
    lastSyncAt = syncedAt is String ? DateTime.tryParse(syncedAt) : null;
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
    if (!const {
          'transaction',
          'category',
          'budget',
        }.contains(change['entity']) ||
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
    await _storage!.write(_quarantineKey, {
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
    await _storage!.write(_quarantineKey, {'items': <Object>[]});
    _quarantine.clear();
    _notify();
  });

  Map<String, dynamic> _snapshot() => {
    'transactions': _transactions.values.map((e) => e.toJson()).toList(),
    'categories': _categories.values.map((e) => e.toJson()).toList(),
    'budgets': _budgets.values.map((e) => e.toJson()).toList(),
    'dirty': _dirty.values.toList(),
    'tombstones': _tombstones.values.toList(),
    'cursor': _cursor,
    'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
  };
  Future<void> _persist() => _storage!.write(_scope, _snapshot());
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
    for (final change in _dirty.values) {
      final previous = DateTime.parse(change['updatedAt'] as String);
      if (!now.isAfter(previous)) {
        now = previous.add(const Duration(microseconds: 1));
      }
    }
    return now;
  }

  void _queueChange(Map<String, dynamic> change) {
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

  Future<void> saveTransaction(TransactionRecord record) =>
      _exclusive(() async {
        if (record.amountMinor <= 0) {
          throw ArgumentError('Сумма должна быть больше нуля');
        }
        final saved = record.copyWith(updatedAt: _now());
        _transactions[saved.id] = saved;
        _queueChange(
          _change('transaction', saved.id, saved.updatedAt, saved.payload()),
        );
        await _edited();
      });
  Future<void> deleteTransaction(String id) => _delete('transaction', id);
  Future<void> deleteBudget(String id) => _delete('budget', id);
  Future<void> deleteCategory(String id) => _delete('category', id);
  Future<void> _delete(String entity, String id) => _exclusive(() async {
    if (entity == 'transaction') _transactions.remove(id);
    if (entity == 'category') {
      final category = _categories.remove(id);
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
    if (entity == 'budget') _budgets.remove(id);
    _queueChange(_change(entity, id, _now(), null));
    await _edited();
  });

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
  Future<void> adjustBalance(int targetMinor, {String note = ''}) =>
      _exclusive(() async {
        final delta = targetMinor - balanceMinor;
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
        );
        _transactions[record.id] = record;
        _queueChange(_change('transaction', record.id, now, record.payload()));
        await _edited();
      });

  /// Lossless copy of the current account's records, including deletions.
  /// Sync state (queue, cursor) is per device and deliberately not included.
  Future<Map<String, dynamic>> exportBackup() => _exclusive(
    () async => {
      'format': backupFormat,
      'version': backupVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'data': {
        'transactions': _transactions.values.map((e) => e.toJson()).toList(),
        'categories': _categories.values.map((e) => e.toJson()).toList(),
        'budgets': _budgets.values.map((e) => e.toJson()).toList(),
        'tombstones': _tombstones.values.toList(),
      },
    },
  );

  /// Dry run of [restoreBackup]: what each record would do, without changes.
  Future<BackupPlan> previewBackup(Object? decoded) => _exclusive(() async {
    final data = backupData(decoded);
    final transactions = Map.of(_transactions);
    final categories = Map.of(_categories);
    final budgets = Map.of(_budgets);
    final dirty = Map.of(_dirty);
    final tombstones = Map.of(_tombstones);
    final plan = <BackupPlanItem>[];
    final BackupRestoreResult result;
    try {
      result = _restoreRecords(data, plan: plan);
    } finally {
      _transactions
        ..clear()
        ..addAll(transactions);
      _categories
        ..clear()
        ..addAll(categories);
      _budgets
        ..clear()
        ..addAll(budgets);
      _dirty
        ..clear()
        ..addAll(dirty);
      _tombstones
        ..clear()
        ..addAll(tombstones);
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

    void restore<T extends Object>(
      String section,
      String entity,
      T Function(Map<String, dynamic>) parse,
      String Function(T) id,
      DateTime Function(T) updatedAt,
      String? Function(T) duplicate,
      Map<String, T> target,
      Map<String, dynamic> Function(T) payload,
    ) {
      for (final json in items(section)) {
        final T record;
        try {
          record = parse(json);
        } catch (_) {
          result.invalid++;
          continue;
        }
        final key = '$entity:${id(record)}';
        final local = target[id(record)];
        final reason =
            older(
              key,
              local == null ? null : updatedAt(local),
              updatedAt(record),
            ) ??
            duplicate(record);
        if (reason != null || (only != null && !only.contains(key))) {
          result.skipped++;
          if (reason != null) {
            plan?.add(
              BackupPlanItem(
                entity: entity,
                id: id(record),
                action: BackupAction.skip,
                record: record,
                reason: reason,
              ),
            );
          }
          continue;
        }
        target[id(record)] = record;
        _queueChange(
          _change(entity, id(record), updatedAt(record), payload(record)),
        );
        local == null ? result.added++ : result.updated++;
        plan?.add(
          BackupPlanItem(
            entity: entity,
            id: id(record),
            action: local == null ? BackupAction.add : BackupAction.update,
            record: record,
          ),
        );
      }
    }

    restore<CategoryRecord>(
      'categories',
      'category',
      (json) {
        final record = CategoryRecord.fromJson(json);
        if (record.name.trim().isEmpty) {
          throw const FormatException('Пустое название');
        }
        return record;
      },
      (r) => r.id,
      (r) => r.updatedAt,
      (r) =>
          _categories.values.any(
            (c) =>
                c.id != r.id &&
                c.name == r.name &&
                c.kindRawValue == r.kindRawValue,
          )
          ? 'Категория с таким названием уже есть'
          : null,
      _categories,
      (r) => r.payload(),
    );
    restore<BudgetRecord>(
      'budgets',
      'budget',
      (json) {
        final record = BudgetRecord.fromJson(json);
        if (record.limitMinor <= 0) {
          throw const FormatException('Лимит должен быть больше нуля');
        }
        return record;
      },
      (r) => r.id,
      (r) => r.updatedAt,
      (r) {
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
      },
      _budgets,
      (r) => r.payload(),
    );
    restore<TransactionRecord>(
      'transactions',
      'transaction',
      (json) {
        final record = TransactionRecord.fromJson(json);
        if (record.amountMinor <= 0) {
          throw const FormatException('Сумма должна быть больше нуля');
        }
        return record;
      },
      (r) => r.id,
      (r) => r.updatedAt,
      (_) => null,
      _transactions,
      (r) => r.payload(),
    );
    for (final json in items('tombstones')) {
      try {
        final change = _validChange(json);
        if (change['deleted'] != true) {
          throw const FormatException('Not a deletion');
        }
        final entity = change['entity'] as String;
        final id = change['id'] as String;
        final at = DateTime.parse(change['updatedAt'] as String);
        final target = switch (entity) {
          'transaction' => _transactions,
          'category' => _categories,
          _ => _budgets,
        };
        final local = target[id];
        final localAt = switch (local) {
          TransactionRecord r => r.updatedAt,
          CategoryRecord r => r.updatedAt,
          BudgetRecord r => r.updatedAt,
          _ => null,
        };
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
    if (unconfiguredGuest != null &&
        await _storage!.read(_scopeFor(null)) == null) {
      await _storage!.write(_scopeFor(null), unconfiguredGuest);
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
    await _loadScope();
    if (guest != null) {
      await _storage!.write(_scope, guest);
      await _loadScope();
      _cursor = 0;
      // Imported rows may have been synced under another prior guest snapshot.
      for (final t in _transactions.values) {
        _queueChange(_change('transaction', t.id, t.updatedAt, t.payload()));
      }
      for (final c in _categories.values) {
        _queueChange(_change('category', c.id, c.updatedAt, c.payload()));
      }
      for (final b in _budgets.values) {
        _queueChange(_change('budget', b.id, b.updatedAt, b.payload()));
      }
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
  Future<void> resetAndSync() => _exclusive(() async {
    _cursor = 0;
    for (final t in _transactions.values) {
      _queueChange(_change('transaction', t.id, t.updatedAt, t.payload()));
    }
    for (final c in _categories.values) {
      _queueChange(_change('category', c.id, c.updatedAt, c.payload()));
    }
    for (final b in _budgets.values) {
      _queueChange(_change('budget', b.id, b.updatedAt, b.payload()));
    }
    for (final tombstone in _tombstones.values.toList()) {
      _queueChange(tombstone);
    }
    await _persist();
    await _syncLocked();
  });
  Future<void> _syncLocked() async {
    if (session == null || syncing) return;
    syncing = true;
    error = null;
    syncMessage = 'Синхронизация…';
    _skippedFromServer = 0;
    _notify();
    final sent = Map<String, Map<String, dynamic>>.from(_dirty);
    try {
      Future<int> run() => _api.synchronize(
        accessToken: _accessToken,
        cursor: _cursor,
        deviceId: _deviceId,
        changes: sent.values.toList(),
        applyPage: _applyPage,
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
      lastSyncAt = DateTime.now();
      await _persist();
      syncMessage =
          sessionPersistenceWarning ??
          (_skippedFromServer > 0
              ? 'Синхронизировано. Пропущено записей с ошибками: $_skippedFromServer — см. Настройки → Данные'
              : _dirty.isEmpty
              ? 'Синхронизировано'
              : 'Есть изменения для следующей синхронизации');
    } catch (e) {
      error = e is SyncApiException
          ? e.message
          : 'Не удалось синхронизировать: $e';
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
    final key = _key(change);
    final entity = change['entity'] as String;
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
    DateTime? local;
    if (entity == 'transaction') local = _transactions[id]?.updatedAt;
    if (entity == 'category') local = _categories[id]?.updatedAt;
    if (entity == 'budget') local = _budgets[id]?.updatedAt;
    if (local != null && incoming.isBefore(local)) return;
    if (change['deleted'] == true) {
      if (entity == 'transaction') _transactions.remove(id);
      if (entity == 'category') _categories.remove(id);
      if (entity == 'budget') _budgets.remove(id);
      _tombstones[key] = Map<String, dynamic>.from(change);
    } else {
      final payload = Map<String, dynamic>.from(change['payload'] as Map);
      if (entity == 'transaction') {
        _transactions[id] = TransactionRecord.fromPayload(
          id: id,
          updatedAt: incoming,
          payload: payload,
        );
      }
      if (entity == 'category') {
        _categories[id] = CategoryRecord.fromPayload(
          id: id,
          updatedAt: incoming,
          payload: payload,
        );
      }
      if (entity == 'budget') {
        _budgets[id] = BudgetRecord.fromPayload(
          id: id,
          updatedAt: incoming,
          payload: payload,
        );
      }
      _tombstones.remove(key);
    }
    if (pending != null &&
        incoming.isAfter(DateTime.parse(pending['updatedAt'] as String))) {
      _dirty.remove(key);
    }
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
