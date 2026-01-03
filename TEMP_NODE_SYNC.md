# Documentation: Clearing database via a temporary node

A set of scripts for clearing node database with minimal downtime using a temporary node approach.

## Requirements

**Working Directory:** All commands must be run from `gonka/deploy/join` directory

```bash
cd gonka/deploy/join
```

**Required Tools:**
- Docker and Docker Compose
- `jq` for JSON parsing
- `yq` for YAML parsing (install: `sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq`)

## Process Overview

1. **start-temp.sh** - launch temporary node
2. **wait-temp-sync.sh** - monitor temporary node synchronization
3. **swap-from-temp.sh** - swap main node state with synchronized temp state

## Scripts

### 1. start-temp.sh

Creates and launches a temporary node for synchronization.

**Usage:**
```bash
sudo ./temp-node/start-temp.sh [--from-scratch]
```

**Options:**
- `--from-scratch` - sync from scratch via network (without local snapshots)

**Two Operation Modes:**

#### Mode with Local Snapshots (default)
```bash
sudo ./temp-node/start-temp.sh
```
- ✅ Fast synchronization (from latest snapshot)
- ⚠️ Stops main node during DB copy (usually 2-10 minutes)
- 📋 Copies: `blockstore.db`, `state.db`, snapshots
- 🎯 Recommended for quick recovery

#### Network Sync Mode
```bash
sudo ./temp-node/start-temp.sh --from-scratch
```
- ✅ Near-zero downtime for main node (few seconds)
- ⏱️ Long synchronization (hours/days, downloads snapshots from network)
- 📋 Copies only config (no DB)
- 🎯 Recommended when downtime is critical

**What it does:**
- Creates `.inference-temp/` and `.tmkms-temp/`
- Generates `docker-compose.temp.yml`
- Launches temporary node on ports 15001 (P2P), 26667 (RPC)

### 2. wait-temp-sync.sh

Monitors synchronization of temporary node with main node.

**Usage:**
```bash
./temp-node/wait-temp-sync.sh
```

**Parameters (via environment variables):**
- `HEIGHT_DIFF_THRESHOLD=5` - acceptable block height difference (default 5)
- `POLL_INTERVAL=5` - check interval in seconds (default 5)

**Example:**
```bash
# Wait until difference becomes < 3 blocks
HEIGHT_DIFF_THRESHOLD=3 ./temp-node/wait-temp-sync.sh
```

**Output:**
```
[INFO] Temp height=12345 catching_up=true | Main height=12350 catching_up=false | diff=5
[INFO] Temp height=12348 catching_up=false | Main height=12350 catching_up=false | diff=2
[INFO] Height diff < 5. Done.
```

### 3. swap-from-temp.sh

Replaces main node state with synchronized temporary node state.

**Usage:**
```bash
sudo ./temp-node/swap-from-temp.sh [--copy-temp]
```

**Options:**
- `--copy-temp` - copy temporary node state instead of moving (Not recommended)

**Safety:**
- ⚠️ Checks that PoC phase is inactive (otherwise aborts operation)
- ⚠️ Aborts if backup already exists
- 💾 Creates backup: `.inference/data.bak`, `.inference/wasm.bak`

**What it does:**
1. Checks PoC status via API: `http://127.0.0.1:8000/v1/epochs/latest`
2. Stops both main and temporary nodes
3. Creates backup of current state
4. Moves/copies `data/` and `wasm/` from temporary node
5. Starts main node with new state
6. Leaves temporary node stopped

## Full Workflow

### Option 1: Fast Sync (with main node stop)

```bash
# 1. Start temporary node (stops main node for 2-10 min)
sudo ./temp-node/start-temp.sh

# 2. Wait for synchronization
./temp-node/wait-temp-sync.sh

# 3. Switch to synchronized state
sudo ./temp-node/swap-from-temp.sh
```

**Time:**
- Main node downtime: 2-10 minutes (DB copy)
- Temp sync time: 10-30 minutes (from latest snapshot)
- Total time: ~15-40 minutes

### Option 2: Zero-Downtime Sync (from network)

```bash
# 1. Start temporary node (main continues running)
sudo ./temp-node/start-temp.sh --from-scratch

# 2. Wait for synchronization (may take hours)
./temp-node/wait-temp-sync.sh

# 3. Switch to synchronized state
sudo ./temp-node/swap-from-temp.sh
```

**Time:**
- Main node downtime: few seconds (swap only)
- Temp sync time: several hours/days (from network)
- Total time: depends on blockchain size

## Environment Variables

Configuration via `config.env` or direct export:

```bash
# Directories
MAIN_HOME=".inference"
TEMP_HOME=".inference-temp"
TEMP_TMKMS_HOME=".tmkms-temp"

# Temporary node ports
TEMP_P2P_PORT=15001
TEMP_RPC_PORT=26667

# Container names
TEMP_CONTAINER="node-temp"
TEMP_PROJECT_NAME="gonka-temp"

# PoC check
POC_CHECK_URL="http://127.0.0.1:8000/v1/epochs/latest"

# Sync monitoring
HEIGHT_DIFF_THRESHOLD=5
POLL_INTERVAL=5
```

## Rollback

If something goes wrong after swap:

```bash
# Stop main node
docker stop node

# Restore backup
cd .inference
rm -rf data wasm
mv data.bak data
mv wasm.bak wasm

# Start main node
docker start node
```

Or use `sudo ./temp-node/rollback-swap.sh` (if available).

## Cleanup

After successful swap and verification:

```bash
# Remove temporary files
rm -rf .inference-temp
rm -rf .tmkms-temp
rm -f docker-compose.temp.yml

# Remove temporary containers
docker compose -p gonka-temp down -v

# Remove backups (when you're sure everything works)
rm -rf .inference/data.bak
rm -rf .inference/wasm.bak
```

## Troubleshooting

**Temporary node not starting:**
```bash
# Check logs
docker logs node-temp

# Check ports
netstat -tulpn | grep -E "(15001|26667)"
```

**Sync stuck:**
```bash
# Check status
curl http://127.0.0.1:26667/status | jq .result.sync_info
curl http://127.0.0.1:26657/status | jq .result.sync_info
```

**Swap aborted due to PoC:**
```bash
# Check PoC status
curl http://127.0.0.1:8000/v1/epochs/latest | jq .is_confirmation_poc_active

# Wait for PoC phase to end and retry swap
```

## Recommendations

1. **Use local snapshots** if 2-10 minutes downtime is acceptable
2. **Use --from-scratch** if maximum availability is required
3. **Monitor PoC phases** - swap is blocked during PoC
4. **Keep backups** until full node operation verification
5. **Test the process** on test node before production
