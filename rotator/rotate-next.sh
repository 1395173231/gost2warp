#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

GOST_API="${GOST_API:-http://gost:18080}"
GOST_CHAIN="${GOST_CHAIN:-warp-chain}"
GOST_HOP="${GOST_HOP:-warp-hop}"
GOST_CONTAINER="${GOST_CONTAINER:-gost}"

WARP_CONTAINERS_CSV="${WARP_CONTAINERS:-warp1,warp2,warp3}"
IFS=',' read -r -a WARPS <<< "${WARP_CONTAINERS_CSV}"

MIN_UPSTREAMS="${MIN_UPSTREAMS:-2}"
DRAIN_GRACE="${DRAIN_GRACE:-60}"
DRAIN_MAX="${DRAIN_MAX:-600}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-240}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
TEST_URL="${TEST_URL:-https://dash.cloudflare.com/cdn-cgi/trace}"

STATE_DIR="/var/lib/warp-rotator"
LOCK_FILE="${STATE_DIR}/lock"
STATE_FILE="${STATE_DIR}/last_index"

mkdir -p "$STATE_DIR"

# 单实例锁
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another rotate is running, exit"
  exit 0
fi

api_ok() {
  curl -fsS "${GOST_API}/config" >/dev/null
}

docker_health() {
  local c="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo "missing"
}

count_healthy_warps() {
  local n=0
  for w in "${WARPS[@]}"; do
    [[ "$(docker_health "$w")" == "healthy" ]] && n=$((n+1))
  done
  echo "$n"
}

# 将 IPv4 转为 /proc/net/tcp 使用的 little-endian HEX（大写）
ip_to_hex_le() {
  local ip="$1"
  awk -F. '{printf "%02X%02X%02X%02X", $4,$3,$2,$1}' <<<"$ip"
}

# 统计 gost 容器到某个 warp:1080 的 ESTABLISHED 数（尽量不依赖 ss/netstat）
conn_count_established() {
  local warp="$1"
  local warp_ip
  warp_ip="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$warp")"
  if [[ -z "$warp_ip" ]]; then
    echo 0
    return
  fi
  local iphex porthex
  iphex="$(ip_to_hex_le "$warp_ip")"
  porthex="0438" # 1080 -> 0x0438

  docker exec "$GOST_CONTAINER" sh -c \
    "awk 'NR>1{
       split(\$3,a,\":\");
       if (toupper(a[1])==\"$iphex\" && toupper(a[2])==\"$porthex\" && \$4==\"01\") c++
     } END{print c+0}' /proc/net/tcp" 2>/dev/null || echo 0
}

# 生成 chain JSON（只包含指定 warps）
build_chain_json() {
  local -a nodes=("$@")
  jq -n \
    --arg chain "$GOST_CHAIN" \
    --arg hop "$GOST_HOP" \
    '{
      name: $chain,
      selector: {strategy:"rand", maxFails:1, failTimeout:"30s"},
      hops: [{
        name: $hop,
        nodes: []
      }]
    } | .hops[0].nodes = []' \
  | jq --argjson nodes "$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s .)" \
       '.hops[0].nodes = ($nodes | map({
          name: .,
          addr: (. + ":1080"),
          connector: {type:"socks5"},
          dialer: {type:"tcp"}
        }))'
}

# PUT 更新 chain（动态配置立即生效） ([gost.run](https://gost.run/en/tutorials/api/config/))
put_chain() {
  local json="$1"
  curl -fsS -X PUT "${GOST_API}/config/chains/${GOST_CHAIN}" \
    -H 'Content-Type: application/json' \
    -d "$json" >/dev/null
}

proxy_test() {
  local auth_file="${GOST_SOCKS_AUTH_FILE:-/run/secrets/gost_socks_auth}"
  local user pass

  if [[ ! -r "$auth_file" ]]; then
    log "WARN: auth file not readable: $auth_file"
    return 1
  fi

  # 取第一行 "user pass"
  read -r user pass < "$auth_file"

  curl -fsS --max-time 15 --retry 2 \
    --proxy "socks5h://gost:1080" \
    --proxy-user "${user}:${pass}" \
    "$TEST_URL" >/dev/null
}

choose_next_warp() {
  local last=-1
  if [[ -f "$STATE_FILE" ]]; then
    last="$(cat "$STATE_FILE" || echo -1)"
  fi
  local next=$(( (last + 1) % ${#WARPS[@]} ))
  echo "$next"
}

rotate_one() {
  local target="$1"

  log "=== rotate start: $target ==="

  if ! api_ok; then
    log "ERROR: gost API not reachable: ${GOST_API}"
    return 1
  fi

  local healthy_total
  healthy_total="$(count_healthy_warps)"
  if (( healthy_total < MIN_UPSTREAMS )); then
    log "SKIP: healthy warps ($healthy_total) < MIN_UPSTREAMS ($MIN_UPSTREAMS)"
    return 0
  fi

  if [[ "$(docker_health "$target")" != "healthy" ]]; then
    log "WARN: target $target not healthy now, will not rotate it (sync-chain will handle)"
    return 0
  fi

  # 1) 摘除 target：只保留其他 healthy warp
  local -a remain=()
  for w in "${WARPS[@]}"; do
    if [[ "$w" != "$target" && "$(docker_health "$w")" == "healthy" ]]; then
      remain+=("$w")
    fi
  done

  if (( ${#remain[@]} < MIN_UPSTREAMS )); then
    log "SKIP: removing $target would leave healthy upstreams=${#remain[@]} < MIN_UPSTREAMS=$MIN_UPSTREAMS"
    return 0
  fi

  log "drain: remove $target from chain, remain: ${remain[*]}"
  put_chain "$(build_chain_json "${remain[@]}")"

  # 2) 立即做一次代理测试（确保更新后仍可用）
  proxy_test && log "proxy test after remove OK" || log "WARN: proxy test after remove FAILED"

  # 3) 等待存量连接自然结束
  log "drain: grace sleep ${DRAIN_GRACE}s"
  sleep "$DRAIN_GRACE"

  local waited=0
  while (( waited < DRAIN_MAX )); do
    local c
    c="$(conn_count_established "$target")"
    log "drain: $target established connections = $c"
    if (( c == 0 )); then
      break
    fi
    sleep "$CHECK_INTERVAL"
    waited=$((waited + CHECK_INTERVAL))
  done

  if (( waited >= DRAIN_MAX )); then
    log "drain: timeout (${DRAIN_MAX}s), proceed restart anyway"
  else
    log "drain: connections drained in ${waited}s"
  fi

  # 4) 重启 target
  log "restart: docker restart $target"
  docker restart "$target" >/dev/null

  # 5) 等待 target healthy
  log "wait: $target becomes healthy (timeout ${RESTART_TIMEOUT}s)"
  local t=0
  while (( t < RESTART_TIMEOUT )); do
    if [[ "$(docker_health "$target")" == "healthy" ]]; then
      log "wait: $target healthy"
      break
    fi
    sleep "$CHECK_INTERVAL"
    t=$((t + CHECK_INTERVAL))
  done

  if [[ "$(docker_health "$target")" != "healthy" ]]; then
    log "ERROR: $target not healthy after restart, keep it out of chain"
    proxy_test && log "proxy test with remaining OK" || log "WARN: proxy test with remaining FAILED"
    return 1
  fi

  # 6) 加回：收集所有 healthy warp
  local -a all=()
  for w in "${WARPS[@]}"; do
    [[ "$(docker_health "$w")" == "healthy" ]] && all+=("$w")
  done

  log "restore: add $target back, healthy set: ${all[*]}"
  put_chain "$(build_chain_json "${all[@]}")"

  proxy_test && log "proxy test after restore OK" || log "WARN: proxy test after restore FAILED"

  log "=== rotate done: $target ==="
}

idx="$(choose_next_warp)"
target="${WARPS[$idx]}"

# 记录 index（即使失败也推进，避免一直卡在同一个）
echo "$idx" > "$STATE_FILE"

rotate_one "$target"

