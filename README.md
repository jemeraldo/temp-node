# Gonka clearing database via a temporary node

> **English version** | **[Русская версия](README.ru.md)**

## 📋 Overview

This toolset allows you to clean up your Gonka node db with minimal downtime by using a temporary node. 

## 🚀 Quick Start

See [QUICK_START.md](QUICK_START.md) for a brief overview ([Russian version](QUICK_START.ru.md)).

## 📖 Full Documentation

See [TEMP_NODE_SYNC.md](TEMP_NODE_SYNC.md) for detailed documentation ([Russian version](TEMP_NODE_SYNC.ru.md)).

## 📦 Installation

### Prerequisites

- Running Gonka node in `gonka/deploy/join` directory
- Docker and Docker Compose installed
- Ports 15001 (P2P) and 26667 (RPC) available for temp node
- `jq` installed for JSON parsing
- `yq` installed for YAML parsing (required by start-temp.sh)

### Setup

```bash
# 1. Install yq if not already installed
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq

# 2. Navigate to your Gonka deployment directory
cd gonka/deploy/join

# 3. Clone this repository
git clone https://github.com/jemeraldo/temp-node.git temp-node

# 4. Make scripts executable
chmod +x temp-node/*.sh

# 5. Verify installation
ls -la temp-node/
```

## 🎯 Usage

### Option 1: Fast Sync (with local snapshots)

**Main node downtime:** 2-10 minutes for DB copy  
**Sync time:** 10-30 minutes from last snapshot

```bash
cd gonka/deploy/join

sudo ./temp-node/start-temp.sh && \
sudo ./temp-node/wait-temp-sync.sh && \
sudo ./temp-node/swap-from-temp.sh
```

### Option 2: Zero-Downtime Sync (from network)

**Main node downtime:** few seconds (only during swap from temp node)  
**Sync time:** Hours (full network sync)

```bash
cd gonka/deploy/join

sudo ./temp-node/start-temp.sh --from-scratch && \
sudo ./temp-node/wait-temp-sync.sh && \
sudo ./temp-node/swap-from-temp.sh
```

**Option 2 is recommended if you have time to sync from the network.**

## 🗑️ Cleanup

After successful swap and verification:

```bash
# Remove temp services
docker rm -f node-temp tmkms-temp
# Remove temporary files
rm -rf .inference-temp .tmkms-temp docker-compose.temp.yml
# Remove backups (when you're sure everything works!)
rm -rf .inference/data.bak .inference/wasm.bak
```

## 🔄 Rollback

If something goes wrong:

```bash
# Use the rollback script
sudo ./temp-node/rollback-swap.sh

# Or manually:
docker stop node
cd .inference
rm -rf data wasm
mv data.bak data
mv wasm.bak wasm
docker start node
```

## ⚙️ Configuration

Environment variables (optional):

```bash
# Customize sync monitoring
export HEIGHT_DIFF_THRESHOLD=5
export POLL_INTERVAL=5

# Run wait script
sudo ./temp-node/wait-temp-sync.sh
```

## 📝 Scripts Overview

| Script | Description |
|--------|-------------|
| `start-temp.sh` | Launch temporary node for synchronization |
| `wait-temp-sync.sh` | Monitor temp node sync progress |
| `swap-from-temp.sh` | Swap main node state with synced temp |
| `rollback-swap.sh` | Rollback swap operation if needed |

## ⚠️ Important Notes

1. **PoC Phase:** Swap is blocked during active PoC phase
2. **Backups:** Always created automatically during swap
3. **Verification:** Test the process on a test node first
4. **Ports:** Ensure temp node ports (15001, 26667) are available

## 🔧 Troubleshooting

**Temp node not starting:**
```bash
docker logs node-temp
```

**Sync stuck:**
```bash
docker exec node-temp inferenced status | jq .result.sync_info
```

**Swap blocked:**
```bash
# Check PoC status
curl http://127.0.0.1:8000/v1/epochs/latest | jq .is_confirmation_poc_active
```

## 🔄 Updates

To update scripts to the latest version:

```bash
cd gonka/deploy/join/temp-node
git pull
```
