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
