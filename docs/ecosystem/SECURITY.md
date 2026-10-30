# Безопасность (сквозные требования)

> **Справочный документ экосистемы Balance.** Скопирован из корня монорепозитория Balance (`docs/`) при выделении BalanceFlutter в отдельный репозиторий. Описывает общий контракт всех клиентов; ссылки вида `../BalanceServer/...`, `../Balance/...`, `../BalanceAndroid/...` указывают на файлы монорепозитория и в этом репозитории не открываются. Реализация Flutter-клиента — [`../../SYNC_PROTOCOL.md`](../../SYNC_PROTOCOL.md).

Этот документ собирает требования безопасности, которые применяются
ко **всем** подпроектам одновременно. Платформенно-специфичные детали —
в [`BalanceServer/docs/SECURITY.md`](../BalanceServer/docs/SECURITY.md),
`Balance/AGENTS.md` (раздел «Безопасность») и
`BalanceAndroid/AGENTS.md` (раздел «Security»).

## Хранение секретов на клиентах

| | Apple | Android |
| --- | --- | --- |
| Access/refresh токены | Keychain (service `BalanceServer`) | зашифрованное хранилище через Android Keystore (AES/GCM), `SecureSessionStore` |
| Несекретные настройки (URL сервера, cursor, sync metadata) | `UserDefaults` | `ServerPreferences` |
| Запрещено | пароль в `UserDefaults`, SwiftData или файлах | токены в обычных `SharedPreferences` |

Ни один клиент не должен хранить пароль пользователя после
аутентификации — только access/refresh токены.

## Хранение секретов на сервере

- Пароли — только Argon2id-хеши, plaintext никогда не сохраняется.
- Refresh-токены хранятся как SHA-256 хеши, не в открытом виде.
- `BALANCE_JWT_SECRET` должен быть случайной строкой не короче 32
  символов; его смена инвалидирует access-токены (refresh-сессии
  остаются валидны и получают новый access-токен при следующем
  refresh).

## Транспорт

- Для удалённого (не-localhost) сервера все клиенты обязаны
  использовать HTTPS.
- HTTP разрешён клиентам **только** для `localhost`, `127.0.0.1` и
  `::1` — это относится и к Apple-, и к Android-клиенту.
- Production-деплой сервера должен работать через HTTPS/TLS
  (например, через reverse proxy — Caddy/nginx), см.
  [`BalanceServer/README.md#https`](../BalanceServer/README.md#https).

## Логирование

Запрещено логировать на любой из трёх платформ:

- пароли;
- access/refresh токены;
- заголовок `Authorization` целиком;
- полные request bodies с финансовыми данными без явной необходимости.

Безопасно логировать (на сервере): request ID, endpoint, status code,
latency, размер batch, неконфиденциальные идентификаторы записей.

## Авторизация на сервере

Каждая sync-мутация обязана проверять ownership по authenticated user
из токена/сессии. Никогда не доверяй `userId`, пришедшему в теле
запроса от клиента, если identity уже известна из
Authorization-заголовка или cookie-сессии:

```text
Authorization header / session cookie
        ↓
   authenticated user
        ↓
   server-side ownership check
        ↓
   requested entity
```

## Валидация входных данных (сервер)

Проверяются: UUID/ID, enum-значения, `amount`, timestamps, длины строк,
размер batch, размер JSON, границы cursor/sequence.

## Защита от злоупотреблений (production-деплой сервера)

- rate limiting для auth-эндпоинтов (встроенный лимитер — 30
  auth-запросов на IP в минуту; для более сильного публичного
  rate limiting используйте reverse proxy);
- разумные ограничения на размер тела запроса;
- таймауты и graceful shutdown;
- ограничение подключений к БД;
- мониторинг.

## Секреты в репозитории

Ни в одном из трёх подпроектов не должны появляться:

- production URL серверов;
- реальные `BALANCE_JWT_SECRET` или иные секреты;
- закоммиченные `.env`, keystore-файлы, сертификаты;
- захардкоженные тестовые credentials, которые могут быть спутаны с
  боевыми.

`.env.example` в `BalanceServer/` и `local.properties.example` в
`BalanceAndroid/` — единственные допустимые «примерные» файлы с
конфигурацией; реальные значения в них не хранятся.
