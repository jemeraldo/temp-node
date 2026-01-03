# Gonka Temp Node Sync Scripts

Zero-downtime synchronization scripts for Gonka blockchain nodes using temporary node approach.

## 📋 Overview

This toolset allows you to sync your Gonka node with minimal downtime by using a temporary node. Perfect for catching up with the network without interrupting your main node operation.

## 🚀 Quick Start

See [QUICK_START.md](QUICK_START.md) for a brief overview.

## 📖 Full Documentation

See [TEMP_NODE_SYNC.md](TEMP_NODE_SYNC.md) for detailed documentation.

## 📦 Installation

### Prerequisites

- Running Gonka node in `gonka/deploy/join` directory
- Docker and Docker Compose installed
- Ports 15001 (P2P) and 26667 (RPC) available for temp node
- `jq` installed for JSON parsing

### Setup

```bash
# 1. Navigate to your Gonka deployment directory
cd gonka/deploy/join

# 2. Clone this repository
git clone https://github.com/YOUR_USERNAME/gonka-temp-node-sync.git temp-node

# 3. Make scripts executable
chmod +x temp-node/*.sh

# 4. Verify installation
ls -la temp-node/
```

## 🎯 Usage

### Option 1: Fast Sync (with local snapshots)

**Downtime:** 2-5 minutes for DB copy  
**Sync time:** 10-30 minutes from last snapshot

```bash
cd gonka/deploy/join

sudo ./temp-node/start-temp.sh && \
./temp-node/wait-temp-sync.sh && \
sudo ./temp-node/swap-from-temp.sh
```

### Option 2: Zero-Downtime Sync (from network)

**Downtime:** ~30 seconds (only during swap)  
**Sync time:** Hours/days (full network sync)

```bash
cd gonka/deploy/join

sudo ./temp-node/start-temp.sh --no-restore && \
./temp-node/wait-temp-sync.sh && \
sudo ./temp-node/swap-from-temp.sh
```

## 🗑️ Cleanup

After successful swap and verification:

```bash
# Remove temporary files
rm -rf .inference-temp .tmkms-temp docker-compose.temp.yml

# Remove backups (when you're sure everything works)
rm -rf .inference/data.bak .inference/wasm.bak
```

## 🔄 Rollback

If something goes wrong:

```bash
# Use the rollback script
./temp-node/rollback-swap.sh

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
./temp-node/wait-temp-sync.sh
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
curl http://127.0.0.1:26667/status | jq .result.sync_info
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

## 📄 License

[Specify your license]

## 🤝 Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## 📞 Support

For issues or questions, please open an issue on GitHub.
