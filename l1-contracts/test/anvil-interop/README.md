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
# From contracts/l1-contracts/ — run all tests with pregenerated state (~85s)
cd contracts/l1-contracts
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
  yarn hardhat test test/anvil-interop/test/hardhat/0*.spec.ts \
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
├── run-v29-to-v31-upgrade-test.ts # V29 → V31 upgrade test
├── cleanup.sh                     # Kill Anvil processes, reset state
├── config/
│   ├── anvil-config.json          # Chain IDs, ports, gateway designation
│   ├── l1-deployment.toml         # L1 contract deployment params
│   ├── ctm-deployment.toml        # ChainTypeManager params
│   ├── permanent-values.toml      # Immutable protocol values
│   └── chain-{10,11,12,13}.toml   # Per-chain deployment params (generated)
├── chain-states/
│   └── v0.31.0/                   # Pregenerated Anvil state snapshots
│       ├── 31337.json             # L1 state dump
│       ├── {10,11,12,13}.json     # L2 chain state dumps
│       └── addresses.json         # All contract addresses + test tokens
├── src/
│   ├── deployment-runner.ts       # Orchestrates all deployment steps
│   ├── core/
│   │   ├── const.ts               # System contract addresses, chain IDs
│   │   ├── types.ts               # TypeScript interfaces
│   │   ├── contracts.ts           # ABI loading from compiled artifacts
│   │   ├── utils.ts               # Helpers (relay, merkle proofs, ABI loading)
│   │   ├── data-encoding.ts       # Encode/decode L1/L2 data formats
│   │   ├── forge.ts               # Forge command wrapper
│   │   └── toml-handling.ts       # TOML file parsing/merging
│   ├── deployers/
│   │   ├── deployer.ts            # L1 contract deployment via forge scripts
│   │   ├── chain-registry.ts      # Register L2 chains on L1 CTM + capture genesis priority txs
│   │   ├── system-contracts-deployer.ts    # L2 system contracts via anvil_setCode (legacy path)
│   │   ├── l2-genesis-upgrade-deployer.ts  # Pre-deploy mocks + relay real genesis priority tx
│   │   ├── gateway-setup.ts       # Gateway designation + chain migration
│   │   └── gateway-deployer.ts    # Verify GW system contracts
│   ├── daemons/
│   │   └── anvil-manager.ts       # Start/stop Anvil processes
│   └── helpers/
│       ├── l1-deposit-helper.ts   # L1->L2 ETH/ERC20 deposits
│       ├── l2-withdrawal-helper.ts          # L2->L1 ETH/ERC20 withdrawals
│       ├── token-transfer.ts                # L2<->L2 interop token transfers
│       ├── token-balance-migration-helper.ts # Token balance migration (L2->L1->GW)
│       ├── process-logs-helper.ts           # Build/process withdrawal logs on GW
│       ├── balance-tracker.ts               # L1AssetTracker balance snapshots
│       └── deploy-test-token.ts             # Deploy ERC20 test tokens to L2 chains
├── test/hardhat/
│   ├── 01-deployment-verification.spec.ts
│   ├── 02-direct-bridge.spec.ts
│   ├── 03-interop-transfer.spec.ts
│   ├── 04-gateway-setup.spec.ts
│   ├── 05-gateway-bridge.spec.ts
│   ├── 06-gateway-interop.spec.ts
│   └── token-transfer.spec.ts
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

L1 withdrawal finalization normally requires batch proofs. For Anvil testing, a `DummyL1MessageRoot` is deployed that bypasses proof verification (always returns true). Withdrawals are finalized by calling `L1Nullifier.finalizeDeposit` directly with a synthetic merkle proof that encodes the settlement layer chain ID.

### Data Encoding

L1 `bridgeMint` expects `DataEncoding.encodeBridgeMintData` format: `(address originalCaller, address receiver, address originToken, uint256 amount, bytes metadata)`. This is different from the L2 burn data format `(uint256 amount, address receiver, address token)`.

## Known Deviations from Production

Anvil runs standard EVM, not ZKsync VM. The test environment uses mocks and impersonation to bridge the gap. This section documents all places where the test setup diverges from production behavior.

### Mock System Contracts

L2 system contracts are ZK-VM bytecode and cannot run on Anvil. The following mocks replace them:

| Mock Contract | Address | What it replaces | Key difference |
|---|---|---|---|
| `MockL2ToL1Messenger` | `0x8008` | L2ToL1Messenger | Only emits `L1MessageSent` event; no merkle tree or proof construction |
| `MockL2MessageVerification` | `0x10009` | L2MessageVerification | All proof verification functions return `true` unconditionally |
| `MockSystemContext` | `0x800b` | SystemContext | Minimal implementation without ZK-VM state tracking |
| `MockMintBaseTokenHook` | `0x7100` | MINT_BASE_TOKEN_HOOK | Returns success without minting; L2BaseToken is pre-funded via `anvil_setBalance` |

Note: The real `L2BaseTokenZKOS` contract is used at `0x800a` — the old `MockL2BaseToken` is no longer needed since the burner pattern was removed.

### Proof Verification Bypass

- **`DummyL1MessageRoot`** replaces `L1MessageRoot` on L1. All proof verification functions return `true`.
- **Synthetic merkle proofs** are constructed by `buildWithdrawalMerkleProof()` — they encode the settlement layer chain ID in the correct format for `getProofData()` to parse, but contain no real cryptographic data.
- **Interop proofs** (`buildMockInteropProof()`) have the correct struct shape but empty proof arrays.

### L2 Contract Deployment via `anvil_setCode` + Real Genesis Upgrade

System contracts are placed at their hardcoded addresses using `anvil_setCode` before the genesis upgrade runs. This is necessary because `isZKsyncOS=true` skips force deployments in `L2GenesisForceDeploymentsHelper` — in production, these contracts exist in the genesis state. After pre-deployment, the real genesis upgrade priority transaction from L1 is relayed to L2, executing the same `L2GenesisUpgrade.genesisUpgrade()` calldata that the L1 `ChainTypeManager.createNewChain()` generated. This initializes all contracts via their `initL2()` methods using production-identical data.

### Interop Chain Registration Shortcut

`registerChainForInterop()` registers chains on L2Bridgehub by impersonating `SERVICE_TX_SENDER_ADDR`. In production, chain registration goes through the full governance flow with proper authorization. This means the test does not cover the real registration path.

### L1→L2 Priority Request Relay

Instead of a real sequencer, `extractAndRelayNewPriorityRequests()` parses `NewPriorityRequest` events from L1 receipts and replays them on L2 by impersonating the original sender. For GW-settled chains, this chains L1 → GW → L2.

### Impersonation-Based Flows

Several flows use `anvil_impersonateAccount` instead of real authorization:

| What | Who is impersonated | Production equivalent |
|---|---|---|
| L2 genesis upgrade | `L2_FORCE_DEPLOYER_ADDR` | Bootloader executes upgrade transactions |
| L2 contract init | `SERVICE_TX_SENDER_ADDR` | Service transactions from sequencer |
| GW chain registration | `ChainAssetHandler` address | Governance authorization flow |
| Settlement layer notification | `L2_BOOTLOADER_ADDR` | Bootloader sets this at batch start |
| ETH withdrawals on L2 | `L2_ASSET_ROUTER_ADDR` | ZKsync VM allows non-payable functions to receive ETH |
| Governance calls | Governance contract address | Multi-sig / timelock flows |

### Gateway Setup Shortcuts

- **Fake diamond proxies**: Deterministic placeholder addresses are deployed on GW via `anvil_setCode` so that `L2Bridgehub.getZKChain(chainId)` returns non-zero. Production uses real diamond proxy deployments.
- **Ownership transfers**: Uses `anvil_impersonateAccount` on Governance to accept 2-step ownership transfers instantly.

## Cleanup

```bash
# Full cleanup: kill chains, remove outputs, reset state
cd contracts/l1-contracts/test/anvil-interop
yarn cleanup
```
