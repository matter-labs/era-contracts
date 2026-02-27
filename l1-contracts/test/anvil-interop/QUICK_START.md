# Quick Start Guide

## Prerequisites

```bash
cd contracts/l1-contracts
forge build                    # Build Solidity contracts
cd test/anvil-interop
yarn                           # Install dependencies (if not done)
```

## Run Tests

```bash
# From contracts/l1-contracts/ — fastest way to run everything (~85s with pregenerated state)
cd contracts/l1-contracts
yarn test:hardhat:interop

# Force full deployment from scratch (~5 min)
ANVIL_INTEROP_FRESH_DEPLOY=1 yarn test:hardhat:interop

# Keep chains running after tests (for debugging or re-running individual tests)
yarn test:hardhat:interop --keep-chains

# Run on different ports (e.g. to avoid conflicts with another running instance)
# Shifts all ports by N: L1 becomes 9545+N, chains become 4050+N, 4051+N, etc.
yarn test:hardhat:interop --port-offset 100
```

## Re-run Tests (Chains Already Running)

After `--keep-chains`, re-run tests without redeployment:

```bash
cd contracts/l1-contracts

# All specs
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test test/anvil-interop/test/hardhat/0*.spec.ts \
  --network hardhat --no-compile

# Single spec
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test test/anvil-interop/test/hardhat/02-direct-bridge.spec.ts \
  --network hardhat --no-compile

# Filter by test name
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test test/anvil-interop/test/hardhat/05-gateway-bridge.spec.ts \
  --network hardhat --no-compile --grep "deposits ETH"
```

## Interactive Environment

```bash
cd contracts/l1-contracts/test/anvil-interop

# Start all chains + deploy + keep running (Ctrl+C to stop)
yarn start
```

Then in another terminal:

```bash
cd contracts/l1-contracts/test/anvil-interop
yarn send:l2-to-l2              # L2->L2 interop message
yarn deploy:test-token           # Deploy ERC20 test token
yarn send:token                  # Token transfer
```

## Step-by-Step Deployment

```bash
cd contracts/l1-contracts/test/anvil-interop
yarn step1  # Start Anvil chains
yarn step2  # Deploy L1 contracts
yarn step3  # Register L2 chains
yarn step4  # Initialize L2 (L2GenesisUpgrade)
yarn step5  # Setup gateway
yarn step6  # Start batch settler daemon
```

## Regenerate Pregenerated State

After changing contracts, regenerate the chain state snapshots:

```bash
cd contracts/l1-contracts/test/anvil-interop
yarn setup-and-dump
```

## Cleanup

```bash
cd contracts/l1-contracts/test/anvil-interop
yarn cleanup                    # Kill Anvil processes, remove outputs
```

## Troubleshooting

| Issue                             | Solution                                           |
| --------------------------------- | -------------------------------------------------- |
| "L2 chains not found"             | Run `yarn step1` first                             |
| "Could not read [Contract]"       | Run `forge build` in `l1-contracts/`               |
| Transaction reverted              | Use `cast run <tx_hash> -r <rpc_url>` to trace     |
| Tests fail after contract changes | Run `yarn setup-and-dump` to regenerate state      |
| Port conflicts                    | Use `ANVIL_INTEROP_PORT_OFFSET=100` to shift ports |
