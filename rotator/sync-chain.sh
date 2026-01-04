#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

STATE_DIR="/var/lib/warp-rotator"
LOCK_FILE="${STATE_DIR}/lock"
STATE_FILE="${STATE_DIR}/sync-chain.last_healthy"
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

api_ok() { curl -fsS "${GOST_API}/config" >/dev/null; }

docker_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo "missing"
}

# 修复：确保返回排序后的逗号分隔列表
get_current_chain_nodes_list() {
  local raw json_data nodes_list
  
  raw="$(curl -fsS "${GOST_API}/config/chains/${GOST_CHAIN}" 2>/dev/null)" || {
    echo ""
    return
  }
  
  # 尝试解析，失败则返回空
  nodes_list="$(echo "$raw" | jq -r '
    if .hops then
      [.hops[0].nodes[]? | .name // empty] | sort | join(",")
    else
      ""
    end
  ' 2>/dev/null)" || nodes_list=""
  
  echo "$nodes_list"
}

build_chain_json() {
  local -a nodes=("$@")
  jq -n \
    --arg chain "$GOST_CHAIN" \
    --arg hop "$GOST_HOP" \
    --argjson nodes "$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s 'sort')" \
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
  curl -fsS -X PUT "${GOST_API}/config/chains/${GOST_CHAIN}" \
    -H 'Content-Type: application/json' \
    -d "$json" >/dev/null
}

if ! api_ok; then
  log "WARN: gost API not reachable: ${GOST_API}"
  exit 0
fi

healthy=()
for w in "${WARPS[@]}"; do
  [[ "$(docker_health "$w")" == "healthy" ]] && healthy+=("$w")
done

if (( ${#healthy[@]} == 0 )); then
  log "WARN: no healthy warps, do nothing"
  exit 0
fi

# 排序后生成逗号分隔列表
readarray -t healthy_sorted < <(printf '%s\n' "${healthy[@]}" | sort -u)
desired_list="$(printf '%s\n' "${healthy_sorted[@]}" | sort | paste -sd, -)"
current_list="$(get_current_chain_nodes_list)"

# 调试日志（可在稳定后删除）
# log "DEBUG: desired=[${desired_list}] current=[${current_list}]"

# 比较时都非空才跳过
if [[ -n "$current_list" && "$current_list" == "$desired_list" ]]; then
  echo "$desired_list" > "$STATE_FILE" 2>/dev/null || true
  log "sync-chain: unchanged (${desired_list}), skip"
  exit 0
fi

put_chain "$(build_chain_json "${healthy_sorted[@]}")"
echo "$desired_list" > "$STATE_FILE" 2>/dev/null || true
log "sync-chain: applied, healthy warps = ${healthy_sorted[*]}"
