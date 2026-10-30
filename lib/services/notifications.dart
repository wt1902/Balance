import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/finance.dart';
import '../domain/notifications.dart';

/// Where notifications go; the plugin in the app, a fake in tests.
abstract class NotificationSink {
  Future<void> initialize(void Function(String payload) onTap);

  /// The payload of the notification that launched the app, if any.
  Future<String?> launchPayload();
  Future<bool> requestPermission();
  Future<void> show(int id, String title, String body, String payload);

  /// Shows at [first] and then daily at the same local time.
  Future<void> scheduleDaily(
    int id,
    String title,
    String body,
    DateTime first,
    String payload,
  );
  Future<void> cancel(int id);
}

/// Device-local notification settings and rules. Nothing here is synced; the
/// UI and the background sync engine both run [ledgerChanged].
class Notifications extends ChangeNotifier {
  Notifications({NotificationSink? sink, DateTime Function()? clock})
    : _sink = sink ?? PluginNotificationSink(),
      _clock = clock ?? DateTime.now;

  static const reminderId = 1;
  static const _months = [
    'январь',
    'февраль',
    'март',
    'апрель',
    'май',
    'июнь',
    'июль',
    'август',
    'сентябрь',
    'октябрь',
    'ноябрь',
    'декабрь',
  ];

  final NotificationSink _sink;
  final DateTime Function() _clock;
  SharedPreferences? _prefs;
  bool budgetAlerts = false;
  bool reminder = false;
  int reminderHour = 20, reminderMinute = 0;

  /// Tap on a notification: `budget` or `reminder`.
  void Function(String payload)? onTap;

  /// Linux and Web have no scheduler; Windows has no repeating notifications.
  static bool get canSchedule =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _load();
    try {
      await _sink.initialize((payload) => onTap?.call(payload));
    } catch (_) {
      // Notifications are optional; the app works without them.
    }
  }

  void _load() {
    budgetAlerts = _prefs!.getBool('notify.budget') ?? false;
    reminder = _prefs!.getBool('notify.reminder') ?? false;
    final time = (_prefs!.getString('notify.reminderTime') ?? '20:00').split(
      ':',
    );
    reminderHour = int.tryParse(time.first) ?? 20;
    reminderMinute = int.tryParse(time.last) ?? 0;
  }

  Future<String?> launchPayload() async {
    try {
      return await _sink.launchPayload();
    } catch (_) {
      return null;
    }
  }

  Future<void> _requirePermission() async {
    if (!await _sink.requestPermission()) {
      throw const NotificationException(
        'Уведомления запрещены. Разрешите их в настройках системы.',
      );
    }
  }

  /// Turning alerts on records the current state silently, so only later
  /// crossings notify.
  Future<void> setBudgetAlerts(
    bool on, {
    required Iterable<BudgetRecord> budgets,
    required Iterable<TransactionRecord> transactions,
  }) async {
    if (on) {
      await _requirePermission();
      final levels = _levels();
      for (final alert in NotificationRules.budgetAlerts(
        budgets,
        transactions,
        _clock(),
        levels,
      )) {
        levels[NotificationRules.budgetKey(alert.budget)] = alert.threshold;
      }
      await _saveLevels(levels);
    }
    budgetAlerts = on;
    await _prefs!.setBool('notify.budget', on);
    notifyListeners();
  }

  Future<void> setReminder(
    bool on, {
    required Iterable<TransactionRecord> transactions,
  }) async {
    if (on) await _requirePermission();
    reminder = on;
    await _prefs!.setBool('notify.reminder', on);
    await _schedule(transactions);
    notifyListeners();
  }

  Future<void> setReminderTime(
    int hour,
    int minute, {
    required Iterable<TransactionRecord> transactions,
  }) async {
    reminderHour = hour;
    reminderMinute = minute;
    await _prefs!.setString(
      'notify.reminderTime',
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
    );
    await _schedule(transactions);
    notifyListeners();
  }

  /// After every ledger change (local edit or sync): budget alerts that newly
  /// crossed 80% or 100%, and the reminder moved to tomorrow once something
  /// was entered today. Never throws: notifications must not break editing.
  Future<void> ledgerChanged({
    required Iterable<BudgetRecord> budgets,
    required Iterable<TransactionRecord> transactions,
  }) async {
    if (_prefs == null) return;
    try {
      // Another engine (background sync) may have notified meanwhile.
      await _prefs!.reload();
      _load();
      if (budgetAlerts) {
        final levels = _levels();
        final alerts = NotificationRules.budgetAlerts(
          budgets,
          transactions,
          _clock(),
          levels,
        );
        if (alerts.isNotEmpty) {
          // Record first, so a concurrent engine does not repeat them.
          for (final alert in alerts) {
            levels[NotificationRules.budgetKey(alert.budget)] = alert.threshold;
          }
          await _saveLevels(levels);
          final month = _months[_clock().toLocal().month - 1];
          for (final alert in alerts) {
            await _sink.show(
              _budgetNotificationId(alert.budget),
              alert.title,
              alert.body(month),
              'budget',
            );
          }
        }
      }
      if (reminder) await _schedule(transactions);
    } catch (_) {}
  }

  Future<void> _schedule(Iterable<TransactionRecord> transactions) async {
    if (!canSchedule) return;
    await _sink.cancel(reminderId);
    if (!reminder) return;
    final now = _clock();
    await _sink.scheduleDaily(
      reminderId,
      'Баланс',
      'Не забудьте записать сегодняшние траты',
      NotificationRules.nextReminder(
        now,
        reminderHour,
        reminderMinute,
        enteredToday: NotificationRules.hasEntryToday(transactions, now),
      ),
      'reminder',
    );
  }

  /// Stable per budget and month, away from the reminder id.
  static int _budgetNotificationId(BudgetRecord budget) =>
      1000 + NotificationRules.budgetKey(budget).hashCode.abs() % 1000000;

  Map<String, int> _levels() {
    try {
      final raw = _prefs!.getString('notify.budgetLevels');
      if (raw == null) return {};
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// Keeps only the current month's entries.
  Future<void> _saveLevels(Map<String, int> levels) async {
    final now = _clock().toLocal();
    final suffix = '|${now.year}-${now.month.toString().padLeft(2, '0')}';
    levels.removeWhere((key, _) => !key.endsWith(suffix));
    await _prefs!.setString('notify.budgetLevels', jsonEncode(levels));
  }
}

class NotificationException implements Exception {
  const NotificationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PluginNotificationSink implements NotificationSink {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _timeZoneReady = false;

  static const _budgetDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'budget',
      'Бюджеты',
      channelDescription: 'Предупреждения о 80% и 100% лимита',
      visibility: NotificationVisibility.private,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  static const _reminderDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminder',
      'Напоминания',
      channelDescription: 'Ежедневное напоминание внести траты',
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  @override
  Future<void> initialize(void Function(String payload) onTap) async {
    // Permissions are asked when the user turns a notification on.
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_balance'),
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(defaultActionName: 'Открыть'),
        windows: WindowsInitializationSettings(
          appName: 'Баланс',
          appUserModelId: 'Balance.Balance',
          guid: '5f1f6c3e-7a5b-4c2e-9a41-0d3b8e6f2c17',
        ),
        web: WebInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (response) =>
          onTap(response.payload ?? ''),
    );
  }

  @override
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.didNotificationLaunchApp == true
        ? details!.notificationResponse?.payload
        : null;
  }

  @override
  Future<bool> requestPermission() async {
    if (kIsWeb) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                WebFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android =>
        await _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.requestNotificationsPermission() ??
            false,
      TargetPlatform.iOS =>
        await _plugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, sound: true) ??
            false,
      TargetPlatform.macOS =>
        await _plugin
                .resolvePlatformSpecificImplementation<
                  MacOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, sound: true) ??
            false,
      // Linux and Windows show notifications without a runtime prompt.
      _ => true,
    };
  }

  @override
  Future<void> show(int id, String title, String body, String payload) =>
      _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: _budgetDetails,
        payload: payload,
      );

  @override
  Future<void> scheduleDaily(
    int id,
    String title,
    String body,
    DateTime first,
    String payload,
  ) async {
    if (!_timeZoneReady) {
      tzdata.initializeTimeZones();
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
      _timeZoneReady = true;
    }
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(first, tz.local),
      notificationDetails: _reminderDetails,
      // Inexact: no exact-alarm permission; a few minutes late is fine.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
