# Native → Flutter feature audit

> Пути в колонке источников (`Balance/...`, `BalanceAndroid/...`) относятся к исходному монорепозиторию Balance, из которого выделен этот проект. Нативный клиент Apple Watch теперь живёт в отдельном репозитории BalanceWatch.

Source audit of the Swift iOS/macOS/watchOS and Kotlin Android applications. Statuses distinguish source implementation, executed automated tests and remaining platform checks; none implies complete device verification. Paths are relative to the repository root. The Apple CloudKit removal was explicitly requested; finance features and the native Watch target are retained.

## Functional matrix

| Native feature | Source | Required behavior / native differences | Flutter status |
| --- | --- | --- | --- |
| Navigation | `Balance/Balance/App/ContentView.swift`; `Balance/BalanceMac/MacContentView.swift`; `BalanceAndroid/app/src/main/java/com/example/balanceandroid/ui/BalanceRoot.kt` | Overview, analytics, transactions, budgets, settings; categories and server settings; Mac sidebar, phone bottom tabs | Implemented in `lib/ui/app.dart`; responsive rail/bottom tabs; widget verification in progress |
| Transaction model | `Balance/Balance/Models/FinanceTransaction.swift`; Android `data/Entities.kt` | UUID, positive Double amount, date, note, category name/icon/emoji/color snapshot, kind, adjustment flag, updatedAt | Implemented in `lib/domain/finance.dart`; serialization tests pass; uses integer hundredths (see deviations) |
| Total balance | `Balance/Balance/Utilities/FinanceCalculations.swift`; Android `data/FinanceMath.kt` | All income minus all expenses, including adjustments and future dates; no calculation rounding | Implemented; finance tests pass |
| Period summary | Same | Income, expenses, result; exclude adjustments | Implemented with half-open periods; finance tests pass |
| Category spending | Same | Expense only, exclude adjustments; group by category name; descending sum; first record supplies design | Implemented; grouping/exclusion tests pass |
| Calendar periods | `Balance/Balance/Views/Analytics/AnalyticsView.swift`; Android `ui/Components.kt` | Current calendar month; 3 months start two months before current month, 12 start eleven before; end is next month's start; local timezone | Implemented in source; boundary math tests pass; DST/device checks pending |
| Overview | `Balance/Balance/Views/Dashboard/DashboardView.swift`; Android `ui/BalanceRoot.kt` | Overall balance, current-month income/expenses, category bars, recent operations, add/adjust actions. iOS top 5 categories / 4 recent; Android top 7 / 5 recent; Mac top 8 / no recent; Watch 4 recent | Implemented; top 5 categories / 5 recent; widget verification in progress |
| Analytics metrics | `Balance/Balance/Views/Analytics/AnalyticsView.swift`; `Balance/BalanceMac/MacFeatures.swift`; Android `ui/BalanceRoot.kt` | 1/3/12-month selector, income/expense/result, savings `(income-expenses)/income*100` or 0 when income ≤ 0 | Implemented in source, including result and largest category; visual verification pending |
| Cash-flow graph | iOS analytics; `Balance/BalanceMac/MacFeatures.swift` | Separate income/expense sums, buckets day/weekOfYear/month for 1/3/12-month periods; no inserted zero buckets; line + points. Absent on Android/Watch | Implemented as paired bars with explicit zero buckets; calendar weeks Monday-based; different visual representation from Apple lines |
| Spending structure | iOS analytics; Mac features; Android components; Watch features | iOS donut uses top 6, legend top 5; Mac top 8 donut; Android top 7 bars; Watch top 6 bars normalized against max(first amount, 1) | Implemented as category bars and an analytical donut; all category totals retained |
| Insights | iOS analytics | Largest expense category; average daily spending = all selected-period expenses / elapsed calendar days inclusive, minimum one | Implemented in source; average daily + largest category; DST daily denominator checks pending |
| Transaction list | `Balance/Balance/Views/Transactions/TransactionsView.swift`; Android root | Date descending, all/income/expense filter, case-insensitive category/note search; include adjustments | Implemented in source; filters/search/day grouping; widget verification in progress |
| Transaction CRUD | `Balance/Balance/Views/Transactions/NewTransactionView.swift`; Android `ui/Editors.kt`, `MainViewModel.kt`; `Balance/BalanceMac/MacEditors.swift`; `Balance/BalanceWatch/WatchAddTransactionView.swift` | Add/edit amount/type/category/date/note; delete with deletion journal; kind change selects first built-in category; update timestamp on edit | Implemented in store/UI; store tests pass; widget verification in progress |
| Adjustment editing | Same | Apple locks type/category and preserves archived snapshot; Android currently permits changing type/category while flag remains true | Implemented Apple behavior in source: locked kind/category, archived snapshot; dedicated widget test pending |
| Balance adjustment | `Balance/Balance/Views/Dashboard/BalanceAdjustmentView.swift`; Mac/Watch features; Android view model | Target-current; create abs(diff), income if positive else expense; minimum abs(diff) .005; flag=true; category `Корректировка`; default note `Ручная корректировка баланса` | Implemented in source with integer-cent difference; dedicated behavioral/UI test pending |
| Built-in categories | `Balance/Balance/Models/FinanceCategory.swift`; Android entities | 9 expense / 5 income categories, locked. `Другое` appears for both kinds with distinct icons | Implemented; 9/5 catalog test passes |
| Custom category CRUD | `Balance/Balance/Views/Settings/CategoriesView.swift`; Mac editors; Watch features; Android editors/view model/DAO | Name, immutable-after-create kind, icon or emoji, color; retain transaction snapshots after deletion; rename propagates snapshots; delete associated budgets | Implemented; rename/delete cascade store tests pass; widget verification in progress |
| Category design | `Balance/Balance/Shared/CategoryDesignOptions.swift`; Android editors/components | 50 icon names, 30 suggested emojis, 24 named colors; custom emoji input; unknown color→indigo; Apple `auto` resolves built-in color by name | Implemented; 50/30/24 catalog tests pass; auto-color fallback differs |
| Monthly budgets | `Balance/Balance/Views/Budgets/*.swift`; Mac/Watch features; Android root/editors/view model | Current month only; expense built-ins + custom categories; >0 create/update, empty/invalid/≤0 delete; expense totals exclude adjustments | Implemented; explicit delete and month navigation added; UTC-to-local month regression passes under Europe/Moscow |
| Budget feedback | iOS budgets | Progress capped at 1; ≥1 red, ≥.8 orange, otherwise indigo; spent/limit, remaining, overage. Android/Mac/Watch show simpler progress + limit | Implemented in source; 80/100% colors, remaining/overage; visual checks pending |
| Currency | `Balance/Balance/Utilities/CurrencyFormatting.swift`; Android settings/components | RUB default; EUR/USD/SEK; display-only setting, no conversion or per-record currency; locale-aware formatting | Implemented; fixed ru_RU locale and two decimals differ from native device-locale 0–2 digits |
| Theme | `Balance/Balance/Shared/AppTheme.swift`; Android `ui/theme/Theme.kt` | system default, light, dark; persisted locally | Implemented in source; secure device settings round-trip not tested |
| Settings details | iOS settings; Mac/Watch features; Android root | Category/server links, operation count, storage/privacy description, version; local preferences excluded from finance sync | Implemented links/categories/about/storage messaging; saved-operation count absent at review |
| CSV export | `Balance/Balance/Views/Settings/CSVDocument.swift` | Apple iOS/Mac only; all transactions descending; `balance-transactions.csv`, UTF-8, LF, ISO8601 UTC; raw positive amount; header `Дата,Тип,Категория,Сумма,Заметка`; every value quoted and embedded quotes doubled; adjustment type `Корректировка`; disabled for empty data | Flutter 4.2 keeps the five native columns first and appends `ID,Вид,Иконка,Эмодзи,Цвет,Изменено`, writes a UTF-8 BOM and disarms formula-like cells reversibly; the file round-trips through statement import. Share/save dialogs checked on Linux and Android 15 |
| Local persistence | `Balance/Balance/Shared/BalanceModelContainer.swift`; Android `data/AppDatabase.kt` | Durable finance entities; Apple SwiftData, Android Room v1; Apple recovery falls back to in-memory if local creation fails | Implemented using transactional Sembast / IndexedDB snapshots; restart tests use memory adapter, not real disk |
| Server account | `Balance/Balance/Shared/ServerSync.swift`; Android `sync/*` | URL save, login/register (registration password ≥8), logout, manual sync, full resync, busy/message/last-sync state; retain local finance records on logout/server change | Implemented; scoped account/server isolation tests pass; device secure-storage and registration integration pending |
| Session security | Same; Android `sync/SecureSessionStore.kt` | Apple Keychain AfterFirstUnlockThisDeviceOnly; Android AES-GCM encrypted session with Android Keystore; tokens never finance payload | Implemented through flutter_secure_storage with session-only fallback warning; physical-device secure storage unverified |
| Server protocol | Same | POST auth/register/login/refresh/logout and sync; bearer token; ISO8601 dates; stable device UUID; transaction/category/budget payloads; refresh within 60s of expiry and one retry on 401 | Implemented in `lib/services/sync_api.dart`; mock server store tests pass; see separate protocol integration evidence |
| Incremental sync | Same | 100-record pages; cutoff fixed for run; 5s overlap on lastPush; push entities + tombstones, then pull; per-server/user cursor; cursor monotonic; hasMore must advance cursor | Implemented durable dirty outbox, 100-record batching, push/pull cursor; differs from native 5-second watermark scanning |
| Conflict/deletion handling | Same; `Balance/Balance/Models/SyncTombstone.swift`; Android DAO | Remote upsert only when strictly newer, remote delete when local timestamp ≤ remote; order changes by sequence; deletion journal dedup by entity/id, clear after corresponding pull | Implemented; pending-delete conflict and failed-page rollback tests pass; delete-wins policy differs from native LWW |
| Automatic sync | Apple content/root views; Android `BalanceApplication.kt`, `sync/SyncWorker.kt` | Apple immediately and each 120 seconds while root task lives; Android ViewModel initialization and connected-network WorkManager every 15min, retry on failure | Foreground startup/resume and 2-minute timer plus Android 15-minute connected-network WorkManager implemented; native lock JVM tests pass; real suspended-app execution pending |
| CloudKit | Apple local store and entitlements | Intentionally removed by user request; synchronization uses the Go server only | **Removed by request; not a parity gap** |
| Apple Watch | `Balance/BalanceWatch/*.swift` | Native Watch overview, analytics, transaction/category CRUD, budgets, adjustment, theme/currency/server settings; independent server login, no CSV, no WatchConnectivity bridge or complications | Retained native Watch target via `scripts/build.sh watchos`; no Flutter watchOS runner; Apple SDK build unverified |

## Edge cases and deliberate parity decisions

1. **Period end:** Swift `DateInterval.contains` includes its end, Android uses `[start,end)`. A transaction exactly at next month's start can be counted twice by Apple month views. Choose and document one Flutter rule; do not accidentally use different rules for charts/budgets/summary.
2. **Future records:** overall balance includes every date. Period analytics includes future records within the period, while iOS daily-average denominator only runs through today.
3. **Money parsing:** iOS removes ASCII spaces, replaces comma with dot, requires >0. Android only replaces comma. Mac/Watch use native number input. Explicit finite-number validation is absent from native editors; NaN/Infinity must not corrupt persisted/exported finance data.
4. **Archived category:** Apple adds missing transaction category snapshots to editor choices; Android falls back to first built-in, losing archived design on save.
5. **Duplicate category names:** Apple blocks names matching any built-in/custom category across both kinds, case/diacritic insensitive. Android checks custom categories of the same kind only; built-in names can collide.
6. **Rename cascade:** iOS matches name+kind for transactions and only updates budgets for expense categories. Android/Mac/Watch match name only and can affect an opposite-kind collision.
7. **Delete cascade:** iOS deletes category budgets only for expense kind; Android/Mac/Watch delete all matching-name budgets. Transactions remain on every platform.
8. **Duplicate budgets:** no category/month uniqueness constraint. Apple editor's `Dictionary(uniqueKeysWithValues:)` traps on duplicate names. Android updates the first matching budget. Flutter should merge or reject duplicates explicitly.
9. **Month timezone:** Apple includes budget monthStart within current interval; Android requires exact equality with locally calculated month start. A timezone change can hide Android imported budgets.
10. **Limit precision:** iOS pre-fills budget limits with `%.0f`, so saving unchanged rounds fractional limits. Mac/Watch/Android retain fractions.
11. **Limit equality:** iOS displays "Лимит превышен на 0" at exact limit. Android progress divides by max(limit,1), which differs for sub-unit limits.
12. **Emoji:** iOS limits input to one grapheme; Mac/Watch take first Swift Character on save. Android accepts an arbitrary string.
13. **Notes:** iOS/Android transaction editors trim notes, Mac/Watch do not. Adjustment defaults: iOS trims; Android uses ifBlank without trimming a nonblank note; Mac/Watch use isEmpty.
14. **Unknown kind:** Apple getter defaults to expense. Android totalBalance subtracts unknown kind but summary/spending exclude it because they test literal `expense`.
15. **CSV is lossy (native):** no UUID, kind for adjustment, flag, timestamps, category design, custom-category definitions or budgets; an expense adjustment exports positive amount with no recoverable sign. Formula-like notes are quoted but not neutralized by native export. Flutter 4.2 makes its transaction CSV lossless with appended columns (see Data tools 4.2); categories and budgets are only in the JSON backup.
16. **Sync sizes:** Apple rejects individual payload >256 KiB and splits full bodies >1.5 MB. Android splits changes arrays >1.5 MB, without the Apple single-payload guard.
17. **Server URL:** Apple HTTP allows localhost/127.0.0.1/::1; Android localhost/127.0.0.1/10.0.2.2. Android rejects userinfo/query/fragment; Apple has no explicit equivalent rejection.
18. **Deletion journal:** Apple UserDefaults journal quarantines corrupt data and validates UUID/entity; Android Room journal is transactional with local deletion. A successful push alone must not discard tombstones.
19. **Preferences:** theme, currency, server session remain device-local, including Watch; they are not in synced finance payloads.
20. **Rounding:** Apple currency display allows 0–2 fractional digits and narrow symbol; Android NumberFormat uses 0 fractional digits for integral values, otherwise up to 2. Display formatting must not alter stored amounts.

## Storage and migration

CloudKit was intentionally removed by user request. The Apple model container now always uses a persistent local SwiftData store (`cloudKitDatabase: .none`), with the existing in-memory recovery fallback. Cloud capabilities, configuration flags and setup instructions have been removed. Finance synchronization uses only the Go server; there is no CloudKit bridge or CloudKit parity requirement.

No explicit old-store importer exists in native Swift/Kotlin. A new Flutter JSON/SQLite store does not automatically discover SwiftData or Room databases, and a new app identity does not grant access to the old sandbox. Preserve original installations until transfer is verified.

The practical complete-model transfer is to sync the original app with its Go server, sign into the same server/account from Flutter, then pull transactions, custom categories, budgets and deletion records. Preserve UUIDs, timestamps, category snapshots and adjustment flags. Validate counts, per-month summaries, total balance and representative adjustments before retiring the original store. CSV is an export report, not a complete migration format (see edge case 15).

Local-only data without a server still requires either this server route or a tested native upgrade/export plus complete Flutter importer. Data that was never downloaded from an earlier cloud-backed deployment is not migrated automatically by this change; keep that original deployment available until its records have been transferred. Do not claim automatic existing-data migration.

## Native test baseline

`Balance/BalanceTests/FinanceCalculationsTests.swift`: summary income/expenses, outside-period filtering, spending grouping with emoji/color, all-time balance including adjustments, adjustment exclusion, deletion journal dedup/removal.

`BalanceAndroid/app/src/test/java/com/example/balanceandroid/FinanceMathTest.kt`: income/expense/adjustment summary and category grouping.

Native tests do not cover period end, timezone changes, duplicate budgets, CSV or migration. Flutter verification should exercise those behaviors in addition to the baseline math tests.

## Flutter review evidence and remaining checks

The audit executed 12 `finance_test.dart` tests successfully before the additional exact-local-storage regression was added with `TZ=Europe/Moscow`, including an imported native budget at local January 1 serialized as December 31 UTC. `budgetUsed` now recovers the local calendar month. The store owner also normalizes budget duplicate comparisons with `.toLocal()`.

Six `app_store_test.dart` tests passed in the audit run: restart snapshot, rename cascade, delete conflict, category deletion, failed pull rollback, account/server isolation. Storage uses the memory adapter in those tests; durable on-disk and OS keychain checks are separate requirements.

Narrow-editor action overflows found in the initial run were corrected. The final 22 UI/screenshot tests pass on 320/390/1280 widths, including 1.5 text scale, dark mode, CRUD, negative adjustment and mocked native CSV selector/share. Screen-reader, real software keyboard, native system dialogs, suspended-app and production secure-storage behavior remain device checks.

Intentional/current Flutter differences from the native source:

- Money is stored as integer hundredths. Incoming native sub-cent amounts are rounded on import, even though native models accept arbitrary Double precision. New inputs permit at most two decimals; this is a data-model policy change, not bit-for-bit Double parity.
- Half-open month intervals avoid Apple's inclusive-end overlap. Unknown kinds default to expense consistently.
- UI uses a responsive Material 3 layout, paired cash-flow bars, category bars and an analytical donut. The cash-flow graph retains period totals with paired bars instead of the Apple line style. Zero periods are explicit.
- Locale is fixed to Russian and currency always uses two decimals. Native follows device locale and allows zero decimals for whole amounts.
- Budgets can navigate other months and are edited individually. Empty/zero does not delete through the editor; an explicit delete action is available. Categories are sorted by name rather than native creation order.
- Account/server ledgers are isolated. Native keeps one shared ledger across account/server changes. First guest import is conditional and once per server; preserve guest data and explain this condition in the UI.
- The Flutter outbox retains deletion knowledge and prefers an unsent local deletion over a newer server edit by issuing a newer delete. Native uses simple last-write-wins timestamps.

Additional safety/data checks from source review:

- Main ledger records do not contain auth tokens; session data goes through secure storage. Failed secure-store access produces a visible session-only fallback rather than writing plaintext credentials.
- Server URLs are validated by the same transport rules before account changes; insecure HTTP is limited to loopback and the Android emulator address. Android network-security and Apple local-network ATS exceptions are configured; real-device connectivity remains a device check.
- Transaction editor choices deduplicate imported category names to avoid duplicate dropdown-value assertions while retaining archived snapshot categories.
- A native preexisting SwiftData/Room database is not automatically imported by the new app identity. Use the Go transfer route above; the native Watch ledger also requires the same server/account.
- Scoped ledgers are loaded into memory once and stored per record in Sembast (4.2): each edit or pull page writes only changed records with the cursor in one transaction. A shared `ledgerRevision` preference tells engines when to reload; see `VALIDATION.md` for the 1k/10k/50k benchmark.
- Corrupt local records no longer fail initialization (4.2): each is set aside into a per-scope quarantine and startup continues; see Data tools 4.2.
- Remote payload validation checks envelope shape; a pulled change that fails model decoding is quarantined (source `server`) and skipped, the page and cursor still commit, and the sync message reports the count (4.2). Envelope/protocol errors still abort the pull.
- Nonpositive imported budget limits do not produce division by zero; local UI requires a positive replacement limit. Invalid server data can be repaired through the editor.
- Flutter CSV (4.2) carries every transaction field (id, kind of an adjustment, category design, `updatedAt`) and prefixes formula-like cells (`= + - @`, tab, CR, apostrophe) with an apostrophe that its own importer removes. It still holds transactions only; the JSON backup also restores categories, budgets and deletions.

## Android background synchronization verification

`lib/services/background.dart` registers unique periodic WorkManager task `balance-periodic-sync` with a 15-minute frequency, connected-network constraint and update policy. Its preserved entry-point dispatcher initializes Flutter plugins, creates `AppStore(background: true)`, restores the current account and performs the same full push/pull/refresh flow as the foreground. Errors return false for WorkManager retry; credentials are not logged or copied to a plaintext mirror. No scheduler calls are made on web or non-Android platforms. `main.dart` surfaces scheduler initialization failure while keeping foreground use available.

`packages/balance_runtime` is a real Android FlutterPlugin registered in foreground and headless engines. Its `balance/runtime` channel acquires a process-wide fair Semaphore and an OS FileChannel lock on one app-private lock file. Acquisition runs off the Android main thread. An engine-specific token is required to release the lock; detach cancels waiters and releases held locks. Overlapping acquisition from the same engine fails rather than deadlocking a single acquisition executor.

AppStore holds this lock across each complete serialized operation, reloads preferences and protected credentials/ledger after acquisition, and releases after completion. Sembast connections open and close for each read/write so a headless isolate does not read a stale open-connection cache. Consequently OAuth refresh rotation, account changes, pushes, pulled-page commits and foreground edits share the same lock, rather than racing an independently refreshed token mirror. Background stores have no timer or lifecycle observer, and the worker awaits close before it exits.

Executed checks:

- Android release Java compilation passed for the local plugin.
- Three JVM tests passed: concurrent thread ownership + idempotent release; interrupted waiter recovery; a separate JVM process blocked on the real OS lock until the first owner released it.
- Three Dart channel tests passed: engine token supplied on release, absent token fails closed, non-Android calls are no-ops.
- Targeted Dart analysis of background/runtime modules passed.

These checks do **not** prove actual Android OS wake-up, force-stop/reboot behavior, OEM battery restrictions, keychain access in a suspended process, or engine teardown during a real network request. Run a signed-device test with UI closed, an expired access token, queued edits/deletions, remote changes and simultaneous foreground resume. Fifteen minutes is the requested minimum interval; Android controls the actual execution time. The same native file lock guards engines/processes of this app; other platforms retain their foreground-only behavior.

## Web multi-tab coordination

`RuntimeLock` conditionally loads `runtime_lock_web.dart`. Each real AppStore operation acquires the exclusive origin-wide Web Lock `balance-ledger-v1`, then reloads shared preferences, credentials and the IndexedDB snapshot before mutating or refreshing tokens. The lock callback returns an unresolved JS Promise held until `release()` completes it, so another tab cannot overwrite a stale whole-ledger snapshot or rotate the same refresh token concurrently. Browser teardown releases ownership. Acquisition failures reject the waiting Dart caller; the app fails closed with a clear HTTPS/localhost or unsupported-Web-Locks message instead of silently using an unsafe no-op lock.

The web helper uses SDK `dart:js_interop` only. The audit compiled `scripts/probe_web_lock.dart` to JavaScript and ran it against Node 24's native `navigator.locks`: two separate owner instances serialized, ownership released/reacquired, duplicate acquire/release rejected, insecure origin rejected, unsupported API rejected. The existing three Android channel tests still pass, and targeted analyzer checks pass. This exercises native Web Locks Promise semantics, not a real browser two-tab IndexedDB/keychain scenario; that integration remains an explicit runtime check. The platform owner rebuilds the full release web bundle after this change.

Desktop multiple independent app processes are not coordinated by this Web/Android helper. Standard desktop runners have one foreground AppStore; simultaneous desktop instances require a separately tested OS file-lock implementation before they can be claimed safe.

## Appearance update 4.1

Flutter supports system/light/dark mode plus five persisted presets (forest, indigo, ocean, rose, OLED). Selecting OLED initially enables dark mode; system mode subsequently follows OS brightness. Pure-black surfaces are checked both as theme colors and actual rendered pixels. Total Flutter tests: 62 passing. The native Watch client retains its existing appearance controls.

## Data tools 4.2

Flutter-only additions; the wire protocol is unchanged and there is no native equivalent.

- JSON backup/restore (`balance-backup`, version 1): lossless (ids, `amountMinor`, `updatedAt`, adjustment flag, category design, custom categories, budgets, tombstones); queue and cursor are per-device and excluded. Restore merges by last-write-wins on `updatedAt`, queues restored records for sync, and rejects a newer format version.
- Local quarantine of damaged records and failed pulled changes, with a JSON report and clear action in Settings → «Данные».
- Bank statement import: CSV (auto delimiter and encoding, Т-Банк preset, column mapping) and OFX 1.x/2.x, with stable UUIDv5 ids so re-import adds nothing. Balance's own CSV export is recognized by its header and imported with its original ids, adjustment flags and category design.
- Restore preview: a dry run lists what each backup record would do (add, update, delete, or skip with a reason) and only the selected records are restored.

## Quick entry 4.2

Flutter-only, no wire or model change; templates are device preferences (`quickTemplates`) like theme and currency.

- Repeat and save-as-template from a transaction's menu (not for balance adjustments); «Быстрый ввод» chips show saved templates and up to three presets repeated at least twice in the last 90 days.
- App icon shortcuts «Расход»/«Доход» via `quick_actions` (Android, iOS). Android also has a Quick Settings tile and a home-screen widget; both open the editor through the `balance/launch` method channel (`initialAction`, `action`, `updateWidgets`).
- The widget reads preformatted `flutter.widget.*` strings that AppStore writes after every operation when they change; background sync updates them too, and the widget refreshes on its 30-minute schedule. No iOS widget yet.

## Privacy 4.2

Flutter-only, device-local, never synced: optional app lock with a 4–8 digit PIN (salted PBKDF2-HMAC-SHA256 in secure storage, throttled after five wrong attempts) and biometrics via `local_auth` (Android, iOS, macOS, Windows Hello; not Linux or Web). The lock shows at start and after a chosen time in the background; the interface stays offstage, out of the accessibility tree, while locked. «Скрывать в недавних приложениях» covers the app-switcher snapshot (Android 13+ `setRecentsScreenshotEnabled`, `FLAG_SECURE` below; a Flutter cover on iOS). Android's MainActivity is now a `FlutterFragmentActivity` with an AppCompat launch theme, as `local_auth` requires.

## Notifications 4.2

Flutter-only, device-local, off by default; the permission is requested when a switch is turned on. Budget alerts (`flutter_local_notifications`, all platforms) fire once per budget, month and threshold (80%, 100%) after local edits and, on Android, after background sync; the text has percentages only, the Android visibility is private. Turning alerts on records current levels silently. The daily reminder (Android, iOS, macOS; Linux/Web have no scheduler, Windows no repeats) is scheduled inexactly and moves to the next day when something was entered today. Rules live in `lib/domain/notifications.dart` and use `FinanceMath.budgetUsed`. System UI the app opens itself (pickers, share sheet, permission and biometric prompts) runs inside `AppLock.whileExternal`, so it does not relock the app.
