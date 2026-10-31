# Balance sync wire protocol

`lib/services/sync_api.dart` implements the existing Go `/v1` API using
`package:http`. It uses JSON maps independently of local model classes. Add
`http` to the app's dependencies. No server modifications are required.

## Authentication

- `register(email, password)` and `login(email, password)` POST to
  `/v1/auth/register` and `/v1/auth/login` with `{email,password}`.
- They return `{accessToken,refreshToken,expiresAt,user:{id,email}}`.
- `refresh(refreshToken)` POSTs `{refreshToken}` to `/v1/auth/refresh` and
  **rotates** the refresh token. Serialize refresh operations and save the full
  returned session atomically in the separate secure session store.
- `me(accessToken)` GETs `/v1/me` using `Authorization: Bearer …`.
- `logout(refreshToken)` POSTs to `/v1/auth/logout` (204). Clear the local store
  in `finally`; offline logout cannot revoke the server session.

The client is stateless and never persists tokens. Its caller should refresh
60 seconds before `expiresAt`, retain sessions on transient network/5xx errors,
clear them on invalid refresh credentials, and retry an authorized request at
most once following a successful refresh on 401. Concurrent refreshes must share
one in-flight operation because refresh tokens are single-use. `synchronize`
accepts an async `accessToken` provider for this external session manager; it
does not automatically replay failed HTTP requests. HTTP errors expose status,
server error code and message through `SyncApiException`; network, timeout and
format errors remain distinct exceptions. Never log session maps or passwords.

## Sync and payloads

POST `/v1/sync` with:

```json
{"cursor":0,"deviceId":"stable-device-id","changes":[{"entity":"category","id":"UUID","deleted":false,"updatedAt":"2026-10-28T12:00:00Z","payload":{"name":"Food","icon":"cart","emoji":"","colorName":"indigo","kindRawValue":"expense","createdAt":"2026-10-28T12:00:00Z"}}],"pull":false}
```

The server returns `{cursor,changes,serverTime,hasMore}`. Changes include server
`version` and global `sequence`; neither is an optimistic concurrency precondition.
Timestamps use RFC3339 UTC (Dart: `date.toUtc().toIso8601String()`). Preserve
record IDs exactly, including UUID case; Swift uses UUID IDs. The current server
does not use `deviceId` for conflict resolution.

| Entity | Active payload fields |
| --- | --- |
| `transaction` | `amount` number, `date` timestamp, `note`, `categoryName`, `categoryIcon`, `categoryEmoji`, `categoryColorName`, `isBalanceAdjustment` boolean, `kindRawValue` (`income` / `expense`) |
| `category` | `name`, `icon`, `emoji`, `colorName`, `kindRawValue`, `createdAt` timestamp |
| `budget` | `categoryName`, `categoryIcon`, `categoryEmoji`, `limit` number, `monthStart` timestamp |

Deletion uses the same envelope with `deleted:true`, an updated timestamp and
no payload. Keep tombstones until confirmed by a pulled change. The server limits
requests to 2 MiB, 5000 changes and each payload to 256 KiB; it rejects timestamps
over 24 hours into its future. `synchronize` uploads immutable snapshots in batches
of 100, splitting batches beyond 1.5 MB, then downloads 500-record pages. Push-only
requests do not advance the cursor. `sync` exposes a single page for custom flows.

## Durable merge contract

Scope cursor and push watermark by normalized server URL **and user ID**. Never
reuse another account's cursor. Serialize full sync runs. Capture a cutoff and a
stable snapshot of local edits up to that cutoff before starting. Native clients
query edits after `lastPush - 5 seconds` (or from zero after a clock rollback),
plus pending tombstones; overlapping uploads are safe.

The server keeps a change only when `incoming.updatedAt > existing.updatedAt`:
last timestamp wins, and equal timestamps leave the existing server value. Pull
in sequence order. Apply an active record only when it is newer than the local
record; apply a deletion when its timestamp is at least the local timestamp.
A pending local tombstone must also participate in this comparison, preventing
an older remote active record from resurrecting a newer local deletion. Remove
a pending tombstone only when a confirmed remote change is at least as new.

`synchronize(..., applyPage: (changes, cursor) async { ... })` requires the caller
to merge a complete page and store its cursor in one durable transaction. Throw
on malformed/unapplied records; advancing the cursor would otherwise lose data.
It validates page order and cursor progress before invoking this callback. Record
the push cutoff only after the entire method succeeds. A failed run can replay
its snapshot safely; do not remove edits made concurrently after the cutoff.

## Browser considerations

Use HTTPS. Local HTTP development requires explicit `allowInsecureHttp:true`;
browsers still block HTTPS-to-HTTP mixed content. Cross-origin Flutter Web needs
the exact frontend origin in the existing server CORS configuration. This client
uses bearer headers and refresh tokens in JSON, not credentialed browser cookies;
the server currently has no `Access-Control-Allow-Credentials`, and its cookies
are `SameSite=Strict`. A cross-site cookie session cannot be assumed to work.
Browser token persistence is a separate security decision: do not use
localStorage/SharedPreferences for tokens; memory-only sessions require login
after reload. JavaScript execution can access any tokens returned to the app,
so XSS remains a risk even with encrypted browser persistence. Native platforms
should use their OS secure storage. Cursors above 2^53−1 are rejected to avoid
silent precision loss in Flutter Web. The transport disables redirect following
where supported; browsers may manage redirects themselves, so configure the
final HTTPS API URL directly.

## Contract v2

`docs/ecosystem/CONTRACT_V2.md` is the shared contract; this section is how
the Flutter client implements it. Everything is additive: `/v1/sync`, cursor,
`sequence`, `updatedAt`, tombstones and last-write-wins are unchanged.

### Entities and payloads

`syncEntities` in `sync_api.dart` lists the eleven entities. Models live in
`lib/domain/finance.dart` (transaction, category, budget) and
`lib/domain/records.dart` (account, transfer, recurring, goal, debt, rate,
setting, attachment); `entityCodecs` maps each entity to its local snapshot
section and storage key prefix.

| Entity | Payload fields (v2) |
| --- | --- |
| `transaction` | v1 fields plus optional `accountId`, `currency`, `tags`, `recurringId`, `occurrence`; written only when set, so a v1 record keeps its exact v1 payload |
| `account` | `name`, `kindRawValue` (`cash`/`card`/`deposit`/`other`, unknown read as `other` but kept), `icon`, `colorName`, `currency` (null = base), `createdAt`, `isArchived`, `sortOrder` |
| `transfer` | `fromAccountId`, `toAccountId`, `amount` (source currency), `toAmount` (default `amount`), `date`, `note` |
| `recurring` | `kindRawValue`, `amount`, `currency`, `accountId`, category snapshot, `note`, `tags`, `frequency`, `interval`, `startDate`, `endDate`, `mode`, `isPaused`, `generatedThrough` (`YYYY-MM-DD`) |
| `goal` | `name`, `target`, `currency`, `deadline`, `accountId`, `saved`, `icon`, `colorName`, `createdAt`, `isArchived` |
| `debt` | `person`, `direction` (`iOwe`/`owedToMe`), `amount`, `currency`, `date`, `dueDate`, `note`, `repaid`, `isClosed` |
| `rate` | `from`, `to`, `rate` (decimal **string**, ≤ 6 fractional digits, > 0), `date` |
| `setting` | id is the key; `{"value": …}`; known key `baseCurrency` |
| `attachment` | `transactionId`, `sha256` (64 lower-case hex), `contentType`, `size`, `name`, `createdAt` |

Money is integer hundredths inside the client and a number on the wire, as in
v1. Every record keeps payload fields it does not know in `extra` and sends
them back unchanged on the next save (§0.2); local-only snapshot keys (`id`,
`updatedAt`, `amountMinor`, `limitMinor`) never enter a payload. A pulled
change of an unknown entity is skipped by `SyncApi.sync` after its `sequence`
was validated, so the cursor still advances (§0.1). An unreadable record of a
known entity is quarantined as in v1.

### Capabilities

`SyncApi.capabilities()` reads `GET /v1/capabilities` without authorization;
404 yields `ServerCapabilities.v1`. AppStore checks at most every 10 minutes
before a sync (and after sign-in), caches the answer per server in
preferences, and keeps the last answer (v1 if none) when the check fails.
Only changes whose entity the server lists are pushed; the rest stay in the
queue until a later check reports them, so nothing is lost on a v1 server.
Attachments and ledgers require `attachments`/`ledgers` in the answer.

### Ledgers

The data scope is `server|user` for the personal ledger (the v1 key, so
existing data stays put) and `server|user|ledger:<id>` for a shared one; each
has its own records, queue, tombstones, quarantine and cursor. The chosen
ledger is a per-server, per-user preference (`activeLedger.…`); sign-in starts
in the personal ledger, where guest records are imported. `/v1/sync` and
`/v1/attachments/*` carry `X-Balance-Ledger: <id>` for a shared ledger only.
`SyncApi` implements every `/v1/ledgers` route; AppStore keeps the list
(id, name and role only; member e-mails are not stored) and returns to the
personal ledger when the active one is deleted, left, or answers 403/404.

### Attachments

`addAttachment` hashes the bytes (SHA-256), checks type and size against the
capabilities (contract defaults until known), writes them to the
content-addressed `AttachmentCache` (files under the app support directory on
native platforms, a separate IndexedDB database on Web) and queues the record
plus an `uploads` entry in the ledger snapshot. A sync PUTs pending files
first and pushes an attachment record only after its file was uploaded. Bytes
are downloaded lazily (`attachmentBytes`), verified against the hash and
cached. Local copies are not deleted with a record: another ledger may share
the file.

### Recurring operations

`RecurringEngine` (`lib/domain/recurring.dart`) computes occurrences in the
UTC calendar; transaction ids are UUID v5 (namespace
`6f1c3f5e-8a8d-4c3a-9d2b-4b1f0e7a2c11`, name
`recurring:<recurringId>:<occurrence>` in lower case). `auto` rules run when
saved, at startup without an account, and after every successful pull, never
before it, so progress (`generatedThrough`) and deletions from other devices
are known first; an id already present or tombstoned is never recreated.
Created records are pushed on the next sync.
