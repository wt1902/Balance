import 'dart:async';
import 'dart:ui';

import 'package:balance_flutter/l10n/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // Keep the existing Russian UI assertions independent of the host locale.
  setUp(() {
    appLocale = 'ru';
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
  });
  tearDown(binding.platformDispatcher.clearLocalesTestValue);
  await testMain();
}
