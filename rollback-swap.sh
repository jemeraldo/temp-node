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

# Load env if present
if [ -f "${BASE_DIR}/config.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${BASE_DIR}/config.env"
  set +a
fi

MAIN_HOME=${MAIN_HOME:-"${BASE_DIR}/.inference"}
MAIN_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

for arg in "$@"; do
  case "${arg}" in
    --help|-h)
      printf "Usage: %s\n" "$(basename "$0")"
      printf "  Rollback swap-state-from-temp changes by restoring .bak files\n"
      exit 0
      ;;
    *)
      log_error "Unknown argument: ${arg}"
      exit 1
      ;;
  esac
done

log_step "Validating inputs and environment"
if [ ! -d "${MAIN_HOME}" ]; then
  log_error "Main home not found: ${MAIN_HOME}"
  exit 1
fi

if [ ! -f "${MAIN_COMPOSE_FILE}" ]; then
  log_error "Main compose file not found: ${MAIN_COMPOSE_FILE}"
  exit 1
fi

log_step "Checking backup state"
if [ ! -e "${MAIN_HOME}/data.bak" ]; then
  log_error "Backup not found: ${MAIN_HOME}/data.bak"
  log_error "Nothing to rollback. Has swap-state-from-temp.sh been run?"
  exit 1
fi

if [ -e "${MAIN_HOME}/data.new" ] || [ -e "${MAIN_HOME}/wasm.new" ]; then
  log_error "Rollback state already exists (data.new/wasm.new)"
  log_error "Please remove these directories first if you want to retry rollback"
  exit 1
fi

run_compose() {
  local compose_file=$1
  shift

  if [ -f "${BASE_DIR}/config.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${BASE_DIR}/config.env"
    set +a
  fi

  docker compose -f "${compose_file}" "$@"
}

log_step "Stopping main node"
# Stop only node, keep tmkms running (same as swap-state-from-temp.sh)
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

log_step "Saving current state as .new (from temp swap)"
if [ -d "${MAIN_HOME}/data" ]; then
  log_info "mv ${MAIN_HOME}/data -> ${MAIN_HOME}/data.new"
  mv "${MAIN_HOME}/data" "${MAIN_HOME}/data.new"
fi
if [ -d "${MAIN_HOME}/wasm" ]; then
  log_info "mv ${MAIN_HOME}/wasm -> ${MAIN_HOME}/wasm.new"
  mv "${MAIN_HOME}/wasm" "${MAIN_HOME}/wasm.new"
fi

log_step "Restoring backup state"
if [ -d "${MAIN_HOME}/data.bak" ]; then
  log_info "mv ${MAIN_HOME}/data.bak -> ${MAIN_HOME}/data"
  mv "${MAIN_HOME}/data.bak" "${MAIN_HOME}/data"
else
  log_error "Backup data not found: ${MAIN_HOME}/data.bak"
  exit 1
fi

if [ -d "${MAIN_HOME}/wasm.bak" ]; then
  log_info "mv ${MAIN_HOME}/wasm.bak -> ${MAIN_HOME}/wasm"
  mv "${MAIN_HOME}/wasm.bak" "${MAIN_HOME}/wasm"
else
  log_warn "Backup wasm not found: ${MAIN_HOME}/wasm.bak (skipping)"
fi

log_step "Starting main node"
# Use docker start to restart the container with its original configuration
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

log_info "Rollback complete!"
log_info "Previous state (from swap) saved at: ${MAIN_HOME}/data.new and ${MAIN_HOME}/wasm.new"
log_info "Original state restored from: ${MAIN_HOME}/data.bak and ${MAIN_HOME}/wasm.bak"
log_warn "You can safely remove .new directories once you verify the rollback worked"
