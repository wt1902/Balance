import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/pin_hash.dart';
import '../services/app_lock.dart';
import 'editors.dart';

/// Digit pad for 4–8 digit PINs; also takes digits, Backspace and Enter from
/// a physical keyboard. [onSubmit] returns an error to show, or null.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.title,
    required this.onSubmit,
    this.subtitle,
    this.extra,
  });
  final String title;
  final String? subtitle;
  final Future<String?> Function(String pin) onSubmit;

  /// Shown under the keypad, e.g. biometrics or «Забыли PIN-код?».
  final Widget? extra;
  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  final focus = FocusNode();
  String pin = '';
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    // autofocus yields to a focus the hidden interface still holds; take it,
    // so a physical keyboard types the PIN.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focus.requestFocus();
    });
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  void type(String digit) {
    if (busy || pin.length >= 8) return;
    setState(() {
      pin += digit;
      error = null;
    });
  }

  void erase() {
    if (busy || pin.isEmpty) return;
    setState(() => pin = pin.substring(0, pin.length - 1));
  }

  Future<void> submit() async {
    if (busy) return;
    if (!PinHash.isValid(pin)) {
      setState(() => error = 'PIN-код — от 4 до 8 цифр');
      return;
    }
    setState(() => busy = true);
    String? result;
    try {
      result = await widget.onSubmit(pin);
    } on AppLockException catch (e) {
      result = e.message;
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      error = result;
      if (result != null) pin = '';
    });
  }

  KeyEventResult key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final char = event.character;
    if (char != null && RegExp(r'^\d$').hasMatch(char)) {
      type(char);
    } else if (event.logicalKey == LogicalKeyboardKey.backspace) {
      erase();
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      submit();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget button(Widget child, VoidCallback? onPressed, {String? label}) =>
      Padding(
        padding: const EdgeInsets.all(6),
        child: Semantics(
          button: true,
          label: label,
          child: SizedBox(
            width: 72,
            height: 60,
            child: TextButton(
              onPressed: busy ? null : onPressed,
              style: TextButton.styleFrom(shape: const StadiumBorder()),
              child: child,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final digits = theme.textTheme.headlineSmall;
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: key,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.title,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          if (widget.subtitle != null) ...[
            const SizedBox(height: 6),
            Text(widget.subtitle!, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 20),
          Semantics(
            label: 'Введено цифр: ${pin.length}',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < (pin.length < 4 ? 4 : pin.length); i++)
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < pin.length
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      border: Border.all(color: theme.colorScheme.primary),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 36,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      error ?? '',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
            ),
          ),
          // Narrow dialogs (320px) shrink the keypad instead of overflowing.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final d in row)
                        button(Text(d, style: digits), () => type(d)),
                    ],
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    button(
                      const Icon(Icons.backspace_outlined),
                      erase,
                      label: 'Стереть',
                    ),
                    button(Text('0', style: digits), () => type('0')),
                    button(const Icon(Icons.check), submit, label: 'Готово'),
                  ],
                ),
              ],
            ),
          ),
          if (widget.extra != null) ...[
            const SizedBox(height: 8),
            widget.extra!,
          ],
        ],
      ),
    );
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock});
  final AppLock lock;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  AppLock get lock => widget.lock;

  @override
  void initState() {
    super.initState();
    if (lock.biometrics && lock.biometricsAvailable) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => lock.unlockWithBiometrics(),
      );
    }
  }

  Future<void> forgot() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Забыли PIN-код?'),
      content: const Text(
        'PIN-код нельзя восстановить: он хранится только в виде хеша на этом '
        'устройстве. Чтобы снять блокировку, очистите данные приложения в '
        'настройках системы или переустановите его. Записи, которые уже '
        'синхронизированы с сервером или сохранены в резервной копии, '
        'вернутся после входа или восстановления.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final wait = lock.waitSeconds;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 12),
                PinPad(
                  title: 'Введите PIN-код',
                  subtitle: wait > 0
                      ? 'Слишком много попыток. Подождите $wait с'
                      : null,
                  onSubmit: (pin) async =>
                      await lock.unlock(pin) ? null : 'Неверный PIN-код',
                  extra: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      if (lock.biometrics && lock.biometricsAvailable)
                        TextButton.icon(
                          onPressed: lock.unlockWithBiometrics,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('По биометрии'),
                        ),
                      TextButton(
                        onPressed: forgot,
                        child: const Text('Забыли PIN-код?'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the interface while the app is in the app switcher.
class PrivacyCover extends StatelessWidget {
  const PrivacyCover({super.key});
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: Icon(
        Icons.account_balance_wallet_outlined,
        size: 56,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// Hides the app under the lock screen or cover; while locked the interface
/// is offstage, so it is neither painted nor read by screen readers.
class PrivacyGate extends StatelessWidget {
  const PrivacyGate({super.key, required this.lock, required this.child});
  final AppLock? lock;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final lock = this.lock;
    if (lock == null) return child;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) => Stack(
        children: [
          Offstage(
            offstage: lock.locked,
            child: TickerMode(enabled: !lock.locked, child: child),
          ),
          if (lock.locked)
            LockScreen(lock: lock)
          else if (lock.obscured)
            const PrivacyCover(),
        ],
      ),
    );
  }
}

Future<String?> _pinDialog(
  BuildContext context,
  String title,
  Future<String?> Function(String pin) onSubmit, {
  String? subtitle,
}) => editDialog<String>(
  context,
  Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: Builder(
        builder: (context) => PinPad(
          title: title,
          subtitle: subtitle,
          onSubmit: (pin) async {
            final error = await onSubmit(pin);
            if (error == null && context.mounted) Navigator.pop(context, pin);
            return error;
          },
          extra: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
        ),
      ),
    ),
  ),
);

/// Asks for a new PIN twice; null when cancelled.
Future<String?> askNewPin(BuildContext context) async {
  final first = await _pinDialog(
    context,
    'Новый PIN-код',
    (_) async => null,
    subtitle: 'От 4 до 8 цифр',
  );
  if (first == null || !context.mounted) return null;
  return _pinDialog(
    context,
    'Повторите PIN-код',
    (pin) async => pin == first ? null : 'PIN-коды не совпадают',
  );
}

/// Asks for the current PIN and runs [action] with it.
Future<bool> confirmWithPin(
  BuildContext context,
  String title,
  Future<void> Function(String pin) action,
) async =>
    await _pinDialog(context, title, (pin) async {
      await action(pin);
      return null;
    }) !=
    null;

/// Settings → «Приватность».
class PrivacyPanel extends StatelessWidget {
  const PrivacyPanel({super.key, required this.lock, required this.run});
  final AppLock lock;
  final Future<void> Function(Future<void> Function() action, {String? success})
  run;

  static String delayTitle(int seconds) => switch (seconds) {
    0 => 'Сразу',
    60 => 'Через 1 минуту',
    _ => 'Через ${seconds ~/ 60} минут',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: lock,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Блокировка PIN-кодом'),
          subtitle: const Text(
            'Скрывает приложение при запуске и после возврата. Данные на '
            'устройстве не шифруются.',
          ),
          value: lock.enabled,
          onChanged: (on) async {
            if (on) {
              final pin = await askNewPin(context);
              if (pin != null) {
                await run(
                  () => lock.enable(pin),
                  success: 'Блокировка включена',
                );
              }
            } else {
              await confirmWithPin(context, 'Введите PIN-код', lock.disable);
            }
          },
        ),
        if (lock.enabled) ...[
          if (lock.biometricsAvailable)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Вход по биометрии'),
              subtitle: const Text('Отпечаток пальца или лицо вместо PIN-кода'),
              value: lock.biometrics,
              onChanged: (on) => run(() => lock.setBiometrics(on)),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Блокировать после ухода из приложения'),
            trailing: DropdownButton<int>(
              value: AppLock.lockDelays.contains(lock.lockAfter)
                  ? lock.lockAfter
                  : 0,
              items: [
                for (final seconds in AppLock.lockDelays)
                  DropdownMenuItem(
                    value: seconds,
                    child: Text(delayTitle(seconds)),
                  ),
              ],
              onChanged: (v) => run(() => lock.setLockAfter(v ?? 0)),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  String? current;
                  if (!await confirmWithPin(context, 'Текущий PIN-код', (
                        pin,
                      ) async {
                        await lock.verify(pin);
                        current = pin;
                      }) ||
                      !context.mounted) {
                    return;
                  }
                  final next = await askNewPin(context);
                  if (next != null) {
                    await run(
                      () => lock.changePin(current!, next),
                      success: 'PIN-код изменён',
                    );
                  }
                },
                child: const Text('Сменить PIN-код'),
              ),
              TextButton(
                onPressed: lock.lockNow,
                child: const Text('Заблокировать сейчас'),
              ),
            ],
          ),
        ],
        if (Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Скрывать в недавних приложениях'),
            subtitle: const Text(
              'В переключателе приложений вместо сумм — заставка. На Android '
              'ниже 13 это также запрещает снимки экрана.',
            ),
            value: lock.hideInRecents,
            onChanged: (on) => run(() => lock.setHideInRecents(on)),
          ),
      ],
    ),
  );
}
