import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/pin_hash.dart';

/// Device-local app lock and privacy settings. The PIN hash lives only in
/// secure storage; preferences hold the switches. Nothing here is synced.
/// The lock hides the interface; ledger data on disk is not encrypted.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({
    FlutterSecureStorage? secureStorage,
    LocalAuthentication? auth,
    DateTime Function()? clock,
    int? iterations,
  }) : _secure = secureStorage ?? const FlutterSecureStorage(),
       _auth = auth ?? LocalAuthentication(),
       _clock = clock ?? DateTime.now,
       // dart2js is far slower at hashing; the count is stored with the hash.
       _iterations = iterations ?? (kIsWeb ? 20000 : 100000);

  static const _secretKey = 'balance.appLock';
  static const _privacy = MethodChannel('balance/privacy');
  static const lockDelays = [0, 60, 300];

  final FlutterSecureStorage _secure;
  final LocalAuthentication _auth;
  final DateTime Function() _clock;
  final int _iterations;
  SharedPreferences? _prefs;

  bool enabled = false;
  bool locked = false;
  bool biometrics = false;
  bool biometricsAvailable = false;
  bool hideInRecents = false;

  /// Seconds in the background before the app locks again.
  int lockAfter = 0;

  /// Covers the interface while the app is inactive (app switcher snapshot).
  bool obscured = false;
  int failures = 0;
  DateTime? blockedUntil;
  DateTime? _backgroundedAt;

  static AppLock? _current;
  int _external = 0;
  DateTime? _externalEndedAt;

  /// Runs system UI the app opened itself (file picker, share sheet,
  /// permission or biometric prompt). It briefly sends the app to the
  /// background, which must not count as leaving the app and relock it.
  static Future<T> whileExternal<T>(Future<T> Function() body) async {
    final lock = _current;
    if (lock == null) return body();
    lock._external++;
    try {
      return await body();
    } finally {
      lock._external--;
      lock._externalEndedAt = lock._clock();
    }
  }

  /// The resume that follows system UI can arrive just after it returned.
  bool get _inExternalUi {
    final ended = _externalEndedAt;
    return _external > 0 ||
        (ended != null && _clock().difference(ended).inSeconds < 3);
  }

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    enabled = _prefs!.getBool('privacy.appLock') ?? false;
    biometrics = enabled && (_prefs!.getBool('privacy.biometrics') ?? false);
    lockAfter = _prefs!.getInt('privacy.lockAfter') ?? 0;
    hideInRecents = _prefs!.getBool('privacy.hideInRecents') ?? false;
    failures = _prefs!.getInt('privacy.failures') ?? 0;
    final until = _prefs!.getString('privacy.blockedUntil');
    blockedUntil = until == null ? null : DateTime.tryParse(until);
    locked = enabled;
    _current = this;
    biometricsAvailable = await _canUseBiometrics();
    // MainActivity applies the saved value itself on create; this only
    // covers an engine attached to an already running activity.
    if (hideInRecents) await _applyHideInRecents();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<bool> _canUseBiometrics() async {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.fuchsia) {
      return false;
    }
    try {
      return await _auth.isDeviceSupported() &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _readSecret() async {
    String? raw;
    try {
      raw = await _secure.read(key: _secretKey);
    } catch (_) {
      throw const AppLockException(
        'Защищённое хранилище недоступно, PIN-код не проверить.',
      );
    }
    if (raw == null) {
      throw const AppLockException('PIN-код не найден. Задайте его заново.');
    }
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  /// Seconds left before the next PIN attempt is allowed, or 0.
  int get waitSeconds {
    final until = blockedUntil;
    if (until == null) return 0;
    final left = until.difference(_clock()).inSeconds;
    return left > 0 ? left + 1 : 0;
  }

  Future<void> enable(String pin) async {
    if (!PinHash.isValid(pin)) {
      throw const AppLockException('PIN-код — от 4 до 8 цифр');
    }
    final record = PinHash.create(pin, iterations: _iterations);
    try {
      await _secure.write(key: _secretKey, value: jsonEncode(record));
    } catch (_) {
      // Never fall back to plain preferences (AGENTS.md, «Безопасность»).
      throw const AppLockException(
        'Защищённое хранилище недоступно, блокировку включить нельзя.',
      );
    }
    enabled = true;
    locked = false;
    await _resetFailures();
    await _prefs!.setBool('privacy.appLock', true);
    notifyListeners();
  }

  /// Checks the PIN (with the same throttling) without changing anything.
  Future<void> verify(String pin) async {
    if (!await _check(pin)) throw const AppLockException('Неверный PIN-код');
  }

  Future<void> changePin(String current, String next) async {
    if (!await _check(current)) {
      throw const AppLockException('Неверный текущий PIN-код');
    }
    await enable(next);
  }

  Future<void> disable(String pin) async {
    if (!await _check(pin)) throw const AppLockException('Неверный PIN-код');
    try {
      await _secure.delete(key: _secretKey);
    } catch (_) {}
    enabled = false;
    locked = false;
    biometrics = false;
    await _prefs!.setBool('privacy.appLock', false);
    await _prefs!.setBool('privacy.biometrics', false);
    notifyListeners();
  }

  /// Verifies a PIN with attempt throttling: after five wrong PINs each further
  /// one waits 30 s, doubling up to 15 minutes. Survives restarts.
  Future<bool> _check(String pin) async {
    if (waitSeconds > 0) {
      throw AppLockException('Подождите $waitSeconds с');
    }
    final ok = PinHash.verify(pin, await _readSecret());
    if (ok) {
      await _resetFailures();
      return true;
    }
    failures++;
    if (failures >= 5) {
      final seconds = (30 << (failures - 5)).clamp(30, 900);
      blockedUntil = _clock().add(Duration(seconds: seconds));
      await _prefs!.setString(
        'privacy.blockedUntil',
        blockedUntil!.toIso8601String(),
      );
    }
    await _prefs!.setInt('privacy.failures', failures);
    notifyListeners();
    return false;
  }

  Future<void> _resetFailures() async {
    failures = 0;
    blockedUntil = null;
    await _prefs!.remove('privacy.failures');
    await _prefs!.remove('privacy.blockedUntil');
  }

  Future<bool> unlock(String pin) async {
    final ok = await _check(pin);
    if (ok) {
      locked = false;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _authenticate() async {
    try {
      return await whileExternal(
        () => _auth.authenticate(
          localizedReason: 'Разблокируйте «Баланс»',
          // Windows Hello cannot be limited to biometrics.
          biometricOnly: defaultTargetPlatform != TargetPlatform.windows,
          persistAcrossBackgrounding: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> unlockWithBiometrics() async {
    if (!enabled || !biometrics) return false;
    final ok = await _authenticate();
    if (ok) {
      locked = false;
      await _resetFailures();
      notifyListeners();
    }
    return ok;
  }

  /// Turning biometrics on requires one successful scan first.
  Future<void> setBiometrics(bool value) async {
    if (value && !await _authenticate()) {
      throw const AppLockException('Биометрия не подтверждена');
    }
    biometrics = value;
    await _prefs!.setBool('privacy.biometrics', value);
    notifyListeners();
  }

  Future<void> setLockAfter(int seconds) async {
    lockAfter = seconds;
    await _prefs!.setInt('privacy.lockAfter', seconds);
    notifyListeners();
  }

  Future<void> setHideInRecents(bool value) async {
    hideInRecents = value;
    await _prefs!.setBool('privacy.hideInRecents', value);
    await _applyHideInRecents();
    notifyListeners();
  }

  /// Android hides the app-switcher thumbnail natively (also applied at cold
  /// start from the same preference). Other platforms rely on [obscured].
  Future<void> _applyHideInRecents() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _privacy.invokeMethod<void>('setHideInRecents', hideInRecents);
    } catch (_) {}
  }

  void lockNow() {
    if (!enabled) return;
    locked = true;
    notifyListeners();
  }

  /// Phones snapshot the screen for the app switcher when the app becomes
  /// inactive; desktops go inactive on every window switch, so no cover there.
  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        obscured = _mobile && (hideInRecents || enabled);
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        obscured = _mobile && (hideInRecents || enabled);
        _backgroundedAt ??= _clock();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (enabled &&
            !_inExternalUi &&
            since != null &&
            _clock().difference(since).inSeconds >= lockAfter) {
          locked = true;
        }
        obscured = false;
        // A fingerprint or face may have been enrolled in system settings.
        _canUseBiometrics().then((available) {
          if (available != biometricsAvailable) {
            biometricsAvailable = available;
            notifyListeners();
          }
        });
      case AppLifecycleState.detached:
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (identical(_current, this)) _current = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class AppLockException implements Exception {
  const AppLockException(this.message);
  final String message;
  @override
  String toString() => message;
}
