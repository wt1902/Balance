/// Lossless local backup file and diagnostics for records that could not be
/// read. Neither is part of the synchronization protocol: a backup is restored
/// through AppStore, which queues the restored records for the next sync.
library;

const backupFormat = 'balance-backup';
const backupVersion = 1;

/// Outcome of restoring a backup. Records are merged by last-write-wins on
/// updatedAt, so nothing newer on the device is overwritten.
class BackupRestoreResult {
  int added = 0, updated = 0, deleted = 0, skipped = 0, invalid = 0;

  int get changed => added + updated + deleted;

  String describe() {
    final parts = [
      'добавлено $added',
      'обновлено $updated',
      if (deleted > 0) 'удалено $deleted',
      if (skipped > 0) 'без изменений $skipped',
      if (invalid > 0) 'с ошибками $invalid',
    ];
    return 'Восстановление: ${parts.join(', ')}';
  }
}

enum BackupAction { add, update, delete, skip }

/// What restoring one backup record would do, for the preview.
class BackupPlanItem {
  const BackupPlanItem({
    required this.entity,
    required this.id,
    required this.action,
    this.record,
    this.reason = '',
  });

  final String entity, id;
  final BackupAction action;

  /// The backup's record, or the device record a deletion would remove.
  final Object? record;

  /// Why a record is skipped.
  final String reason;

  String get key => '$entity:$id';
}

class BackupPlan {
  const BackupPlan(this.items, {this.invalid = 0, this.unchanged = 0});
  final List<BackupPlanItem> items;

  /// [invalid]: unreadable records. [unchanged]: deletions of records this
  /// device never had, which are not listed in [items].
  final int invalid, unchanged;

  Iterable<BackupPlanItem> get actionable =>
      items.where((item) => item.action != BackupAction.skip);
}

/// Validates the envelope and returns its data section. Individual records are
/// validated while merging, so one damaged record does not reject the file.
Map<String, dynamic> backupData(Object? decoded) {
  if (decoded is! Map ||
      decoded['format'] != backupFormat ||
      decoded['data'] is! Map) {
    throw const FormatException('Это не резервная копия «Баланса»');
  }
  final version = decoded['version'];
  if (version is! int || version < 1 || version > backupVersion) {
    throw const FormatException(
      'Копия создана более новой версией приложения. Обновите приложение.',
    );
  }
  return Map<String, dynamic>.from(decoded['data'] as Map);
}

/// A record set aside instead of blocking startup or synchronization. The raw
/// value is kept as found, so it can be saved to a file and repaired by hand.
class QuarantineEntry {
  const QuarantineEntry({
    required this.source,
    required this.section,
    required this.reason,
    required this.detectedAt,
    required this.raw,
  });

  /// `local` for the device snapshot, `server` for a pulled change.
  final String source;

  /// Snapshot list (`transactions`, `dirty`, …) or sync entity name.
  final String section;
  final String reason;
  final DateTime detectedAt;
  final Object? raw;

  String? get recordId => raw is Map ? (raw as Map)['id']?.toString() : null;

  String get sectionTitle => switch (section) {
    'transactions' || 'transaction' => 'Операция',
    'categories' || 'category' => 'Категория',
    'budgets' || 'budget' => 'Бюджет',
    'dirty' => 'Изменение в очереди',
    'tombstones' => 'Отметка удаления',
    _ => section,
  };

  Map<String, dynamic> toJson() => {
    'source': source,
    'section': section,
    'reason': reason,
    'detectedAt': detectedAt.toUtc().toIso8601String(),
    'raw': raw,
  };

  factory QuarantineEntry.fromJson(Map<String, dynamic> json) =>
      QuarantineEntry(
        source: json['source'] as String? ?? 'local',
        section: json['section'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        detectedAt:
            DateTime.tryParse(json['detectedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        raw: json['raw'],
      );
}

/// Short, user-facing reason without stack traces or record contents.
String describeRecordError(Object error) {
  final text = error is FormatException
      ? error.message
      : error.toString().split('\n').first;
  return text.length > 160 ? '${text.substring(0, 160)}…' : text;
}
