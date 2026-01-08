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
  printf "\n[%s] [STEP] %s\n" "$(timestamp)" "$*"
}

if ! command -v curl >/dev/null 2>&1; then
  log_error "curl not found; cannot check PoC phase"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq not found; cannot check PoC phase"
  exit 1
fi

POC_CHECK_URL=${POC_CHECK_URL:-"http://127.0.0.1:8000/v1/epochs/latest"}
set +e
POC_JSON=$(curl -sf "${POC_CHECK_URL}" 2>/dev/null)
POC_RC=$?
set -e
if [ ${POC_RC} -ne 0 ]; then
  log_error "Failed to check PoC phase: ${POC_CHECK_URL}"
  exit 1
fi

# Strict contract check:
# - field must exist
# - field must be boolean
set +e
echo "${POC_JSON}" | jq -e 'has("is_confirmation_poc_active") and (.is_confirmation_poc_active | type == "boolean")' >/dev/null
POC_RC=$?
set -e
if [ ${POC_RC} -ne 0 ]; then
  log_error "Invalid PoC check response (missing/invalid is_confirmation_poc_active): ${POC_CHECK_URL}"
  exit 1
fi

POC_ACTIVE=$(echo "${POC_JSON}" | jq -r '.is_confirmation_poc_active')
if [ "${POC_ACTIVE}" = "true" ]; then
  log_error "PoC phase is active; aborting swap"
  exit 1
fi

# Load env if present (same pattern as deploy/join/config.env)
if [ -f "${BASE_DIR}/config.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${BASE_DIR}/config.env"
  set +a
fi

MAIN_HOME=${MAIN_HOME:-"${BASE_DIR}/.inference"}
TEMP_HOME=${TEMP_HOME:-"${BASE_DIR}/.inference-temp"}
MAIN_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
TEMP_COMPOSE_FILE="${BASE_DIR}/docker-compose.temp.yml"
TEMP_PROJECT_NAME=${TEMP_PROJECT_NAME:-"gonka-temp"}
TEMP_CONTAINER=${TEMP_CONTAINER:-"node-temp"}
COPY_TEMP=false

for arg in "$@"; do
  case "${arg}" in
    --copy-temp|copy-temp)
      COPY_TEMP=true
      ;;
    --help|-h)
      printf "Usage: %s [--copy-temp]\n" "$(basename "$0")"
      printf "  --copy-temp  Copy temp state (default is move)\n"
      exit 0
      ;;
    *)
      log_error "Unknown аргумент: ${arg}"
      exit 1
      ;;
  esac
done

log_step "Validating inputs and environment"
if [ ! -d "${MAIN_HOME}" ]; then
  log_error "Main home not found: ${MAIN_HOME}"
  exit 1
fi

if [ ! -d "${TEMP_HOME}" ]; then
  log_error "Temp home not found: ${TEMP_HOME}"
  exit 1
fi

if [ ! -f "${MAIN_COMPOSE_FILE}" ]; then
  log_error "Main compose file not found: ${MAIN_COMPOSE_FILE}"
  exit 1
fi

if [ ! -f "${TEMP_COMPOSE_FILE}" ]; then
  log_error "Temp compose file not found: ${TEMP_COMPOSE_FILE}"
  exit 1
fi

log_step "Checking backup state"
if [ -e "${MAIN_HOME}/data.bak" ] || [ -e "${MAIN_HOME}/wasm.bak" ]; then
  log_error "Backup already exists (data.bak/wasm.bak); aborting to avoid overwrite"
  exit 1
fi

run_compose() {
  local project=$1
  local compose_file=$2
  shift 2

  if [ -f "${BASE_DIR}/config.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${BASE_DIR}/config.env"
    set +a
  fi

  if [ -n "${project}" ]; then
    docker compose -p "${project}" -f "${compose_file}" "$@"
  else
    docker compose -f "${compose_file}" "$@"
  fi
}

log_step "Backing up main node state"
# Stop main and temp nodes before touching data
log_step "Stopping main and temp nodes before swap"
# Stop main api first (it mounts .inference)
log_info "Stopping main api"
docker stop api 2>/dev/null || true

# Verify api container is actually stopped (not just stopping)
log_info "Verifying main api has fully stopped..."
MAX_WAIT=15
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  API_STATE=$(docker inspect -f '{{.State.Status}}' api 2>/dev/null || echo "not_found")
  if [ "$API_STATE" = "exited" ] || [ "$API_STATE" = "created" ] || [ "$API_STATE" = "not_found" ]; then
    log_info "Main api container state: ${API_STATE}"
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "Main api did not stop within ${MAX_WAIT} seconds (state: ${API_STATE})"
    exit 1
  fi
  sleep 1
done

# Stop temp node (both node and tmkms)
log_info "Stopping temp node and temp tmkms"
docker stop "${TEMP_CONTAINER}" tmkms-temp 2>/dev/null || true

# Verify temp containers are actually stopped (not just stopping)
log_info "Verifying temp node has fully stopped..."
MAX_WAIT=15
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  TEMP_NODE_STATE=$(docker inspect -f '{{.State.Status}}' "${TEMP_CONTAINER}" 2>/dev/null || echo "not_found")
  if [ "$TEMP_NODE_STATE" = "exited" ] || [ "$TEMP_NODE_STATE" = "created" ] || [ "$TEMP_NODE_STATE" = "not_found" ]; then
    log_info "Temp node container state: ${TEMP_NODE_STATE}"
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "Temp node did not stop within ${MAX_WAIT} seconds (state: ${TEMP_NODE_STATE})"
    exit 1
  fi
  sleep 1
done

log_info "Temp node and tmkms stopped"

# Stop main node (only node, keep tmkms running)
docker stop node

# Verify container is actually stopped (not just stopping)
log_info "Verifying main node has fully stopped..."
MAX_WAIT=15
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  CONTAINER_STATE=$(docker inspect -f '{{.State.Status}}' node 2>/dev/null || echo "not_found")
  if [ "$CONTAINER_STATE" = "exited" ] || [ "$CONTAINER_STATE" = "created" ]; then
    log_info "Main node container state: ${CONTAINER_STATE}"
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "Main node did not stop within ${MAX_WAIT} seconds (state: ${CONTAINER_STATE})"
    exit 1
  fi
  sleep 1
done

# Backup main data/wasm then replace with temp state
if [ -d "${MAIN_HOME}/data" ]; then
  log_info "mv ${MAIN_HOME}/data -> ${MAIN_HOME}/data.bak"
  mv "${MAIN_HOME}/data" "${MAIN_HOME}/data.bak"
fi
if [ -d "${MAIN_HOME}/wasm" ]; then
  log_info "mv ${MAIN_HOME}/wasm -> ${MAIN_HOME}/wasm.bak"
  mv "${MAIN_HOME}/wasm" "${MAIN_HOME}/wasm.bak"
fi

log_step "Copying temp state into main home"
mkdir -p "${MAIN_HOME}/data"
for db_file in application.db blockstore.db state.db; do
  if [ ! -e "${TEMP_HOME}/data/${db_file}" ]; then
    log_error "Missing temp data file: ${TEMP_HOME}/data/${db_file}"
    exit 1
  fi
  if [ "${COPY_TEMP}" = "true" ]; then
    log_info "cp -a ${TEMP_HOME}/data/${db_file} -> ${MAIN_HOME}/data/"
    cp -a "${TEMP_HOME}/data/${db_file}" "${MAIN_HOME}/data/"
  else
    log_info "mv ${TEMP_HOME}/data/${db_file} -> ${MAIN_HOME}/data/"
    mv "${TEMP_HOME}/data/${db_file}" "${MAIN_HOME}/data/"
  fi
done

if [ -d "${TEMP_HOME}/wasm" ]; then
  if [ "${COPY_TEMP}" = "true" ]; then
    if command -v rsync >/dev/null 2>&1; then
      log_info "rsync -a ${TEMP_HOME}/wasm/ -> ${MAIN_HOME}/wasm/"
      rsync -a "${TEMP_HOME}/wasm/" "${MAIN_HOME}/wasm/"
    else
      log_info "cp -a ${TEMP_HOME}/wasm/. -> ${MAIN_HOME}/wasm/"
      cp -a "${TEMP_HOME}/wasm/." "${MAIN_HOME}/wasm/"
    fi
  else
    log_info "mv ${TEMP_HOME}/wasm -> ${MAIN_HOME}/wasm"
    mv "${TEMP_HOME}/wasm" "${MAIN_HOME}/wasm"
  fi
fi

# Restart main node (leave temp stopped)
log_step "Starting main node (temp remains stopped)"
# Use docker start to restart the container with its original configuration
# This works regardless of which compose files were used to create it
docker start node

# Verify node started successfully
log_info "Verifying main node has started..."
MAX_WAIT=15
WAIT_COUNT=0
NODE_STARTED=false
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  CONTAINER_STATE=$(docker inspect -f '{{.State.Status}}' node 2>/dev/null || echo "not_found")
  if [ "$CONTAINER_STATE" = "running" ]; then
    log_info "Main node container state: ${CONTAINER_STATE}"
    NODE_STARTED=true
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "Main node did not start within ${MAX_WAIT} seconds (state: ${CONTAINER_STATE})"
    log_error "Check logs: docker logs node"
    exit 1
  fi
  sleep 1
done

if [ "$NODE_STARTED" = "true" ]; then
  log_info "Main node started successfully"
else
  log_error "Failed to start main node"
  exit 1
fi

# Start main api (stopped before swap)
log_step "Starting main api"
docker start api 2>/dev/null || true

# Verify api started successfully (if it exists)
log_info "Verifying main api has started..."
MAX_WAIT=15
WAIT_COUNT=0
API_STARTED=false
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  API_STATE=$(docker inspect -f '{{.State.Status}}' api 2>/dev/null || echo "not_found")
  if [ "$API_STATE" = "running" ]; then
    log_info "Main api container state: ${API_STATE}"
    API_STARTED=true
    break
  fi
  if [ "$API_STATE" = "not_found" ]; then
    log_warn "Main api container not found; skipping start verification"
    API_STARTED=true
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "Main api did not start within ${MAX_WAIT} seconds (state: ${API_STATE})"
    log_error "Check logs: docker logs api"
    exit 1
  fi
  sleep 1
done

if [ "$API_STARTED" = "true" ]; then
  log_info "Main api started successfully"
else
  log_error "Failed to start main api"
  exit 1
fi

log_info "Temp node remains stopped: ${TEMP_PROJECT_NAME}"
log_info "Swap complete. Backup stored at: ${MAIN_HOME}/data.bak and ${MAIN_HOME}/wasm.bak"
