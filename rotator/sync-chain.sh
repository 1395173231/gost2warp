#!/usr/bin/env bash
set -euo pipefail

# =========================
# Logging
# =========================
# 默认较少日志；需要全量调试时：DEBUG=1 ./sync-chain.sh
DEBUG="${DEBUG:-0}"

log()  { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
dbg()  { [[ "$DEBUG" == "1" ]] && log "DEBUG: $*"; }
warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; }

# 仅在 DEBUG=1 时逐行打印大段文本（比如 JSON）
log_lines_dbg() {
  [[ "$DEBUG" != "1" ]] && return 0
  local ts; ts="$(date -Is)"
  while IFS= read -r line; do
    printf '[%s] DEBUG: %s\n' "$ts" "$line" >&2
  done
}

trap 'err "exit code $? at line $LINENO"' ERR

# =========================
# State / Lock
# =========================
STATE_DIR="/var/lib/warp-rotator"
LOCK_FILE="${STATE_DIR}/lock"
STATE_FILE="${STATE_DIR}/sync-chain.last_healthy"
mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "sync-chain: rotate in progress, skip"
  exit 0
fi

# =========================
# Config
# =========================
GOST_API="${GOST_API:-http://gost:18080}"
GOST_CHAIN="${GOST_CHAIN:-warp-chain}"
GOST_HOP="${GOST_HOP:-warp-hop}"

WARP_CONTAINERS_CSV="${WARP_CONTAINERS:-warp1,warp2,warp3}"
IFS=',' read -r -a WARPS <<< "${WARP_CONTAINERS_CSV}"

dbg "ENV: GOST_API=$GOST_API"
dbg "ENV: GOST_CHAIN=$GOST_CHAIN"
dbg "ENV: GOST_HOP=$GOST_HOP"
dbg "ENV: WARPS=${WARPS[*]}"

api_ok() { curl -fsS "${GOST_API}/config" >/dev/null; }

docker_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo "missing"
}

# =========================
# Read current chain nodes
# =========================
# Primary endpoint might 404 in your env:
#   GET /config/chains/<name> => 404
# So fallback to GET /config and find it in .chains[]
get_current_chain_nodes_list() {
  local tmp_body tmp_code http_code raw_body result

  dbg "GET_CHAIN: primary GET /config/chains/${GOST_CHAIN}"
  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"
  curl -s -o "$tmp_body" -w "%{http_code}" \
    "${GOST_API}/config/chains/${GOST_CHAIN}" > "$tmp_code" || true
  http_code="$(cat "$tmp_code" 2>/dev/null || true)"
  raw_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body" "$tmp_code"

  if [[ "$http_code" == "200" ]]; then
    dbg "GET_CHAIN: primary 200, parsing"
    dbg "GET_CHAIN: primary body:"
    printf '%s\n' "$raw_body" | log_lines_dbg

    result="$(echo "$raw_body" | jq -r '
      if .hops and (.hops|length>0) and .hops[0].nodes then
        (.hops[0].nodes | map(.name) | sort | join(","))
      else "" end
    ' 2>/dev/null || echo "")"

    dbg "GET_CHAIN: primary parsed=[$result]"
    echo "$result"
    return
  fi

  dbg "GET_CHAIN: primary unusable (http_code=$http_code), fallback GET /config"
  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"
  curl -s -o "$tmp_body" -w "%{http_code}" \
    "${GOST_API}/config" > "$tmp_code" || true
  http_code="$(cat "$tmp_code" 2>/dev/null || true)"
  raw_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body" "$tmp_code"

  if [[ "$http_code" != "200" ]]; then
    warn "GET_CHAIN: fallback /config failed http_code=$http_code"
    dbg "GET_CHAIN: fallback body:"
    printf '%s\n' "$raw_body" | log_lines_dbg
    echo ""
    return
  fi

  dbg "GET_CHAIN: fallback 200, parsing chain=$GOST_CHAIN"
  dbg "GET_CHAIN: fallback body:"
  printf '%s\n' "$raw_body" | log_lines_dbg

  result="$(echo "$raw_body" | jq -r --arg chain "$GOST_CHAIN" '
    (.chains // [])
    | map(select(.name == $chain))
    | if length == 0 then "" else
        (.[0].hops[0].nodes // [] | map(.name) | sort | join(","))
      end
  ' 2>/dev/null || echo "")"

  dbg "GET_CHAIN: fallback parsed=[$result]"
  echo "$result"
}

# =========================
# Build chain JSON
# =========================
build_chain_json() {
  local -a nodes=("$@")
  local nodes_json json

  nodes_json="$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s 'sort')"
  dbg "BUILD_JSON: nodes_json=$nodes_json"

  json="$(jq -n \
    --arg chain "$GOST_CHAIN" \
    --arg hop "$GOST_HOP" \
    --argjson nodes "$nodes_json" \
    '{
      name: $chain,
      selector: {strategy:"rand", maxFails:1, failTimeout:"30s"},
      hops: [{
        name: $hop,
        nodes: ($nodes | map({
          name: .,
          addr: (. + ":1080"),
          connector: {type:"socks5"},
          dialer: {type:"tcp"}
        }))
      }]
    }'
  )"

  dbg "BUILD_JSON: bytes=$(printf '%s' "$json" | wc -c)"
  printf '%s' "$json"
}

# =========================
# Apply chain
# =========================
put_chain() {
  local json="$1"
  local tmp_body tmp_code http_code resp

  # PUT update
  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"
  curl -s -o "$tmp_body" -w "%{http_code}" \
    -X PUT "${GOST_API}/config/chains/${GOST_CHAIN}" \
    -H 'Content-Type: application/json' \
    -d "$json" > "$tmp_code" || true
  http_code="$(cat "$tmp_code" 2>/dev/null || true)"
  resp="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body" "$tmp_code"

  if [[ "$http_code" == "200" ]]; then
    dbg "PUT_CHAIN: PUT success"
    dbg "PUT_CHAIN: PUT resp: $resp"
    return 0
  fi

  # Only warn when it fails, and show response in DEBUG
  warn "PUT_CHAIN: PUT failed http_code=$http_code, trying POST create"
  dbg "PUT_CHAIN: PUT resp: $resp"

  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"
  curl -s -o "$tmp_body" -w "%{http_code}" \
    -X POST "${GOST_API}/config/chains" \
    -H 'Content-Type: application/json' \
    -d "$json" > "$tmp_code" || true
  http_code="$(cat "$tmp_code" 2>/dev/null || true)"
  resp="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body" "$tmp_code"

  if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
    err "PUT_CHAIN: POST failed http_code=$http_code resp=$resp"
    return 1
  fi

  dbg "PUT_CHAIN: POST success resp=$resp"
}

# =========================
# Main
# =========================
if ! api_ok; then
  warn "gost API not reachable: ${GOST_API}"
  exit 0
fi

healthy=()
for w in "${WARPS[@]}"; do
  status="$(docker_health "$w")"
  dbg "HEALTH: $w => $status"
  [[ "$status" == "healthy" ]] && healthy+=("$w")
done

if (( ${#healthy[@]} == 0 )); then
  warn "no healthy warps, do nothing"
  exit 0
fi

readarray -t healthy_sorted < <(printf '%s\n' "${healthy[@]}" | sort -u)
desired_list="$(printf '%s\n' "${healthy_sorted[@]}" | sort | paste -sd, -)"

current_list="$(get_current_chain_nodes_list)"

dbg "COMPARE: desired=[$desired_list] current=[$current_list]"

if [[ -n "$current_list" && "$current_list" == "$desired_list" ]]; then
  echo "$desired_list" > "$STATE_FILE" 2>/dev/null || true
  log "sync-chain: unchanged (${desired_list}), skip"
  exit 0
fi

json_payload="$(build_chain_json "${healthy_sorted[@]}")"
put_chain "$json_payload"

echo "$desired_list" > "$STATE_FILE" 2>/dev/null || true
log "sync-chain: applied, healthy warps = ${healthy_sorted[*]}"
