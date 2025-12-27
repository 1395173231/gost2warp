#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

STATE_DIR="/var/lib/warp-rotator"
LOCK_FILE="${STATE_DIR}/lock"
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

put_chain() {
  local json="$1"
  curl -fsS -X PUT "${GOST_API}/config/chains/${GOST_CHAIN}" \
    -H 'Content-Type: application/json' \
    -d "$json" >/dev/null
}

if ! api_ok; then
  log "WARN: gost API not reachable"
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

put_chain "$(build_chain_json "${healthy[@]}")"
log "sync-chain: healthy warps = ${healthy[*]}"

