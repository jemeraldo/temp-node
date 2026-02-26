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

log_info "Using base directory: ${BASE_DIR}"

NO_RESTORE=false
for arg in "$@"; do
  case "${arg}" in
    --from-scratch)
      NO_RESTORE=true
      ;;
    --no-restore)
      # Legacy flag for backward compatibility
      NO_RESTORE=true
      ;;
    --help|-h)
      printf "Usage: %s [--from-scratch]\n" "$(basename "$0")"
      printf "  --from-scratch  Create empty temp home and sync from zero\n"
      exit 0
      ;;
    *)
      log_error "Unknown argument: ${arg}"
      exit 1
      ;;
  esac
done

# Load env if present (same pattern as deploy/join/config.env)
if [ -f "${BASE_DIR}/config.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${BASE_DIR}/config.env"
  set +a
fi

DEFAULT_COMPOSE="${BASE_DIR}/docker-compose.yml"
if [ -f "$(pwd)/docker-compose.yml" ]; then
  DEFAULT_COMPOSE="$(pwd)/docker-compose.yml"
fi
COMPOSE_FILE=${COMPOSE_FILE:-"${DEFAULT_COMPOSE}"}
IMAGE=${IMAGE:-""}
if [ ! -f "${COMPOSE_FILE}" ]; then
  log_error "docker-compose.yml not found: ${COMPOSE_FILE}"
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  log_error "yq not found; cannot reliably parse ${COMPOSE_FILE}"
  log_error "Install: sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq"
  exit 1
fi
YQ_VERSION=$(yq --version 2>&1 || echo "unknown")
log_info "Using yq version: ${YQ_VERSION}"
if [ -z "${IMAGE}" ]; then
  IMAGE=$(yq e '.services.node.image' - < "${COMPOSE_FILE}")
  if [ -z "${IMAGE}" ] || [ "${IMAGE}" = "null" ]; then
    log_error "Could not extract node image from ${COMPOSE_FILE}"
    exit 1
  fi
  log_info "Using node image from compose: ${IMAGE}"
else
  log_info "Using node image from environment: ${IMAGE}"
fi
MAIN_HOME=${MAIN_HOME:-"${BASE_DIR}/.inference"}
TEMP_HOME=${TEMP_HOME:-"${BASE_DIR}/.inference-temp"}
GENESIS_PATH=${GENESIS_PATH:-"${BASE_DIR}/../../genesis/genesis.json"}
MAIN_CONTAINER=${MAIN_CONTAINER:-"node"}
TEMP_CONTAINER=${TEMP_CONTAINER:-"node-temp"}
TEMP_TMKMS_HOME=${TEMP_TMKMS_HOME:-"${BASE_DIR}/.tmkms-temp"}
TEMP_COMPOSE_FILE=${TEMP_COMPOSE_FILE:-"${BASE_DIR}/docker-compose.temp.yml"}
TEMP_PROJECT_NAME=${TEMP_PROJECT_NAME:-"gonka-temp"}
MAIN_DOCKER_NETWORK=${MAIN_DOCKER_NETWORK:-$(docker inspect "${MAIN_CONTAINER}" --format '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null | awk 'NF { print; exit }')}
MAIN_CONTAINER_IP=${MAIN_CONTAINER_IP:-$(docker inspect "${MAIN_CONTAINER}" --format "{{ (index .NetworkSettings.Networks \"${MAIN_DOCKER_NETWORK}\").IPAddress }}" 2>/dev/null)}

# Use main node RPC from internal docker network (no external 26657 required)
TEMP_SEED_NODE_RPC_URL=${TEMP_SEED_NODE_RPC_URL:-"http://${MAIN_CONTAINER_IP}:26657"}
TEMP_SEED_NODE_P2P_URL=${TEMP_SEED_NODE_P2P_URL:-"tcp://${MAIN_CONTAINER_IP}:26656"}
TEMP_RPC_SERVER_URL_1=${TEMP_RPC_SERVER_URL_1:-"${TEMP_SEED_NODE_RPC_URL}"}
TEMP_RPC_SERVER_URL_2=${TEMP_RPC_SERVER_URL_2:-"${TEMP_SEED_NODE_RPC_URL}"}

# Ports for temp node to avoid conflicts with the main node
TEMP_P2P_PORT=${TEMP_P2P_PORT:-15001}
TEMP_RPC_PORT=${TEMP_RPC_PORT:-26667}

# Use a distinct external address to avoid confusing peers
TEMP_P2P_EXTERNAL_ADDRESS=${TEMP_P2P_EXTERNAL_ADDRESS:-"127.0.0.1:${TEMP_P2P_PORT}"}

SNAPSHOT_FORMAT=${SNAPSHOT_FORMAT:-3}
SNAPSHOT_HEIGHT=${SNAPSHOT_HEIGHT:-""}
SKIP_SNAPSHOT_RESTORE=${SKIP_SNAPSHOT_RESTORE:-false}
NODE_STOPPED=false
restart_main_node() {
  if [ "${NODE_STOPPED}" = "true" ]; then
    log_step "Starting main node after data copy"
    if docker start node; then
      NODE_STOPPED=false
    else
      log_warn "Failed to start main node; check docker logs"
    fi
  fi
}
trap restart_main_node EXIT

if [ -e "${TEMP_HOME}" ]; then
  log_error "Temp home already exists: ${TEMP_HOME}"
  exit 1
fi

log_step "Validating inputs"
if [ ! -d "${MAIN_HOME}" ]; then
  log_error "Main home not found: ${MAIN_HOME}"
  exit 1
fi

if [ ! -f "${GENESIS_PATH}" ]; then
  log_error "genesis.json not found: ${GENESIS_PATH}"
  exit 1
fi

if [ -z "${MAIN_DOCKER_NETWORK}" ]; then
  log_error "Could not detect docker network for main container: ${MAIN_CONTAINER}"
  exit 1
fi

if ! docker network inspect "${MAIN_DOCKER_NETWORK}" >/dev/null 2>&1; then
  log_error "Main docker network not found: ${MAIN_DOCKER_NETWORK}"
  exit 1
fi

if [ -z "${MAIN_CONTAINER_IP}" ]; then
  log_error "Could not detect IP for main container ${MAIN_CONTAINER} on network ${MAIN_DOCKER_NETWORK}"
  exit 1
fi

log_step "Preparing temp home"
log_info "Temp home directory: ${TEMP_HOME}"
mkdir -p "${TEMP_HOME}"
if [ "${NO_RESTORE}" = "true" ]; then
  log_warn "--from-scratch set; skipping copy and restore, syncing from zero"
else
  # NOTE: We do NOT copy cosmovisor/ from main node
  # Instead, we let the Docker container initialize it fresh with init-docker.sh
  # This ensures the temp node uses the correct binary from /usr/bin/inferenced
  # which contains all upgrade handlers (v0.2.2 through v0.2.6)
  
  log_step "Copying config (without validator keys)"
  log_info "cp -a ${MAIN_HOME}/config -> ${TEMP_HOME}/config"
  cp -a "${MAIN_HOME}/config" "${TEMP_HOME}/config"
  rm -f "${TEMP_HOME}/config/priv_validator_key.json" \
        "${TEMP_HOME}/config/node_key.json"
  mkdir -p "${TEMP_HOME}/data"
  mkdir -p "${TEMP_TMKMS_HOME}"
fi

# Copy snapshots (full copy, no filtering)
if [ "${NO_RESTORE}" != "true" ] && [ "${SKIP_SNAPSHOT_RESTORE}" != "true" ]; then
  if [ -d "${MAIN_HOME}/data/snapshots" ]; then
    log_step "Copying snapshots (full copy)"
    mkdir -p "${TEMP_HOME}/data"
    rm -rf "${TEMP_HOME}/data/snapshots"
    log_info "cp -a ${MAIN_HOME}/data/snapshots -> ${TEMP_HOME}/data/"
    cp -a "${MAIN_HOME}/data/snapshots" "${TEMP_HOME}/data/"
  else
    log_error "Snapshots dir not found: ${MAIN_HOME}/data/snapshots"
    exit 1
  fi

  log_step "Stopping main node before copying blockstore.db and state.db"
  if docker stop node; then
    NODE_STOPPED=true
    # Wait for container to fully stop and release database locks
    log_info "Waiting for main node to fully stop..."
    sleep 2
  else
    log_error "Failed to stop main node"
    exit 1
  fi

  log_step "Copying blockstore.db and state.db"
  rm -rf "${TEMP_HOME}/data/blockstore.db" "${TEMP_HOME}/data/state.db"
  log_info "cp -a ${MAIN_HOME}/data/blockstore.db -> ${TEMP_HOME}/data/"
  cp -a "${MAIN_HOME}/data/blockstore.db" "${TEMP_HOME}/data/"
  log_info "cp -a ${MAIN_HOME}/data/state.db -> ${TEMP_HOME}/data/"
  cp -a "${MAIN_HOME}/data/state.db" "${TEMP_HOME}/data/"
  
  # NOTE: We intentionally do NOT copy upgrade-info.json
  # After snapshot restore, the node will be at a height after all upgrades have occurred,
  # so there's no pending upgrade to process. Copying upgrade-info.json would confuse cosmovisor.
  log_info "Skipping upgrade-info.json (not needed after snapshot restore)"

  restart_main_node

  # Detect latest snapshot height if not provided
  if [ -z "${SNAPSHOT_HEIGHT}" ]; then
    log_step "Detecting latest snapshot height"
    SNAPSHOT_LIST=$(docker run --rm \
      -v "${TEMP_HOME}:/root/.inference" \
      "${IMAGE}" \
      inferenced snapshots list --home /root/.inference || true)

    SNAPSHOT_HEIGHT=$(printf "%s\n" "${SNAPSHOT_LIST}" | awk '{print $2}' | sort -n | tail -1)

    if [ -z "${SNAPSHOT_HEIGHT}" ]; then
      log_error "Could not detect snapshot height. Set SNAPSHOT_HEIGHT explicitly."
      if [ -n "${SNAPSHOT_LIST}" ]; then
        log_info "Snapshots list output:"
        while IFS= read -r line; do
          log_info "  ${line}"
        done <<< "${SNAPSHOT_LIST}"
      else
        log_warn "Snapshots list output is empty"
      fi
      exit 1
    fi
  fi

  log_info "Using snapshot height: ${SNAPSHOT_HEIGHT}"

  # Restore application.db from snapshot into TEMP_HOME
  # IMPORTANT: Use /usr/bin/inferenced from Docker image (not cosmovisor/current/bin/)
  # because it contains all upgrade handlers for v0.2.6 and earlier
  log_step "Restoring application.db from snapshot"
  set +e
  RESTORE_OUT=$(docker run --rm \
    -v "${TEMP_HOME}:/root/.inference" \
    -v "${GENESIS_PATH}:/root/.inference/config/genesis.json" \
    "${IMAGE}" \
    inferenced snapshots restore "${SNAPSHOT_HEIGHT}" "${SNAPSHOT_FORMAT}" --home /root/.inference 2>&1)
  RESTORE_RC=$?
  set -e

  if [ ${RESTORE_RC} -ne 0 ]; then
    log_error "Snapshot restore failed"
    log_error "${RESTORE_OUT}"
    exit ${RESTORE_RC}
  fi

  log_info "Snapshot restore completed"
elif [ "${NO_RESTORE}" != "true" ]; then
  log_warn "SKIP_SNAPSHOT_RESTORE=true; starting temp node without snapshot restore"
fi

restart_main_node

if [ -n "${TEMP_P2P_EXTERNAL_ADDRESS}" ]; then
  log_info "Temp P2P external address: ${TEMP_P2P_EXTERNAL_ADDRESS}"
else
  log_warn "P2P_EXTERNAL_ADDRESS not set; temp node will not advertise an external P2P address"
fi

log_step "Building docker-compose.temp.yml"
log_info "Using main docker network: ${MAIN_DOCKER_NETWORK}"
log_info "Using local seed RPC for temp node: ${TEMP_SEED_NODE_RPC_URL}"
log_info "Using local seed P2P for temp node: ${TEMP_SEED_NODE_P2P_URL}"
P2P_EXTERNAL_ADDRESS="${TEMP_P2P_EXTERNAL_ADDRESS}" \
TEMP_SEED_NODE_RPC_URL="${TEMP_SEED_NODE_RPC_URL}" \
TEMP_SEED_NODE_P2P_URL="${TEMP_SEED_NODE_P2P_URL}" \
TEMP_RPC_SERVER_URL_1="${TEMP_RPC_SERVER_URL_1}" \
TEMP_RPC_SERVER_URL_2="${TEMP_RPC_SERVER_URL_2}" \
MAIN_DOCKER_NETWORK="${MAIN_DOCKER_NETWORK}" \
yq e '
  .services |= with_entries(select(.key == "node" or .key == "tmkms")) |
  .networks.temp_main_net.external = true |
  .networks.temp_main_net.name = env(MAIN_DOCKER_NETWORK) |
  .services.node.container_name = "'"${TEMP_CONTAINER}"'" |
  .services.tmkms.container_name = "tmkms-temp" |
  .services.node.ports = ["'"${TEMP_P2P_PORT}"':26656","'"${TEMP_RPC_PORT}"':26657"] |
  .services.node.networks = (((.services.node.networks // ["default"]) + ["temp_main_net"]) | unique) |
  .services.node.volumes = ((.services.node.volumes // []) | map(select(. != ".inference:/root/.inference")) + ["'"${TEMP_HOME}"':/root/.inference"]) |
  .services.tmkms.volumes = ((.services.tmkms.volumes // []) | map(select(. != ".tmkms:/root/.tmkms")) + ["'"${TEMP_TMKMS_HOME}"':/root/.tmkms"]) |
  .services.node.environment = (
    (.services.node.environment // [])
    | map(select(test("^(P2P_EXTERNAL_ADDRESS=|APP_NAME=|SYNC_WITH_SNAPSHOTS=|IS_GENESIS=|SEED_NODE_RPC_URL=|SEED_NODE_P2P_URL=|RPC_SERVER_URL_1=|RPC_SERVER_URL_2=)") | not))
    + ["P2P_EXTERNAL_ADDRESS=" + env(P2P_EXTERNAL_ADDRESS)]
    + ["SYNC_WITH_SNAPSHOTS=true"]
    + ["IS_GENESIS=false"]
    + ["SEED_NODE_RPC_URL=" + env(TEMP_SEED_NODE_RPC_URL)]
    + ["SEED_NODE_P2P_URL=" + env(TEMP_SEED_NODE_P2P_URL)]
    + ["RPC_SERVER_URL_1=" + env(TEMP_RPC_SERVER_URL_1)]
    + ["RPC_SERVER_URL_2=" + env(TEMP_RPC_SERVER_URL_2)]
  )
' - < "${COMPOSE_FILE}" > "${TEMP_COMPOSE_FILE}"

log_info "Temporary compose file: ${TEMP_COMPOSE_FILE}"

log_step "Starting temporary node and tmkms with docker compose"
docker compose -p "${TEMP_PROJECT_NAME}" -f "${TEMP_COMPOSE_FILE}" up -d

log_info "Temporary node started: ${TEMP_CONTAINER}"
log_info "Temp RPC: http://127.0.0.1:${TEMP_RPC_PORT}"
