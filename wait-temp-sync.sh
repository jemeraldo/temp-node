#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
if [ -d "${SCRIPT_DIR}/.inference" ]; then
  BASE_DIR="${SCRIPT_DIR}"
fi

timestamp() {
  date -u "+%Y-%m-%d %H:%M:%S UTC"
}

log_info() {
  printf "[%s] [INFO] %s\n" "$(timestamp)" "$*"
}

log_warn() {
  printf "[%s] [WARN] %s\n" "$(timestamp)" "$*"
}

log_error() {
  printf "[%s] [ERROR] %s\n" "$(timestamp)" "$*"
}

log_step() {
  printf "[%s] [STEP] %s\n" "$(timestamp)" "$*"
}

# Load env if present (same pattern as deploy/join/config.env)
if [ -f "${BASE_DIR}/config.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${BASE_DIR}/config.env"
  set +a
fi

MAIN_HOME=${MAIN_HOME:-"${BASE_DIR}/.inference"}
TEMP_HOME=${TEMP_HOME:-"${BASE_DIR}/.inference-temp"}
MAIN_RPC_PORT=${MAIN_RPC_PORT:-26657}
TEMP_RPC_PORT=${TEMP_RPC_PORT:-26667}
HEIGHT_DIFF_THRESHOLD=${HEIGHT_DIFF_THRESHOLD:-5}
POLL_INTERVAL=${POLL_INTERVAL:-5}

log_step "Validating inputs and environment"
if [ ! -d "${MAIN_HOME}" ]; then
  log_error "Main home not found: ${MAIN_HOME}"
  exit 1
fi

if [ ! -d "${TEMP_HOME}" ]; then
  log_error "Temp home not found: ${TEMP_HOME}"
  exit 1
fi

get_status() {
  local rpc_port=$1
  python3 - "$rpc_port" 2>/dev/null <<'PY'
import json,sys,urllib.request
port=sys.argv[1]
url=f"http://127.0.0.1:{port}/status"
try:
    with urllib.request.urlopen(url, timeout=3) as f:
        data=json.load(f)
    info=data["result"]["sync_info"]
    print(info["latest_block_height"], info["catching_up"])
except Exception as exc:
    sys.exit(1)
PY
}

log_step "Waiting for temp node height to get close to main"
while true; do
  if ! read -r TEMP_HEIGHT TEMP_CATCHUP < <(get_status "${TEMP_RPC_PORT}" || true); then
    TEMP_HEIGHT=""
    TEMP_CATCHUP=""
  fi
  if ! read -r MAIN_HEIGHT MAIN_CATCHUP < <(get_status "${MAIN_RPC_PORT}" || true); then
    MAIN_HEIGHT=""
    MAIN_CATCHUP=""
  fi
  if [ -z "${TEMP_HEIGHT:-}" ] || [ -z "${MAIN_HEIGHT:-}" ]; then
    log_warn "RPC not ready; retrying in 5 seconds"
    sleep 5
    continue
  fi

  diff=$((MAIN_HEIGHT - TEMP_HEIGHT))
  if [ "${diff}" -lt 0 ]; then
    diff=$((diff * -1))
  fi

  log_info "Temp height=${TEMP_HEIGHT} catching_up=${TEMP_CATCHUP} | Main height=${MAIN_HEIGHT} catching_up=${MAIN_CATCHUP} | diff=${diff}"

  if [ "${diff}" -lt "${HEIGHT_DIFF_THRESHOLD}" ]; then
    log_info "Height diff < ${HEIGHT_DIFF_THRESHOLD}. Done."
    exit 0
  fi

  sleep "${POLL_INTERVAL}"
done
