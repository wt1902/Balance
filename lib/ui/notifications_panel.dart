import 'package:flutter/material.dart';

import '../services/app_lock.dart';
import '../services/app_store.dart';
import '../services/notifications.dart';

/// Settings → «Уведомления».
class NotificationsPanel extends StatelessWidget {
  const NotificationsPanel({
    super.key,
    required this.notifications,
    required this.store,
    required this.run,
  });
  final Notifications notifications;
  final AppStore store;
  final Future<void> Function(Future<void> Function() action, {String? success})
  run;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: notifications,
    builder: (context, _) {
      final n = notifications;
      final time = TimeOfDay(hour: n.reminderHour, minute: n.reminderMinute);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Предупреждать о бюджете'),
            subtitle: const Text(
              'Когда расходы по бюджету месяца достигают 80% и 100% лимита. '
              'В уведомлении только проценты, без сумм.',
            ),
            value: n.budgetAlerts,
            // The permission prompt is system UI, not leaving the app.
            onChanged: (on) => run(
              () => AppLock.whileExternal(
                () => n.setBudgetAlerts(
                  on,
                  budgets: store.budgets,
                  transactions: store.transactions,
                ),
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Напоминать внести траты'),
            subtitle: Text(
              Notifications.canSchedule
                  ? 'Каждый день в выбранное время. Если сегодня уже есть '
                        'операции, напоминание переносится на завтра.'
                  : 'Недоступно на этой платформе: нет уведомлений по расписанию.',
            ),
            value: n.reminder,
            onChanged: Notifications.canSchedule
                ? (on) => run(
                    () => AppLock.whileExternal(
                      () => n.setReminder(on, transactions: store.transactions),
                    ),
                  )
                : null,
          ),
          if (n.reminder && Notifications.canSchedule)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Время напоминания'),
              trailing: OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(time.format(context)),
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (picked != null) {
                    await run(
                      () => n.setReminderTime(
                        picked.hour,
                        picked.minute,
                        transactions: store.transactions,
                      ),
                    );
                  }
                },
              ),
            ),
        ],
      );
    },
  );
}
