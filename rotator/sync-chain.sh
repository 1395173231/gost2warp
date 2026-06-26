#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

STATE_DIR="${STATE_DIR:-/var/lib/warp-rotator}"
LOCK_FILE="${STATE_DIR}/lock"
STATE_FILE="${STATE_DIR}/sync-chain.last_healthy"
DRAINING_TARGET_FILE="${STATE_DIR}/draining_target"
mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "sync-chain: rotate in progress, skip"
  exit 0
fi

GOST_API="${GOST_API:-http://gost:18080}"
GOST_CHAIN="${GOST_CHAIN:-warp-chain}"
GOST_HOP="${GOST_HOP:-warp-hop}"

WARP_CONTAINERS_CSV="${WARP_CONTAINERS:-warp1,warp2,warp3}"
IFS=',' read -r -a WARPS <<< "${WARP_CONTAINERS_CSV}"

warp_exists() {
  local target="$1"
  local w
  for w in "${WARPS[@]}"; do
    [[ "$w" == "$target" ]] && return 0
  done
  return 1
}

draining_target() {
  if [[ -f "$DRAINING_TARGET_FILE" ]]; then
    local target
    target="$(cat "$DRAINING_TARGET_FILE" 2>/dev/null || true)"
    if [[ -n "$target" ]] && warp_exists "$target"; then
      echo "$target"
    fi
  fi
}

api_ok() { curl -fsS "${GOST_API}/config" >/dev/null; }

docker_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo "missing"
}

get_current_chain_nodes_list() {
  local tmp_body tmp_code http_code raw_body result

  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"

  # 尝试直接获取单个 chain
  curl -s -o "$tmp_body" -w "%{http_code}" \
    "${GOST_API}/config/chains/${GOST_CHAIN}" > "$tmp_code" || true

  http_code="$(cat "$tmp_code" 2>/dev/null || true)"
  raw_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body" "$tmp_code"

  if [[ "$http_code" == "200" ]]; then
    result="$(echo "$raw_body" | jq -r '
      if .hops and (.hops|length>0) and .hops[0].nodes then
        (.hops[0].nodes | map(.name) | sort | join(","))
      else "" end
    ' 2>/dev/null || echo "")"
    echo "$result"
    return
  fi

  # fallback: 从 /config 获取完整配置并解析
  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"

  curl -s -o "$tmp_body" -w "%{http_code}" \
    "${GOST_API}/config" > "$tmp_code" || true

  http_code="$(cat "$tmp_code" 2>/dev/null || true)"
  raw_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body" "$tmp_code"

  if [[ "$http_code" != "200" ]]; then
    echo ""
    return
  fi

  result="$(echo "$raw_body" | jq -r --arg chain "$GOST_CHAIN" '
    (.chains // [])
    | map(select(.name == $chain))
    | if length == 0 then "" else
        (.[0].hops[0].nodes // [] | map(.name) | sort | join(","))
      end
  ' 2>/dev/null || echo "")"

  echo "$result"
}

build_chain_json() {
  local -a nodes=("$@")
  local nodes_json
  nodes_json="$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s 'sort')"

  jq -n \
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
}

put_chain() {
  local json="$1"
  local http_code

  # 尝试 PUT 更新
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${GOST_API}/config/chains/${GOST_CHAIN}" \
    -H 'Content-Type: application/json' \
    -d "$json")

  if [[ "$http_code" == "200" ]]; then
    return 0
  fi

  # PUT 失败则 POST 创建
  curl -fsS -X POST "${GOST_API}/config/chains" \
    -H 'Content-Type: application/json' \
    -d "$json" >/dev/null
}

# --- 主逻辑 ---

if ! api_ok; then
  log "WARN: gost API not reachable"
  exit 0
fi

healthy=()
draining="$(draining_target)"
for w in "${WARPS[@]}"; do
  if [[ -n "$draining" && "$w" == "$draining" ]]; then
    continue
  fi
  [[ "$(docker_health "$w")" == "healthy" ]] && healthy+=("$w")
done

if (( ${#healthy[@]} == 0 )); then
  log "WARN: no healthy warps"
  exit 0
fi

readarray -t healthy_sorted < <(printf '%s\n' "${healthy[@]}" | sort -u)
desired_list="$(printf '%s\n' "${healthy_sorted[@]}" | sort | paste -sd, -)"
current_list="$(get_current_chain_nodes_list)"

if [[ -n "$current_list" && "$current_list" == "$desired_list" ]]; then
  echo "$desired_list" > "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

put_chain "$(build_chain_json "${healthy_sorted[@]}")"
echo "$desired_list" > "$STATE_FILE" 2>/dev/null || true
if [[ -n "$draining" ]]; then
  log "sync-chain: applied, healthy warps = ${healthy_sorted[*]} (excluded draining $draining)"
else
  log "sync-chain: applied, healthy warps = ${healthy_sorted[*]}"
fi
