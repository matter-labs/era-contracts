# Multi-Chain Anvil Interop Tests

End-to-end tests for ZKsync interoperability across 5 Anvil chains: L1 contract deployment, L1<->L2 bridging (ETH + ERC20), L2<->L2 interop transfers, gateway setup with chain migration, and balance tracking via L1AssetTracker.

## Chain Topology

```
┌──────────────┐
│  L1 (31337)  │  port 9545 — Bridgehub, CTM, L1AssetRouter, L1NTV, L1AssetTracker
│  settlement  │
└──────┬───────┘
       │
       ├──► L2  (10)  port 4050 — settled directly on L1
       │
       ├──► GW  (11)  port 4051 — gateway chain (settled on L1, settlement layer for L2A/L2B)
       │     │
       │     ├──► L2A (12)  port 4052 — settled via GW
       │     └──► L2B (13)  port 4053 — settled via GW
       │
       └──► (L2A and L2B also registered on L1 but migrated to GW)
```

## Quick Start

```bash
# From repo root — run full deployment + all tests (~3.5 min)
yarn test:hardhat:interop

# Keep chains running after tests finish
yarn test:hardhat:interop --keep-chains
```

## Running Tests Without Redeployment

After running once with `--keep-chains`, the Anvil chains and deployment state persist. Re-run just the hardhat tests:

```bash
# Run all test specs (no redeployment)
cd contracts/l1-contracts
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test test/anvil-interop/test/hardhat/*.spec.ts \
  --network hardhat --no-compile

# Run a single spec file
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test test/anvil-interop/test/hardhat/02-direct-bridge.spec.ts \
  --network hardhat --no-compile

# Filter by test name with --grep
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test test/anvil-interop/test/hardhat/02-direct-bridge.spec.ts \
  --network hardhat --no-compile --grep "withdraws ETH"
```

You can also add `.only` to a `describe` or `it` block in the spec file to isolate tests.

## Test Specs

| Spec | What it tests |
|------|---------------|
| `01-deployment-verification` | L1 contracts deployed, CTM registered, all 4 L2 chains have diamond proxies, L2 system contracts present, test tokens deployed, initial chainBalance is zero |
| `02-direct-bridge` | L1->L2 ETH deposit + L2->L1 ETH withdrawal on chain 10 (direct L1 settlement), L1AssetTracker chainBalance tracking, balance conservation |
| `03-interop-transfer` | L2<->L2 token transfers via InteropCenter between direct-settlement chains (10, 11, 12) |
| `04-gateway-setup` | GW chain contracts deployed, interop chains registered on GW L2Bridgehub, GW designated as settlement layer on L1 |
| `05-gateway-bridge` | L1->L2A ETH deposit + L2A->L1 ETH withdrawal on chain 12 (via GW), L1AssetTracker chainBalance tracking |
| `06-gateway-interop` | L2A<->L2B interop transfers (both on GW), L2A<->GW interop transfers |

## Environment Variables

| Variable | Effect |
|----------|--------|
| `ANVIL_INTEROP_SKIP_SETUP=1` | Skip deployment, run only tests (requires chains already running) |
| `ANVIL_INTEROP_SKIP_CLEANUP=1` | Don't kill Anvil processes after tests |
| `ANVIL_INTEROP_KEEP_CHAINS=1` | Same as `--keep-chains` flag |

## Debugging

Every transaction hash in the test output is printed as a `cast run` command:

```
L1 tx: cast run 0x9eb4...acf83 -r http://127.0.0.1:9545
L2 bridgeBurn tx: cast run 0x4856...736d6 -r http://127.0.0.1:4050
```

Copy-paste into a terminal (while chains are still running) to get the full execution trace.

## File Structure

```
test/anvil-interop/
├── run-hardhat-interop-test.ts    # Main entry: deployment + hardhat test runner
├── config/
│   ├── anvil-config.json          # Chain IDs, ports, gateway designation
│   ├── l1-deployment.toml         # L1 contract deployment params
│   └── ctm-deployment.toml        # ChainTypeManager params
├── src/
│   ├── deployment-runner.ts       # Orchestrates all deployment steps
│   ├── anvil-manager.ts           # Start/stop Anvil processes
│   ├── deployer.ts                # Execute forge deployment scripts
│   ├── chain-registry.ts          # Register L2 chains on L1
│   ├── l2-genesis-upgrade-deployer.ts  # Deploy L2 system contracts via anvil_setCode
│   ├── gateway-setup.ts           # Gateway designation + chain migration
│   ├── gateway-deployer.ts        # Pre-deploy GW CTM contracts
│   ├── token-balance-migration.ts # TBM during migration
│   ├── l1-deposit-helper.ts       # L1->L2 ETH/ERC20 deposits
│   ├── l2-withdrawal-helper.ts    # L2->L1 ETH/ERC20 withdrawals
│   ├── token-transfer.ts          # L2<->L2 interop token transfers
│   ├── balance-tracker.ts         # L1AssetTracker balance snapshots
│   ├── batch-settler.ts           # Batch commit/prove/execute on L1
│   ├── l1-to-l2-relayer.ts        # Relay L1->L2 transactions
│   ├── l2-to-l2-relayer.ts        # Relay L2->L2 interop messages
│   ├── const.ts                   # System contract addresses
│   ├── types.ts                   # TypeScript interfaces
│   └── utils.ts                   # Helpers (ABI loading, asset ID encoding)
├── test/hardhat/
│   ├── 01-deployment-verification.spec.ts
│   ├── 02-direct-bridge.spec.ts
│   ├── 03-interop-transfer.spec.ts
│   ├── 04-gateway-setup.spec.ts
│   ├── 05-gateway-bridge.spec.ts
│   └── 06-gateway-interop.spec.ts
├── outputs/                       # Deployment outputs (gitignored)
└── cleanup.sh                     # Kill Anvil processes, reset state
```

## Key Patterns

### Anvil EVM vs ZKsync VM

On ZKsync VM, all functions can receive ETH value even if not marked `payable`. On Anvil (plain EVM), Solidity enforces the callvalue check. This affects:

- **ETH withdrawals**: `L2AssetRouter.withdraw()` is not payable, but the NTV requires `msg.value == amount` for base token. Solution: bypass L2AssetRouter and call `L2NTV.bridgeBurn` directly by impersonating L2AssetRouter.
- **L2 deposit finalization**: Uses `anvil_impersonateAccount` to act as the aliased L1AssetRouter.

### Proof Bypass

L1 withdrawal finalization normally requires batch proofs. For Anvil testing, we use `anvil_impersonateAccount` on the L1Nullifier to call `L1AssetRouter.finalizeDeposit` directly.

### Data Encoding

L1 `bridgeMint` expects `DataEncoding.encodeBridgeMintData` format: `(address originalCaller, address receiver, address originToken, uint256 amount, bytes metadata)`. This is different from the L2 burn data format `(uint256 amount, address receiver, address token)`.

## Cleanup

```bash
# Full cleanup: kill chains, remove outputs, reset state
cd contracts/l1-contracts/test/anvil-interop
yarn cleanup
```
