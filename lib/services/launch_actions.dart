import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android entry points outside the app UI: the Quick Settings tile and the
/// home-screen widget open the app with an action (`expense` or `income`),
/// and the widget is refreshed after the ledger changes.
class LaunchActions {
  static const _channel = MethodChannel('balance/launch');

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The action that started the app, returned once.
  static Future<String?> initialAction() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('initialAction');
    } catch (_) {
      return null;
    }
  }

  /// Actions delivered while the app is already running.
  static void listen(void Function(String action) onAction) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      final action = call.arguments;
      if (call.method == 'action' && action is String) onAction(action);
    });
  }

  /// Missing in background engines and tests; the widget then refreshes on
  /// its own schedule from the stored strings.
  static Future<void> updateWidgets() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('updateWidgets');
    } catch (_) {}
  }
}
