#!/usr/bin/env bash
# Disposable real-server integration run. No original server files are changed.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Rust BalanceServer checkout; by default a sibling of this repository.
server_source="${BALANCE_SERVER_DIR:-${project_dir}/../BalanceServer}"
[[ -f "$server_source/Cargo.toml" ]] || { echo "BalanceServer source not found at $server_source (set BALANCE_SERVER_DIR)." >&2; exit 1; }
CARGO_BIN="${CARGO_BIN:-$(command -v cargo || true)}"
DART_BIN="${DART_BIN:-$(command -v dart || true)}"
[[ -n "$CARGO_BIN" && -x "$CARGO_BIN" ]] || { echo 'Rust/cargo 1.90+ required (set CARGO_BIN).' >&2; exit 1; }
[[ -n "$DART_BIN" && -x "$DART_BIN" ]] || { echo 'Dart required (set DART_BIN).' >&2; exit 1; }
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/balance-integration.XXXXXX")"
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf -- "$scratch_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Build in a copy so the checkout's target/ and data/ stay untouched.
cp -R -- "$server_source" "$scratch_dir/server"
rm -rf -- "$scratch_dir/server/data"
(cd "$scratch_dir/server" && "$CARGO_BIN" build --locked --release --quiet)
binary="$(find "$scratch_dir/server/target/release" -maxdepth 1 -type f -perm -u+x -name 'balance*' | head -1)"
[[ -x "$binary" ]] || { echo 'Server binary not found after build.' >&2; exit 1; }
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
BALANCE_ADDR="127.0.0.1:$port" \
BALANCE_DB_PATH="$scratch_dir/balance.db" \
BALANCE_ATTACHMENTS_DIR="$scratch_dir/attachments" \
BALANCE_JWT_SECRET='integration-only-disposable-secret-2026-balance' \
BALANCE_ALLOW_REGISTRATION=true \
  "$binary" >"$scratch_dir/server.log" 2>&1 &
server_pid=$!
server_url="http://127.0.0.1:$port"
for ((attempt=0; attempt<100; attempt++)); do
  curl -fsS "$server_url/v1/capabilities" >/dev/null 2>&1 && break
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$scratch_dir/server.log" >&2; exit 1; fi
  sleep 0.1
done
curl -fsS "$server_url/v1/capabilities" >/dev/null || { cat "$scratch_dir/server.log" >&2; echo 'Server startup timed out.' >&2; exit 1; }
cd "$project_dir"
"$DART_BIN" run tool/integration_sync.dart "$server_url"
"$DART_BIN" run tool/integration_v2.dart "$server_url"
