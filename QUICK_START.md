# Quick Start: Clearing database via a temporary node

## Requirements

**Working Directory:** `gonka/deploy/join`

```bash
cd gonka/deploy/join
```

**Required Tools:** Docker, Docker Compose, `jq`, `yq`

Install `yq` if needed:
```bash
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq
```

## Brief Instructions

To synchronize the node with minimal downtime, use three scripts sequentially:

**Step 1:** Launch temporary node with `sudo ./temp-node/start-temp.sh` (fast temp node sync, but main node downtime 2-10 minutes) or `sudo ./temp-node/start-temp.sh --from-scratch` (slow network sync, but main node downtime only few seconds). The first option stops the main node to copy DB and snapshots, then restores state from local snapshot. The second option copies only config and syncs temporary node from network without stopping main node, but takes significantly longer (hours/days).

**Step 2:** Wait for synchronization with `sudo ./temp-node/wait-temp-sync.sh`, which monitors block heights of both nodes and completes when difference becomes less than 5 blocks.

**Step 3:** Perform state swap with `sudo ./temp-node/swap-from-temp.sh`, which stops both nodes, creates backup of main node current state (`.inference/data.bak`, `.inference/wasm.bak`), transfers synchronized state from temporary node and starts main node. Script automatically checks that PoC phase is inactive and aborts if backup already exists. After verifying operation, delete temporary files (`rm -rf .inference-temp .tmkms-temp docker-compose.temp.yml`) and backups.

---

## Commands to Copy

### With Restore from Local Snapshots
```bash
sudo ./temp-node/start-temp.sh && \
sudo ./temp-node/wait-temp-sync.sh && \
sudo ./temp-node/swap-from-temp.sh
```

### With Sync from Scratch via Network
```bash
sudo ./temp-node/start-temp.sh --from-scratch && \
sudo ./temp-node/wait-temp-sync.sh && \
sudo ./temp-node/swap-from-temp.sh
```
