# AGENTS.md — BalanceFlutter

Этот файл — точка входа для AI-агентов и разработчиков. Прочитай его
целиком перед любым изменением в репозитории.

## Что это за проект

**BalanceFlutter** («Баланс») — local-first приложение для учёта личных
финансов на Flutter с Material 3. Один код для Android, iPhone/iPad,
macOS, Windows, Linux и Web. Данные хранятся локально и по желанию
синхронизируются с self-hosted сервером **BalanceServer**.

Проект выделен из монорепозитория Balance. Остальные части экосистемы
живут в своих репозиториях и используют **тот же протокол синхронизации и
те же финансовые правила**:

- BalanceServer — сервер авторизации и синхронизации (`/v1` API);
- BalanceWatch — нативный SwiftUI-клиент для Apple Watch (у Flutter нет
  watchOS runner'а, не добавляй фиктивную сборку под часы);
- нативные Apple/Android-клиенты — исходники, с которыми сверялся перенос
  (см. `FEATURE_PARITY.md`).

Стек: Flutter 3.47.8 / Dart 3.13.7 (закреплены в CI и `pubspec.lock`),
`http`, `sembast` / `sembast_web` (IndexedDB), `flutter_secure_storage`,
`shared_preferences`, `workmanager`, локальный плагин
`packages/balance_runtime`.

## Структура

```text
BalanceFlutter/
├── AGENTS.md, README.md
├── SYNC_PROTOCOL.md       # как Flutter-клиент реализует wire-протокол
├── FEATURE_PARITY.md      # аудит переноса функций из нативных клиентов
├── VALIDATION.md          # что и как проверено, известные ограничения
├── ROADMAP.md             # идеи новых функций и приоритеты
├── docs/                  # скриншоты для README
│   └── ecosystem/         # общий контракт экосистемы (sync, модель данных, безопасность)
├── branding/              # иконка приложения, аватар и баннер README: SVG, PNG, render.sh
├── .github/workflows/flutter.yml
├── lib/
│   ├── main.dart
│   ├── domain/
│   │   ├── finance.dart     # модели, FinanceMath, категории, CSV
│   │   ├── backup.dart      # формат JSON-копии, план восстановления, карантин
│   │   ├── statement_import.dart # разбор выписок CSV/OFX и своего CSV
│   │   ├── templates.dart   # шаблоны быстрого ввода и частые траты
│   │   ├── money_format.dart # money(): формат сумм для UI и виджета
│   │   └── appearance.dart  # пресеты оформления (ColorPreset)
│   ├── services/
│   │   ├── app_store.dart   # AppStore: состояние, CRUD, очередь изменений, сессии, sync
│   │   ├── sync_api.dart    # SyncApi: HTTP-клиент /v1 API
│   │   ├── storage*.dart    # Sembast (native) / IndexedDB (web) снапшоты
│   │   ├── runtime_lock*.dart # межпроцессная/межвкладочная блокировка
│   │   ├── background.dart  # фоновая синхронизация (WorkManager, Android)
│   │   ├── launch_actions.dart # канал balance/launch: плитка, виджет Android
│   │   └── widget_summary.dart # строки для виджета главного экрана
│   └── ui/
│       ├── app.dart         # BalanceApp, BalanceShell, экраны
│       ├── editors.dart     # формы операции, категории, бюджета
│       ├── design.dart      # переиспользуемые виджеты
│       ├── data_tools.dart  # копия, импорт выписок, предпросмотры, карантин
│       └── app_theme.dart   # темы и пресеты Material 3
├── packages/balance_runtime/ # плагин: file lock на Android (Java + JVM-тесты)
├── test/                     # unit, store, HTTP, widget и screenshot-тесты
├── tool/                     # интеграционный прогон с настоящим сервером, иконки
├── scripts/build.sh          # единая точка сборки под все платформы
└── android/ ios/ macos/ windows/ linux/ web/  # платформенные runner'ы
```

## Правила разработки

### 1. Где что менять

| Что | Где |
| --- | --- |
| Модель данных, расчёты, категории, CSV | `lib/domain/finance.dart` |
| Состояние, хранение, очередь, синхронизация | `lib/services/app_store.dart` |
| HTTP и формат запросов к серверу | `lib/services/sync_api.dart` |
| Экраны и формы | `lib/ui/` |
| Оформление и пресеты | `lib/domain/appearance.dart`, `lib/ui/app_theme.dart` |
| Сборка | `scripts/build.sh` + `.github/workflows/flutter.yml` |

- UI не считает деньги сам: расчёты — в `FinanceMath`, изменения
  данных — только через методы `AppStore`.
- Платформенный код (`android/`, `ios/`, …) трогай только когда это
  действительно нужно; analyzer его не проверяет.
  Нативные точки входа Android: `QuickAddTileService` (плитка Quick
  Settings) и `BalanceWidgetProvider` (виджет) в
  `android/app/src/main/kotlin/com/balance/balance/`; связь с Dart — канал
  `balance/launch` в `MainActivity`. Виджет читает строки `flutter.widget.*`,
  которые пишет `AppStore`; расчёты для них — в `FinanceMath`.

### 2. Деньги и даты

- Суммы внутри хранятся **целыми сотыми** валюты. Серверный формат
  `amount`/`limit` остаётся числом; старые значения с более чем двумя
  знаками округляются до сотых. Не переходи на `double` в расчётах.
- Все интервалы полуоткрытые: `[начало, конец)`.
- Валюта (RUB, EUR, USD, SEK) влияет только на формат вывода, конвертации
  нет.

### 3. Финансовые правила (общие для всей экосистемы)

- общий баланс = все доходы − все расходы, включая корректировки и
  будущие даты;
- операции с флагом корректировки входят в общий баланс, но **не**
  входят в периодическую аналитику и в траты по бюджетам;
- расходы группируются по имени категории;
- периоды аналитики: текущий календарный месяц, 3 и 12 месяцев (начало
  на 2 и 11 месяцев раньше текущего).

Эти правила совпадают с нативными клиентами и BalanceWatch. Не меняй их
только здесь; любое изменение покрывай тестами в `test/finance_test.dart`.

### 4. Данные и синхронизация

- Любое изменение записи проходит через `AppStore` (`save*`/`delete*`):
  он обновляет `updatedAt`, ставит изменение в очередь (`_dirty`) и пишет
  tombstone при удалении. Не изменяй коллекции в обход этих методов.
- Сохранение данных и курсора — транзакционное: страница pull'а
  применяется целиком или откатывается. Не разделяй эту запись.
- Журнал scope хранится в Sembast по записям (`ledger|<scope>`: `t:`, `c:`,
  `b:`, `d:`, `x:` и `meta`). `AppStore._persist` пишет только изменённые
  записи: записи неизменяемы, изменения определяются по ссылке. Поэтому меняй
  записи только заменой (`copyWith`, новый Map), не изменяй их на месте.
- Любая запись в хранилище идёт через `AppStore` и сначала ставит новую
  `ledgerRevision` в настройках. По ней другие движки (фоновая синхронизация,
  вкладки Web) понимают, что нужно перечитать данные. `LedgerStorage` держит
  базу открытой и после каждой записи ждёт `flush`. Не обходи эти пути.
- Производительность на большом журнале: `flutter test
  tool/benchmark/ledger_benchmark_test.dart` (размеры —
  `BALANCE_BENCH_SIZES`). При изменениях хранения сравни цифры с
  `VALIDATION.md`.
- Данные разделены по scope «сервер + пользователь». Первый вход
  переносит гостевые записи в аккаунт; logout и смена сервера локальные
  данные не удаляют.
- Формат JSON, семантика cursor/sequence, эндпоинты `/v1/...` и
  заголовки — **общий контракт** с BalanceServer и другими клиентами
  (`SYNC_PROTOCOL.md`, `docs/ecosystem/SYNC_PROTOCOL.md`). Не меняй его
  без согласованного изменения сервера и всех клиентов.
- Синхронизация: при входе/открытии, при возврате в приложение, раз в 2
  минуты в активном режиме; на Android ещё WorkManager раз в 15 минут.
  Фоновый engine и UI защищены общей блокировкой (`RuntimeLock`,
  `balance_runtime`, Web Locks API) — не обходи её.

### 5. Безопасность

- Токены — только в `flutter_secure_storage` (Keychain / Keystore /
  libsecret / DPAPI). Если защищённое хранилище недоступно, сессия живёт
  только в памяти и показывается предупреждение — сохраняй это поведение,
  не добавляй fallback в `shared_preferences` или файлы.
- Пароли нигде не сохраняются.
- PIN-код блокировки приложения хранится только как солёный хеш
  PBKDF2-HMAC-SHA256 в `flutter_secure_storage` (`lib/domain/pin_hash.dart`,
  `lib/services/app_lock.dart`). Если защищённое хранилище недоступно,
  блокировку включить нельзя: не добавляй запасной вариант. Блокировка
  скрывает интерфейс (`PrivacyGate`), а не шифрует журнал.
- Удалённый сервер — только HTTPS. HTTP разрешён только для `localhost`,
  `127.0.0.1`, `::1` и `10.0.2.2` (Android-эмулятор). URL с
  credentials, query или fragment отклоняется.
- Не логируй пароли, токены, заголовок `Authorization`.
- Не коммить ключи подписи, `key.properties`, `*.jks`, production-URL.
  Пример — `android/key.properties.example`.

Подробности — `docs/ecosystem/SECURITY.md`.

### 6. UI

- Material 3, адаптивная навигация: нижняя панель на телефоне, боковая на
  широком экране. Проверяй 320×568, 390×844 и 1280×900.
- Строки интерфейса — на русском.
- Пресеты оформления: Лес (по умолчанию), Индиго, Океан, Роза, OLED.
  OLED в тёмном режиме — чистый `#000000` везде (карточки, навигация,
  диалоги).
- Шрифт — встроенный Roboto (`BalanceRoboto`); Web-сборка не тянет
  ресурсы с CDN (`--no-web-resources-cdn`).

### 7. Стиль кода

- `flutter analyze` должен давать «No issues found»
  (`flutter_lints` + `prefer_single_quotes`).
- Форматирование — `dart format`.
- Новые зависимости добавляй только при реальной необходимости и
  обновляй `pubspec.lock`.

## Сборка и проверка

```bash
flutter pub get
flutter analyze
flutter test
bash scripts/build.sh web        # android | ios | macos | windows | linux
```

- Тесты не должны зависеть от текущей даты, локали и часового пояса
  машины; часовой пояс проверялся и с `TZ=Europe/Moscow`.
- `test/screenshots_test.dart` пишет PNG в `/tmp/balance-ui` — это
  нормально, в репозиторий их не клади. Обновлённые скриншоты для README
  кладутся в `docs/` вручную.
- Интеграция с настоящим сервером: `bash tool/run_integration.sh`. Нужны
  Go 1.25+, Dart и исходники BalanceServer (по умолчанию
  `../BalanceServer`, иначе `BALANCE_SERVER_DIR=/путь`).
- CI (`.github/workflows/flutter.yml`): job `checks` (analyze + test) и
  шесть сборок через `scripts/build.sh` с артефактами `balance-<platform>`.
  Новая платформа или флаг сборки → правь `scripts/build.sh`, а не
  только workflow. Версию Flutter меняй в `FLUTTER_VERSION` синхронно с
  `pubspec.lock` и README.

## Оформление репозитория

`branding/icon.svg` → `assets/app_icon.png` (иконка приложения, 1024×1024:
кошелёк в палитре «Лес» с карточками доходов и расходов),
`branding/icon_foreground.svg` → передний слой adaptive icon Android,
`branding/avatar.svg` → `avatar.png` (аватар репозитория, 512×512, та же
картинка, что и иконка), `branding/banner.svg` → `banner.png` (баннер README,
1280×640; использует `assets/app_icon.png` и скриншоты из `docs/`). После
правки SVG или скриншотов запусти `bash branding/render.sh` (нужны `resvg` и
Pillow). Скрипт перерисует PNG и через `tool/update_icons.py` разложит
иконку по Android, iOS, macOS, Windows и Web.

## Документация

- Меняешь протокол или его реализацию → `SYNC_PROTOCOL.md`.
- Меняешь функции относительно нативных клиентов → `FEATURE_PARITY.md`.
- Выполнил новые проверки или нашёл ограничение → `VALIDATION.md`.
- Реализовал пункт из `ROADMAP.md` → отметь его там.
- Меняешь сборку, CI или запуск → `README.md` и этот файл.
- `docs/ecosystem/` — копия общего контракта из монорепозитория; его
  ссылки на `../BalanceServer/...` и т.п. в этом репозитории не работают.
  Правь эти файлы только вместе с изменением контракта во всей экосистеме.

## Чек-лист перед PR

- [ ] `flutter analyze` — без замечаний, `flutter test` — зелёный.
- [ ] Финансовые правила и sync-контракт не разошлись с BalanceServer и другими клиентами.
- [ ] Изменения данных идут через `AppStore`, удаления — через tombstone.
- [ ] Суммы — целые сотые, интервалы — `[начало, конец)`.
- [ ] Токены только в secure storage, HTTP только для локальных адресов.
- [ ] Секреты, ключи подписи и production-URL не попали в репозиторий.
- [ ] UI проверен на телефонной и широкой ширине, в светлой/тёмной/OLED-теме.
- [ ] CI собирает все платформы; документация обновлена.
