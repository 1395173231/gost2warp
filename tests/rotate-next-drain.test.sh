#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$ROOT_DIR/rotator/rotate-next.sh"

run_case() {
  local name="$1"
  local conn_count="$2"
  local expect_restart="$3"
  local exec_status="${4:-0}"
  local expect_draining="${5:-}"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/secrets"
  printf 'user pass\n' > "$tmp/secrets/gost_socks_auth"

  cat > "$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${TEST_LOG:?}"
conn_count="${TEST_CONN_COUNT:?}"
exec_status="${TEST_EXEC_STATUS:?}"

case "${1:-}" in
  inspect)
    if [[ "${*: -1}" == "gost" ]]; then
      printf 'healthy\n'
      exit 0
    fi

    if [[ "$*" == *'IPAddress'* ]]; then
      printf '172.20.0.2\n'
      exit 0
    fi

    printf 'healthy\n'
    ;;
  exec)
    if [[ "$exec_status" != "0" ]]; then
      exit "$exec_status"
    fi
    printf '%s\n' "$conn_count"
    ;;
  restart)
    printf 'restart %s\n' "${2:-}" >> "$log_file"
    ;;
  *)
    printf 'unexpected docker command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$tmp/bin/flock" "$tmp/bin/sleep" "$tmp/bin/curl" "$tmp/bin/docker"

  local log_file="$tmp/docker.log"
  local output="$tmp/output.log"

  PATH="$tmp/bin:$PATH" \
  TEST_LOG="$log_file" \
  TEST_CONN_COUNT="$conn_count" \
  TEST_EXEC_STATUS="$exec_status" \
  STATE_DIR="$tmp/state" \
  GOST_API="http://gost:18080" \
  GOST_CHAIN="warp-chain" \
  GOST_HOP="warp-hop" \
  GOST_CONTAINER="gost" \
  WARP_CONTAINERS="warp1,warp2,warp3" \
  MIN_UPSTREAMS="2" \
  DRAIN_GRACE="0" \
  DRAIN_MAX="1" \
  CHECK_INTERVAL="1" \
  RESTART_TIMEOUT="1" \
  GOST_SOCKS_AUTH_FILE="$tmp/secrets/gost_socks_auth" \
  "$SCRIPT_UNDER_TEST" > "$output" 2>&1 || {
    cat "$output" >&2
    return 1
  }

  local restarted=0
  if [[ -s "$log_file" ]]; then
    restarted=1
  fi

  if [[ "$expect_restart" == "yes" && "$restarted" -ne 1 ]]; then
    printf 'FAIL %s: expected restart, got none\n' "$name" >&2
    cat "$output" >&2
    return 1
  fi

  if [[ "$expect_restart" == "no" && "$restarted" -ne 0 ]]; then
    printf 'FAIL %s: expected no restart, got:\n' "$name" >&2
    cat "$log_file" >&2
    cat "$output" >&2
    return 1
  fi

  if [[ "$expect_draining" == "present" && "$(cat "$tmp/state/draining_target" 2>/dev/null || true)" != "warp1" ]]; then
    printf 'FAIL %s: expected draining target to remain warp1\n' "$name" >&2
    cat "$output" >&2
    return 1
  fi

  if [[ "$expect_draining" == "absent" && -e "$tmp/state/draining_target" ]]; then
    printf 'FAIL %s: expected draining target to be cleared\n' "$name" >&2
    cat "$output" >&2
    return 1
  fi

  printf 'PASS %s\n' "$name"
}

run_case "skips restart while target still has established connections" "3" "no" "0" "present"
run_case "skips restart when connection count cannot be confirmed" "0" "no" "1" "present"
run_case "restarts only after target has no established connections" "0" "yes" "0" "absent"

run_sync_chain_case() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin" "$tmp/state"
  printf 'warp1\n' > "$tmp/state/draining_target"

  cat > "$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  inspect)
    printf 'healthy\n'
    ;;
  *)
    printf 'unexpected docker command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

data=""
output_file=""
write_code=""
while (($#)); do
  case "$1" in
    -d)
      data="$2"
      shift 2
      ;;
    -o)
      output_file="$2"
      shift 2
      ;;
    -w)
      write_code="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$data" ]]; then
  printf '%s\n' "$data" >> "${TEST_CHAIN_LOG:?}"
fi

if [[ -n "$output_file" && "$output_file" != "/dev/null" ]]; then
  printf '{}\n' > "$output_file"
fi

if [[ -n "$write_code" ]]; then
  printf '404'
fi
EOF

  chmod +x "$tmp/bin/flock" "$tmp/bin/docker" "$tmp/bin/curl"

  local chain_log="$tmp/chain.log"
  local output="$tmp/output.log"

  PATH="$tmp/bin:$PATH" \
  STATE_DIR="$tmp/state" \
  TEST_CHAIN_LOG="$chain_log" \
  GOST_API="http://gost:18080" \
  GOST_CHAIN="warp-chain" \
  GOST_HOP="warp-hop" \
  WARP_CONTAINERS="warp1,warp2,warp3" \
  "$ROOT_DIR/rotator/sync-chain.sh" > "$output" 2>&1 || {
    cat "$output" >&2
    return 1
  }

  if grep -Eq '"name"[[:space:]]*:[[:space:]]*"warp1"' "$chain_log"; then
    printf 'FAIL sync-chain excludes draining target: warp1 was added back\n' >&2
    cat "$chain_log" >&2
    cat "$output" >&2
    return 1
  fi

  if ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"warp2"' "$chain_log" || ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"warp3"' "$chain_log"; then
    printf 'FAIL sync-chain excludes draining target: expected warp2 and warp3 to remain\n' >&2
    cat "$chain_log" >&2
    cat "$output" >&2
    return 1
  fi

  printf 'PASS sync-chain excludes draining target\n'
}

run_sync_chain_case
