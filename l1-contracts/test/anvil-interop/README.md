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

## Limitations & Deviations from Production

### Not Supported

- **L1→L2 transaction failures / refundRecipient**: Priority requests always succeed on Anvil; failure + refund logic is untested
- **Batch settlement**: No real sequencer or prover; batches are never committed/proved/executed
- **Custom pubdata pricing**: Gas and pubdata costs use Anvil defaults, not ZKsync fee models
- **L1→GW→L2 relay via NewPriorityRequest on GW**: GW does not emit `NewPriorityRequest` during relay; the `relayChains` next-hop path in `extractAndRelayNewPriorityRequests` is not exercised

### Mock Contracts

| Mock | Address | Replaces | Difference |
|---|---|---|---|
| `MockL2ToL1Messenger` | `0x8008` | L2ToL1Messenger | Only emits `L1MessageSent`; no merkle tree |
| `MockL2MessageVerification` | `0x10009` | L2MessageVerification | All proof checks return `true` |
| `MockSystemContext` | `0x800b` | SystemContext | Minimal; no ZK-VM state |
| `MockMintBaseTokenHook` | `0x7100` | MINT_BASE_TOKEN_HOOK | No-op; L2BaseToken pre-funded via `anvil_setBalance` |
| `DummyL1MessageRoot` | L1 | L1MessageRoot | All proof verification returns `true` |

Real contracts used: `L2BaseTokenZKOS` at `0x800a`, all other L2 system contracts at their production addresses.

### L2 Deployment: `anvil_setCode` + Real Genesis Upgrade

Contracts are placed at hardcoded addresses via `anvil_setCode` (production has them in genesis state). The real genesis upgrade calldata from L1's `GenesisUpgrade` event is relayed to L2, initializing all contracts via `initL2()` with production-identical data.

### Impersonation

| What | Who | Production equivalent |
|---|---|---|
| Genesis upgrade relay | `L2_FORCE_DEPLOYER_ADDR` | Bootloader executes upgrade tx |
| Interop chain registration | `SERVICE_TX_SENDER_ADDR` | Service transactions from sequencer |
| GW chain registration | `ChainAssetHandler` | Governance flow |
| Settlement layer notification | `L2_BOOTLOADER_ADDR` | Bootloader at batch start |
| Governance calls | Governance contract | Multi-sig / timelock |
| GW L2Bridgehub ownership | Aliased CTM governance | Shared governance from deployment |

### Other Shortcuts

- **Fake GW diamond proxies**: Placeholder addresses via `anvil_setCode` for `getZKChain() != 0`
- **GW L2Bridgehub ownership transfer**: CTM deploys a per-chain Governance, but `fullRegistration` sends from ecosystem Governance. The test transfers ownership before relay.
- **Synthetic merkle proofs**: Encode settlement layer chain ID but contain no real cryptographic data
- **Interop proofs**: Correct struct shape but empty proof arrays

## Cleanup

```bash
# Full cleanup: kill chains, remove outputs, reset state
cd contracts/l1-contracts/test/anvil-interop
yarn cleanup
```
