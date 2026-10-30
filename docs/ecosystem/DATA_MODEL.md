# Сквозная модель данных

> **Справочный документ экосистемы Balance.** Скопирован из корня монорепозитория Balance (`docs/`) при выделении BalanceFlutter в отдельный репозиторий. Описывает общий контракт всех клиентов; ссылки вида `../BalanceServer/...`, `../Balance/...`, `../BalanceAndroid/...` указывают на файлы монорепозитория и в этом репозитории не открываются. Реализация Flutter-клиента — [`../../SYNC_PROTOCOL.md`](../../SYNC_PROTOCOL.md).

Три платформы реализуют одну и ту же доменную модель независимо, на
своём стеке хранения. Этот документ сопоставляет поля между ними.
Полные описания — [`Balance/docs/DATA_MODEL.md`](../Balance/docs/DATA_MODEL.md),
[`BalanceAndroid/docs/DATA_MODEL.md`](../BalanceAndroid/docs/DATA_MODEL.md),
[`BalanceServer/docs/DATA_MODEL.md`](../BalanceServer/docs/DATA_MODEL.md).

## Транзакция

| Логическое поле | Apple (`FinanceTransaction`) | Android (`TransactionEntity`) | Сервер |
| --- | --- | --- | --- |
| Идентификатор | `id: UUID` | `id: String` (UUID) | stable ID |
| Сумма | `amount: Double` | `amount: Double` | amount |
| Дата операции | `date: Date` | `date: Long` (epoch millis) | date |
| Заметка | `note: String` | `note: String` | note |
| Имя категории (snapshot) | `categoryName: String` | `categoryName: String` | category presentation data |
| Иконка категории | `categoryIcon: String` (SF Symbol) | `categoryIcon: String` | — |
| Emoji категории | `categoryEmoji: String` | `categoryEmoji: String` | — |
| Цвет категории | `categoryColorName: String` | `categoryColorName: String` | — |
| Корректировка баланса | `isBalanceAdjustment: Bool` | `isBalanceAdjustment: Boolean` | balance-adjustment flag |
| Тип операции | `kindRawValue: String` (`income`/`expense`) | `kindRawValue: String` | transaction kind |
| Версия/время изменения | `syncUpdatedAt: Date` | `updatedAt: Long` | `updatedAt` |
| Владелец | сессия аккаунта | сессия аккаунта | принадлежность пользователю |

**Категория хранится snapshot'ом**, а не ссылкой, на всех платформах:
это позволяет не терять отображение старой операции при удалении
категории и синхронизировать запись без relationship. Из-за этого
переименование пользовательской категории должно явно обновлять уже
существующие транзакции и бюджеты — и Apple-, и Android-клиент это
делают.

## Пользовательская категория

| Логическое поле | Apple (`CustomCategory`) | Android (`categories`) | Сервер |
| --- | --- | --- | --- |
| Идентификатор | `id: UUID` | `id` | stable ID |
| Имя | `name: String` | `name` | name |
| Иконка | `icon: String` | `icon` | icon/emoji |
| Emoji | `emoji: String` | `emoji` | — |
| Цвет | `colorName: String` | `colorName` | color |
| Тип | `kindRawValue: String` | `kindRawValue` | operation kind |
| Создание | `createdAt: Date` | `createdAt` | creation metadata |
| Версия | `syncUpdatedAt: Date` | `updatedAt` | update metadata |

Имя пользовательской категории уникально без учёта регистра/диакритики
относительно системных и других пользовательских категорий (проверяется
на клиентах). Встроенные системные категории (Продукты, Транспорт,
Зарплата и т.д.) не персистятся как отдельные записи ни на одной
платформе — они закодированы в клиентском коде.

## Месячный бюджет

| Логическое поле | Apple (`MonthlyBudget`) | Android (`budgets`) | Сервер |
| --- | --- | --- | --- |
| Идентификатор | `id: UUID` | `id` | stable ID |
| Имя категории | `categoryName: String` | `categoryName` | category information |
| Иконка/emoji категории | `categoryIcon`, `categoryEmoji` | `categoryIcon`, `categoryEmoji` | — |
| Лимит | `limit: Double` | `limitAmount: Double` | monthly limit |
| Начало месяца | `monthStart: Date` | `monthStart: Long` | month start |
| Версия | `syncUpdatedAt: Date` | `updatedAt: Long` | `updatedAt` |

Бюджет идентифицируется собственным UUID, но связывается с категорией
по сохранённому имени (`categoryName`), а не по ссылке.

## Tombstone / deletion journal

| Логическое поле | Apple (`SyncTombstone`) | Android (`deletion_journal`) | Сервер (change record) |
| --- | --- | --- | --- |
| Идентификатор записи | `id: UUID` | `id = entity:recordId` | record ID |
| Тип сущности | `entity: String` | `entity` | entity |
| ID удалённой записи | `recordID: String` | `recordId` | id |
| Время | `updatedAt: Date` | `updatedAt: Long` | `updatedAt` |
| Флаг удаления | подразумевается (`deleted: true` в payload) | подразумевается | `deleted: true` |

Поддерживаемые значения `entity` одинаковы на всех платформах:
`transaction`, `category`, `budget`.

## Финансовые инварианты (одинаковы на Apple и Android)

1. `amount` не может быть отрицательным через обычный UI.
2. Общий баланс = `sum(income.amount) − sum(expense.amount)`; записи с
   `isBalanceAdjustment == true` **учитываются** в этой сумме.
3. Периодическая аналитика **исключает** balance adjustments и записи
   вне выбранного периода.
4. Расходы группируются по `categoryName` (не по ID категории).
5. `syncUpdatedAt`/`updatedAt` обязано меняться при каждом изменении
   синхронизируемой сущности.
6. Удаление синхронизируемой сущности обязано создать tombstone —
   прямой `DELETE`/`delete()` без tombstone запрещён.

Источники правды по расчётам:
`Balance/Balance/Utilities/FinanceCalculations.swift` (Apple) и
`BalanceAndroid/.../data/FinanceMath.kt` (Android). При изменении
правил на одной платформе перенеси изменение на другую.

## Инварианты на стороне сервера

1. Record ID стабилен между синхронизациями.
2. Запись принадлежит ровно одному пользователю; клиент не может
   читать/изменять чужие записи.
3. `sequence` (серверный порядок изменений) не должен уменьшаться.
4. Повторная доставка одного и того же изменения не должна повреждать
   данные (идемпотентность).
5. Удаление обязано быть видимым клиенту через следующий pull.
6. Все timestamps хранятся в UTC.
7. Enum/строковые значения (`kindRawValue` и т.п.) совместимы между
   iOS и Android — не переименовывать без периода совместимости.
