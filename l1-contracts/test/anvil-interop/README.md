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
# From repo root — run all tests with pregenerated state (~85s)
yarn test:hardhat:interop

# Force full deployment from scratch (~5 min)
ANVIL_INTEROP_FRESH_DEPLOY=1 yarn test:hardhat:interop

# Keep chains running after tests finish
yarn test:hardhat:interop --keep-chains
```

## Pregenerated Chain States

Tests load pregenerated Anvil snapshots from `chain-states/v0.31.0/` by default. This skips the full deployment and cuts test time from ~5 min to ~85s.

The runner auto-detects pregenerated state by checking for `chain-states/<protocol-version>/addresses.json`. If found, it restores each chain via `anvil_loadState`. If not found (or `FRESH_DEPLOY=1`), it runs the full 5-step deployment.

To regenerate pregenerated state after contract changes:

```bash
cd contracts/l1-contracts/test/anvil-interop
yarn setup-and-dump
```

This runs the full deployment with deterministic settings (`blockTime=0`, `timestamp=1`) and dumps each chain's state to the `chain-states/` directory.

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

| Spec                         | What it tests                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `01-deployment-verification` | L1 contracts deployed, CTM registered, all 4 L2 chains have diamond proxies, L2 system contracts present, test tokens deployed, initial chainBalance is zero |
| `02-direct-bridge`           | L1->L2 ETH deposit + L2->L1 ETH withdrawal on chain 10 (direct L1 settlement), L1AssetTracker chainBalance tracking, balance conservation                    |
| `03-interop-transfer`        | L2<->L2 token transfers via InteropCenter between direct-settlement chains (10, 11, 12)                                                                      |
| `04-gateway-setup`           | GW chain contracts deployed, interop chains registered on GW L2Bridgehub, GW designated as settlement layer on L1                                            |
| `05-gateway-bridge`          | L1->L2A ETH deposit + L2A->L1 ETH withdrawal on chain 12 (via GW), L1AssetTracker chainBalance tracking, token balance migration, processLogsAndMessages     |
| `06-gateway-interop`         | L2A<->L2B interop transfers (both on GW), L2A<->GW interop transfers                                                                                         |

## Environment Variables

| Variable                                 | Effect                                                            |
| ---------------------------------------- | ----------------------------------------------------------------- |
| `ANVIL_INTEROP_SKIP_SETUP=1`             | Skip deployment, run only tests (requires chains already running) |
| `ANVIL_INTEROP_SKIP_CLEANUP=1`           | Don't kill Anvil processes after tests                            |
| `ANVIL_INTEROP_KEEP_CHAINS=1`            | Same as `--keep-chains` flag                                      |
| `ANVIL_INTEROP_FRESH_DEPLOY=1`           | Force full deployment even if pregenerated state exists           |
| `ANVIL_INTEROP_PORT_OFFSET=N`            | Offset all chain ports by N (useful for parallel runs)            |
| `ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE=1` | Use genesis upgrade deployer for L2 initialization                |

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
├── setup-and-dump-state.ts        # Generate pregenerated chain state snapshots
├── index.ts                       # Interactive multi-chain environment (yarn start)
├── step1-start-chains.ts          # Step 1: start Anvil chains
├── step2-deploy-l1.ts             # Step 2: deploy L1 contracts
├── step3-register-chains.ts       # Step 3: register L2 chains on L1
├── step4-initialize-l2.ts         # Step 4: initialize L2 system contracts
├── step5-setup-gateway.ts         # Step 5: setup gateway
├── step6-start-settler.ts         # Step 6: start batch settler daemon
├── deploy-test-token.ts           # Deploy test ERC20 tokens
├── cleanup.sh                     # Kill Anvil processes, reset state
├── config/
│   ├── anvil-config.json          # Chain IDs, ports, gateway designation
│   ├── l1-deployment.toml         # L1 contract deployment params
│   ├── ctm-deployment.toml        # ChainTypeManager params
│   ├── permanent-values.toml      # Immutable protocol values
│   └── chain-{10,11,12,13}.toml   # Per-chain deployment params
├── chain-states/
│   └── v0.31.0/                   # Pregenerated Anvil state snapshots
│       ├── 31337.json             # L1 state dump
│       ├── {10,11,12,13}.json     # L2 chain state dumps
│       └── addresses.json         # All contract addresses + test tokens
├── src/
│   ├── deployment-runner.ts       # Orchestrates all deployment steps
│   ├── anvil-manager.ts           # Start/stop Anvil processes
│   ├── deployer.ts                # Execute forge deployment scripts
│   ├── forge.ts                   # Forge command wrapper
│   ├── chain-registry.ts          # Register L2 chains on L1
│   ├── l2-genesis-helper.ts       # L2 genesis contract setup
│   ├── l2-genesis-upgrade-deployer.ts  # Deploy L2 system contracts via anvil_setCode
│   ├── system-contracts-deployer.ts    # L2 system contracts deployment
│   ├── gateway-setup.ts           # Gateway designation + chain migration
│   ├── gateway-deployer.ts        # Pre-deploy GW CTM contracts
│   ├── l1-deposit-helper.ts       # L1->L2 ETH/ERC20 deposits (via TwoBridges)
│   ├── l2-withdrawal-helper.ts    # L2->L1 ETH/ERC20 withdrawals
│   ├── token-transfer.ts          # L2<->L2 interop token transfers
│   ├── token-balance-migration.ts         # Token balance migration during gateway migration
│   ├── token-balance-migration-helper.ts  # TBM helper (L2->L1->GW relay)
│   ├── process-logs-helper.ts     # Build and process withdrawal logs on GW
│   ├── balance-tracker.ts         # L1AssetTracker balance snapshots
│   ├── batch-settler.ts           # Batch commit/prove/execute on L1
│   ├── l1-to-l2-relayer.ts        # Relay L1->L2 transactions
│   ├── l2-to-l2-relayer.ts        # Relay L2->L2 interop messages
│   ├── data-encoding.ts           # Encode/decode L1/L2 data formats
│   ├── toml-handling.ts           # TOML file parsing
│   ├── contracts.ts               # ABI imports and contract definitions
│   ├── const.ts                   # System contract addresses
│   ├── types.ts                   # TypeScript interfaces
│   └── utils.ts                   # Helpers (ABI loading, asset ID encoding, relay)
├── test/hardhat/
│   ├── 01-deployment-verification.spec.ts
│   ├── 02-direct-bridge.spec.ts
│   ├── 03-interop-transfer.spec.ts
│   ├── 04-gateway-setup.spec.ts
│   ├── 05-gateway-bridge.spec.ts
│   └── 06-gateway-interop.spec.ts
└── outputs/                       # Deployment outputs (gitignored)
```

## Key Patterns

### Deposit Flow (ETH)

ETH deposits use `Bridgehub.requestL2TransactionTwoBridges` which routes through L1AssetRouter. This produces a self-finalizing priority request: L1AssetRouter.bridgehubDeposit generates L2 calldata containing `L2AssetRouter.finalizeDeposit(...)`. On Anvil, we relay this via `extractAndRelayNewPriorityRequests`:

- **Direct chains** (chain 10): relay L1 -> L2
- **GW-settled chains** (chain 12): relay L1 -> GW -> L2

### Anvil EVM vs ZKsync VM

On ZKsync VM, all functions can receive ETH value even if not marked `payable`. On Anvil (plain EVM), Solidity enforces the callvalue check. This affects:

- **ETH withdrawals**: `L2AssetRouter.withdraw()` is not payable, but the NTV requires `msg.value == amount` for base token. Solution: bypass L2AssetRouter and call `L2NTV.bridgeBurn` directly by impersonating L2AssetRouter.

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
