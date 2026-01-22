# Quick Start Guide

## Installation

```bash
cd scripts/anvil-interop
yarn install
```

## Start the Environment

```bash
yarn start
```

Expected output:
```
🚀 Starting Multi-Chain Anvil Testing Environment

=== Step 1: Starting Anvil Chains ===
🚀 Starting L1 Chain 1 on port 9545...
✅ L1 Chain 1 on port 9545 started successfully
🚀 Starting L2 Chain 10 on port 4050...
✅ L2 Chain 10 on port 4050 started successfully
🚀 Starting L2 Chain 11 on port 4051...
✅ L2 Chain 11 on port 4051 started successfully
🚀 Starting L2 Chain 12 on port 4052...
✅ L2 Chain 12 on port 4052 started successfully

=== Step 2: Deploying L1 Contracts ===
📦 Deploying L1 core contracts...
✅ L1 core contracts deployed

L1 Core Addresses:
  Bridgehub: 0x...
  L1SharedBridge: 0x...

📦 Deploying ChainTypeManager...
✅ ChainTypeManager deployed

CTM Addresses:
  ChainTypeManager: 0x...

📝 Registering ChainTypeManager with Bridgehub...
✅ ChainTypeManager registered

=== Step 3: Registering L2 Chains ===
📝 Registering L2 chain 10...
✅ Chain 10 registered
📝 Registering L2 chain 11...
✅ Chain 11 registered
📝 Registering L2 chain 12...
✅ Chain 12 registered

=== Step 4: Initializing L2 System Contracts ===
🔧 Initializing L2 system contracts for chain 10...
✅ L2 system contracts initialized for chain 10
🔧 Initializing L2 system contracts for chain 11...
✅ L2 system contracts initialized for chain 11
🔧 Initializing L2 system contracts for chain 12...
✅ L2 system contracts initialized for chain 12

=== Step 5: Setting Up Gateway ===
🌐 Designating chain 11 as Gateway...
✅ Chain 11 designated as Gateway

=== Step 6: Starting Batch Settler Daemon ===
🔄 Starting batch settler daemon...
✅ Batch settler daemon started

=== ✅ Multi-Chain Environment Ready ===

Environment Details:
  L1 Chain: 1 at http://127.0.0.1:9545
  L2 Chain: 10 at http://127.0.0.1:4050
  L2 Chain: 11 at http://127.0.0.1:4051 (Gateway)
  L2 Chain: 12 at http://127.0.0.1:4052

Press Ctrl+C to stop all chains and exit.
```

## Test It

### Send a transaction on L2
```bash
cast send 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  --value 1ether \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://127.0.0.1:4050
```

Watch the batch settler automatically commit, prove, and execute the batch:
```
📊 Chain 10: Processing blocks 1 to 1
📝 Committing batch for chain 10...
✅ Batch 1 committed for chain 10
🔍 Proving batch for chain 10...
✅ Batch 1 proved for chain 10
⚡ Executing batch for chain 10...
✅ Batch 1 executed for chain 10
```

## RPC Endpoints

- **L1**: `http://127.0.0.1:9545`
- **L2 Chain 10**: `http://127.0.0.1:4050`
- **L2 Chain 11** (Gateway): `http://127.0.0.1:4051`
- **L2 Chain 12**: `http://127.0.0.1:4052`

## Default Anvil Account

- **Address**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- **Private Key**: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
- **Balance**: 10,000 ETH

## Stop the Environment

Press `Ctrl+C` to gracefully shutdown all chains.

## Troubleshooting

### "Port already in use"
```bash
pkill anvil
# or
lsof -ti:9545,4050,4051,4052 | xargs kill -9
```

### "Forge script failed"
- Ensure Foundry is installed: `forge --version`
- Check config files in `config/`
- Review error output in terminal

### "Chain not ready"
- Wait 30 seconds for chains to fully start
- Check Anvil logs for errors
- Verify no port conflicts

## Full Documentation

See [README.md](./README.md) for complete documentation.
