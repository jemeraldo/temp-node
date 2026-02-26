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
MAIN_CONTAINER=${MAIN_CONTAINER:-"node"}
TEMP_CONTAINER=${TEMP_CONTAINER:-"node-temp"}
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

if ! command -v docker >/dev/null 2>&1; then
  log_error "docker not found"
  exit 1
fi

get_status() {
  local container_name=$1
  python3 - "$container_name" 2>/dev/null <<'PY'
import json
import subprocess
import sys

container=sys.argv[1]

try:
    result=subprocess.run(
        ["docker", "exec", container, "inferenced", "status"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
except Exception:
    sys.exit(1)

raw=result.stdout.strip()
if not raw:
    sys.exit(1)

try:
    data=json.loads(raw)
except Exception:
    sys.exit(1)

try:
    if isinstance(data, dict) and "result" in data and isinstance(data["result"], dict) and "sync_info" in data["result"]:
        info=data["result"]["sync_info"]
    elif isinstance(data, dict) and "SyncInfo" in data:
        info=data["SyncInfo"]
    elif isinstance(data, dict) and "sync_info" in data:
        info=data["sync_info"]
    else:
        sys.exit(1)

    print(info["latest_block_height"], str(info["catching_up"]).lower())
except Exception:
    sys.exit(1)
PY
}

log_step "Waiting for temp node height to get close to main (via docker exec)"
while true; do
  if ! read -r TEMP_HEIGHT TEMP_CATCHUP < <(get_status "${TEMP_CONTAINER}"); then
    log_error "Failed to get temp node status via docker from container: ${TEMP_CONTAINER}"
    exit 1
  fi
  if ! read -r MAIN_HEIGHT MAIN_CATCHUP < <(get_status "${MAIN_CONTAINER}"); then
    log_error "Failed to get main node status via docker from container: ${MAIN_CONTAINER}"
    exit 1
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
