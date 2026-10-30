#!/usr/bin/env bash
# Disposable real-server integration run. No original server files are changed.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Go BalanceServer checkout; by default a sibling of this repository.
server_source="${BALANCE_SERVER_DIR:-${project_dir}/../BalanceServer}"
[[ -d "$server_source" ]] || { echo "BalanceServer source not found at $server_source (set BALANCE_SERVER_DIR)." >&2; exit 1; }
GO_BIN="${GO_BIN:-$(command -v go || true)}"
DART_BIN="${DART_BIN:-$(command -v dart || true)}"
if [[ -z "$GO_BIN" && -x /tmp/go/bin/go ]]; then GO_BIN=/tmp/go/bin/go; fi
if [[ -z "$DART_BIN" && -x /tmp/flutter/bin/dart ]]; then DART_BIN=/tmp/flutter/bin/dart; fi
[[ -n "$GO_BIN" && -x "$GO_BIN" ]] || { echo 'Go 1.25+ required (set GO_BIN).' >&2; exit 1; }
[[ -n "$DART_BIN" && -x "$DART_BIN" ]] || { echo 'Dart required (set DART_BIN).' >&2; exit 1; }
go_version="$("$GO_BIN" version)"
if [[ ! "$go_version" =~ go([0-9]+)\.([0-9]+) ]] || (( BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 25) )); then
  echo "Go 1.25+ required; found $go_version" >&2; exit 1
fi
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/balance-integration.XXXXXX")"
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf -- "$scratch_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -R -- "$server_source" "$scratch_dir/server"
mkdir -p "$scratch_dir/server/cmd/flutter-integration"
cat > "$scratch_dir/server/cmd/flutter-integration/main.go" <<'GO'
package main

import (
  "balance-server/internal/config"
  "balance-server/internal/database"
  "balance-server/internal/httpapi"
  "log"
  "log/slog"
  "net"
  "net/http"
  "os"
  "time"
)
func main() {
  cfg, err := config.Load(); if err != nil { log.Fatal(err) }
  db, err := database.Open(cfg.DatabasePath); if err != nil { log.Fatal(err) }; defer db.Close()
  listener, err := net.Listen("tcp", "127.0.0.1:0"); if err != nil { log.Fatal(err) }
  if err = os.WriteFile(os.Getenv("BALANCE_READY_FILE"), []byte("http://"+listener.Addr().String()), 0600); err != nil { log.Fatal(err) }
  server := &http.Server{Handler: httpapi.New(cfg, db, slog.Default()), ReadHeaderTimeout: 5*time.Second}
  log.Fatal(server.Serve(listener))
}
GO
(cd "$scratch_dir/server" && "$GO_BIN" build -o "$scratch_dir/server-bin" ./cmd/flutter-integration)
BALANCE_DB_PATH="$scratch_dir/balance.db" \
BALANCE_JWT_SECRET='integration-only-disposable-secret-2026-balance' \
BALANCE_ALLOW_REGISTRATION=true BALANCE_READY_FILE="$scratch_dir/ready" \
  "$scratch_dir/server-bin" >"$scratch_dir/server.log" 2>&1 &
server_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -s "$scratch_dir/ready" ]] && break
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$scratch_dir/server.log" >&2; exit 1; fi
  sleep 0.1
done
[[ -s "$scratch_dir/ready" ]] || { cat "$scratch_dir/server.log" >&2; echo 'Server startup timed out.' >&2; exit 1; }
server_url="$(cat "$scratch_dir/ready")"
cd "$project_dir"
"$DART_BIN" run tool/integration_sync.dart "$server_url"
