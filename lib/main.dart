import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'services/app_lock.dart';
import 'services/app_store.dart';
import 'services/background.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Roboto',
    ], await rootBundle.loadString('assets/fonts/LICENSE.txt'));
  });
  final store = AppStore();
  final lock = AppLock();
  try {
    // The lock is known before the first frame, so nothing shows unlocked.
    await lock.initialize();
    await store.initialize();
    try {
      await configureBackgroundSync();
    } catch (_) {
      store.error =
          'Не удалось включить фоновую синхронизацию. Синхронизация при открытии приложения доступна.';
    }
    runApp(BalanceApp(store: store, lock: lock));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_outlined, size: 48),
                    const SizedBox(height: 16),
                    const Text(
                      'Не удалось открыть хранилище',
                      style: TextStyle(fontSize: 24),
                    ),
                    const SizedBox(height: 12),
                    SelectableText('$error'),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: main,
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
