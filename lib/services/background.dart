import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'app_store.dart';
import 'notifications.dart';

const _periodicSyncName = 'balance-periodic-sync';
const _syncTask = 'balance.finance.sync';

@pragma('vm:entry-point')
void balanceBackgroundDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    if (task != _syncTask) return true;
    final store = AppStore(background: true);
    var success = false;
    try {
      await store.initialize();
      await store.sync();
      success = true;
      // Changes pulled from other devices can cross a budget threshold.
      final notifications = Notifications();
      await notifications.initialize();
      await notifications.ledgerChanged(
        budgets: store.budgets,
        transactions: store.transactions,
      );
    } catch (_) {
      // WorkManager retries with backoff; details/tokens are never logged.
      success = false;
    } finally {
      try {
        await store.close();
      } catch (_) {
        success = false;
      }
      store.dispose();
    }
    return success;
  });
}

/// Android OS scheduling survives UI engine shutdown. Other platforms retain
/// their existing foreground startup/resume/two-minute synchronization.
Future<void> configureBackgroundSync() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  await Workmanager().initialize(balanceBackgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    _periodicSyncName,
    _syncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}
