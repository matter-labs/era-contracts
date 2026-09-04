# Multi-Chain Anvil Interop Tests

End-to-end tests for ZKsync interoperability across 6 Anvil chains: L1 contract deployment, L1<->L2 bridging (ETH + ERC20), L2<->L2 interop transfers, and gateway setup with chain migration.

## Chain Topology

```
┌──────────────┐
│  L1 (31337)  │  port 9545 — Bridgehub, CTM, L1AssetRouter, L1NTV
│  settlement  │
└──────┬───────┘
       │
       ├──► L2  (10)  port 4050 — settled directly on L1
       │
       ├──► GW  (11)  port 4051 — gateway chain (settled on L1, settlement layer for L2A/L2B/L2C)
       │     │
       │     ├──► L2A (12)  port 4052 — settled via GW
       │     ├──► L2B (13)  port 4053 — settled via GW
       │     └──► L2C (14)  port 4054 — custom-base-token chain settled via GW
       │
       └──► (L2A, L2B, and L2C also registered on L1 but migrated to GW)
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

Tests load pregenerated Anvil snapshots from `chain-states/v0.34.0/` by default (the current protocol version, configured as `stateVersion` in `config/anvil-config.json`). This skips the full deployment and cuts test time from ~5 min to ~85s.

The runner auto-detects pregenerated state by checking for `chain-states/<protocol-version>/addresses.json`. If found, it gunzips each `<chainId>.json.gz` dump and starts each Anvil process with `--load-state`. If not found (or `ANVIL_INTEROP_FRESH_DEPLOY=1`), it runs the full deployment.

Only the directory for the current protocol version, selected by `stateVersion`, is regenerated. Upgrade scenarios select their frozen source fixture explicitly; those fixtures must not be regenerated from current contracts.

The per-chain state dumps are committed **gzip-compressed** (`<chainId>.json.gz`). These snapshots are multi-MB; storing them as raw JSON floods every regeneration with an enormous, unreviewable diff. GitHub renders `.gz` as binary ("Binary file not shown"), keeping them out of PR diffs, and gzip shrinks them ~10x. `addresses.json` stays plain text so contract-address changes remain reviewable. Compression/decompression is handled automatically by `dumpAllStates()` / `loadChainStates()` in `deployment-runner.ts` — no manual step.

To regenerate pregenerated state after contract changes:

```bash
cd contracts/l1-contracts/test/anvil-interop
yarn setup-and-dump
```

This runs the full deployment with pinned settings (`blockTime=1`, `timestamp=1`) and dumps each chain's state to the `chain-states/` directory. Interval mining makes the final block height and block-indexed state wall-clock-dependent, so the CI determinism check uses `compare-chain-states.ts` to normalize the documented drift and requires every non-normalized field to match.

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

## Live Interop State

`ANVIL_INTEROP_LIVE=1` skips Anvil setup and cleanup, writes the normal test manifest at `outputs/live-state/chains.json`
from live RPCs and env, and runs specs `07`, `08`, and `09` by default. This file is not simulated chain state; it is
the small manifest the existing specs load for RPC URLs, chain roles, and token addresses. The live setup
deploys a fresh L1 `TestnetERC20Token`, mints it to `LIVE_SOURCE_PRIVATE_KEY`, deposits it to Chain A through the
`@matterlabs/zksync-js` viem adapter, and records the resulting L2 token address. Specs derive the token asset ID from
`L2NativeTokenVault` at execution time.

```bash
cd contracts/l1-contracts

ANVIL_INTEROP_LIVE=1 \
LIVE_L1_RPC=<l1-rpc> \
LIVE_GW_RPC=<gateway-rpc> \
LIVE_CHAIN_A_RPC=<source-chain-rpc> \
LIVE_CHAIN_B_RPC=<destination-chain-rpc> \
LIVE_SOURCE_PRIVATE_KEY=<sender-private-key> \
LIVE_UNBUNDLER_PRIVATE_KEY=<unbundler-private-key> \
yarn test:hardhat:interop
```

Fixed-ZK-fee test coverage discovers the ZK token asset ID from `InteropCenter.ZK_TOKEN_ASSET_ID()` on the source
chain. If the ZK token has not been bridged there yet, or if the sender's ZK balance is zero, fixed-ZK-fee cases are
skipped with a warning.

Live environment variables:

| Variable                           | Default / Effect                                                             |
| ---------------------------------- | ---------------------------------------------------------------------------- |
| `LIVE_L1_RPC`                      | Required L1 RPC for token deployment and L1->L2 deposits                     |
| `LIVE_GW_RPC`                      | Required Gateway RPC; chain ID is discovered from this RPC                   |
| `LIVE_CHAIN_A_RPC`                 | Required source-chain RPC; chain ID is discovered from this RPC              |
| `LIVE_CHAIN_B_RPC`                 | Required destination-chain RPC; chain ID is discovered from this RPC         |
| `LIVE_SOURCE_PRIVATE_KEY`          | Required source signer for setup and specs                                   |
| `LIVE_UNBUNDLER_PRIVATE_KEY`       | Required alternative signer, must be distinct from `LIVE_SOURCE_PRIVATE_KEY` |
| `LIVE_RECIPIENT_ADDRESS`           | Optional token recipient; defaults to `LIVE_SOURCE_PRIVATE_KEY` wallet       |
| `LIVE_SECONDARY_RECIPIENT_ADDRESS` | Optional second token recipient; defaults to unbundler wallet                |
| `LIVE_TEST_TOKEN_NAME`             | `Live Interop Test Token`                                                    |
| `LIVE_TEST_TOKEN_SYMBOL`           | `LIT`                                                                        |
| `LIVE_TEST_TOKEN_AMOUNT`           | `1000`, with 18 decimals                                                     |

## Test Specs

| Spec                         | What it tests                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `01-deployment-verification` | L1 contracts deployed, CTM registered, all 4 L2 chains have diamond proxies, L2 system contracts present, test tokens deployed, initial chainBalance is zero |
| `02-direct-bridge`           | L1->L2 ETH deposit + L2->L1 ETH withdrawal on chain 10 (direct L1 settlement), net flow assertions                                                           |
| `03-interop-transfer`        | Unsupported interop routes revert; only GW-settled L2<->GW-settled L2 interop is intentionally registered                                                    |
| `04-gateway-setup`           | GW chain contracts deployed, interop chains registered on GW L2Bridgehub, GW designated as settlement layer on L1                                            |
| `05-gateway-bridge`          | L1->L2A ETH deposit + L2A->L1 ETH withdrawal on chain 12 (via GW)                                                                                            |
| `06-gateway-interop`         | L2A<->L2B interop transfers between GW-settled L2 chains                                                                                                     |

## Coverage

`run-coverage.ts` runs the specs against Anvil chains started with `--steps-tracing`, then
replays the collected traces through the Forge source maps to produce an LCOV report.

```bash
# From this directory — shard the specs across parallel workers (default)
yarn coverage

# Single process, one set of chains, all specs (the pre-sharding behavior)
yarn coverage:serial

# One spec only (a single spec has nothing to shard, so this runs in one process)
yarn ts-node run-coverage.ts --spec test/anvil-interop/test/hardhat/07-interop-bundles.spec.ts

# Several named specs — still sharded, one worker each. Add --serial to keep them in one process
# against a single set of chains.
yarn ts-node run-coverage.ts --spec .../07-interop-bundles.spec.ts --spec .../09-interop-unbundle.spec.ts
```

Sharding is also skipped when there are no pre-generated chain states, because each worker would
otherwise run its own full deployment concurrently, racing on the shared `config/permanent-values.toml`
and `broadcast/` directories. The run says so when it falls back.

Each shard is a child process that owns its own six Anvil chains (own port offset, own run
suffix, own state dir), runs its slice of the specs, and collects coverage from its own chains
into `l1-contracts/coverage/anvil/shards/p<offset>/`. The parent then unions the per-shard
reports into `l1-contracts/coverage/anvil/anvil-lcov.info`, which is what
`yarn l1 coverage:merge` reads when combining Anvil hits with the Foundry report.

Shards resolve only the contracts their own specs touched, so their file and line sets differ;
the union takes the max hit count per line and per function. Denominators do not matter here —
`scripts/merge-coverage.ts` rebases everything onto the Foundry LCOV. The union itself is
covered by `test/unit/lcov-merge.test.ts`. `yarn test:unit` runs every suite under `test/unit/`
(48 cases, ~4s), and takes a substring to narrow it: `yarn test:unit trace` runs only the trace
guard. CI runs the whole set in the jobs that depend on it.

Two coverage runs can coexist: pass `--port-offset N` or export `ANVIL_INTEROP_PORT_OFFSET=N`
(the flag wins) and both the Anvil ports and the output paths move with it — shard reports go to
`coverage/anvil/shards-pN/`, the merged report to `coverage/anvil/anvil-lcov-pN.info`, single-process
output to `coverage/anvil/run-pN/`, and `--html` to `coverage/anvil/html-pN/`, so one run cannot
delete the other's. Offset 0 keeps the unsuffixed paths that CI and `yarn l1 coverage:merge` expect.

**Valid offsets are 0, 1000, 2000, …** — whole multiples of 1000. A run reserves 1000 ports (up to
ten shards, 100 apart), so bases closer than that overlap: a run at 500 would allocate the same
ports as shards 6 to 10 of a run at 0, and the later run's `startChain` kills the earlier run's
Anvil processes. Anything else is rejected with a message naming the valid values.

Tracing multiplies Anvil's memory and CPU cost, so cap the concurrency on small machines with
`ANVIL_INTEROP_MAX_PARALLEL_WORKERS`. If coverage runs start failing with RPC errors mid-spec,
lower it before looking anywhere else.

CI splits the specs across a small number of runners and shards in-process within each. A
runner costs the same whether it uses one core or four, so parallelism inside a job is free
while extra jobs are not — measured, one-spec-per-runner spent ~43 runner-minutes to reach
~7.0m wall clock, two groups reach ~7.5m for ~14. The groups are listed by hand in the
`coverage-anvil` matrix; `coverage-report` fails if the specs the groups report having run are
not exactly the specs on disk, so a spec left out of the matrix cannot pass unnoticed.

`l1-contracts-ci.yaml` then runs a `coverage-anvil` matrix job per group, each uploading its
`anvil-lcov.info`. The `coverage-report` job downloads them and unions them with
`yarn merge:shards <dir>` (`merge-shard-lcov.ts`), which walks the directory for
`anvil-lcov.info` files and fails if it finds none — a group that produced nothing must not
pass as "these specs added no coverage". Both union paths use the same `lcov-merge.ts`.

## Environment Variables

| Variable                               | Effect                                                                  |
| -------------------------------------- | ----------------------------------------------------------------------- |
| `ANVIL_INTEROP_SKIP_SETUP=1`           | Skip deployment, run only tests (requires chains already running)       |
| `ANVIL_INTEROP_SKIP_CLEANUP=1`         | Don't kill Anvil processes after tests                                  |
| `ANVIL_INTEROP_KEEP_CHAINS=1`          | Same as `--keep-chains` flag                                            |
| `ANVIL_INTEROP_FRESH_DEPLOY=1`         | Force full deployment even if pregenerated state exists                 |
| `ANVIL_INTEROP_PORT_OFFSET=N`          | Offset all chain ports by N (useful for parallel runs)                  |
| `ANVIL_INTEROP_RUN_SUFFIX=X`           | Suffix for output dirs (set automatically by parallel workers)          |
| `ANVIL_INTEROP_MAX_PARALLEL_WORKERS=N` | Cap concurrent test/coverage workers (0 or unset = one per spec)        |
| `ANVIL_COVERAGE_MODE=1`                | Start Anvil with `--steps-tracing` so traces can be collected afterward |

### CLI Parameters

| Parameter           | Effect                                                                                                                                                      |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--spec <file>`     | Run only the specified spec file(s). Can be repeated (e.g., `--spec 02-direct-bridge.spec.ts --spec 05-gateway-bridge.spec.ts`). Disables parallel workers. |
| `--port-offset <N>` | Offset all chain ports by N (equivalent to `ANVIL_INTEROP_PORT_OFFSET`). Useful for avoiding conflicts with other Anvil instances.                          |
| `--keep-chains`     | Keep Anvil processes running after tests finish (equivalent to `ANVIL_INTEROP_KEEP_CHAINS=1`). Disables parallel workers.                                   |

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
├── run-v31-to-v32-upgrade-test.ts # V31 → V32 upgrade test
├── cleanup.sh                     # Kill Anvil processes, reset state
├── config/
│   ├── anvil-config.json          # Chain IDs, ports, gateway designation
│   ├── l1-deployment.toml         # L1 contract deployment params
│   ├── ctm-deployment.toml        # ChainTypeManager params
│   ├── permanent-values.toml      # Immutable protocol values
│   └── chain-{10,11,12,13,14}.toml # Per-chain deployment params (generated)
├── chain-states/
│   └── v0.34.0/                   # Pregenerated Anvil state snapshots (current, regenerated)
│       ├── 31337.json.gz          # L1 state dump (gzip; kept out of diffs)
│       ├── {10,11,12,13,14}.json.gz # L2 chain state dumps (gzip)
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
│       ├── bridged-out-helper.ts            # Read L1NativeTokenVault.bridgedOut in bridge tests
│       └── deploy-test-token.ts             # Deploy ERC20 test tokens to L2 chains
├── test/hardhat/
│   ├── 01-deployment-verification.spec.ts
│   ├── 02-direct-bridge.spec.ts
│   ├── 03-interop-transfer.spec.ts
│   ├── 04-gateway-setup.spec.ts
│   ├── 05-gateway-bridge.spec.ts
│   └── 06-gateway-interop.spec.ts
└── outputs/                       # Deployment outputs (gitignored)
```

## Limitations & Deviations from Production

### Not Supported

- **L1→L2 transaction failures / refundRecipient**: Priority requests always succeed on Anvil; failure + refund logic is untested
- **Batch settlement**: No real sequencer or prover; batches are never committed/proved/executed
- **Custom pubdata pricing**: Gas and pubdata costs use Anvil defaults, not ZKsync fee models
- **Non-ETH base tokens**: All chains use ETH as the base token
- **Validium mode**: All chains run as rollup (validium carries no meaning without batch settlement)
- **Settlement fees**: `processLogsAndMessages` still uses a zero settlement fee payer; interop sends cover non-zero dynamic base-token fees and fixed ZK fees separately

### Mock Contracts

Source of truth for the Anvil predeploy layout lives in
`src/core/predeploys.ts` via `PREDEPLOY_SYSTEM_CONTRACTS`.

| Mock                        | Address   | Replaces              | Difference                                           |
| --------------------------- | --------- | --------------------- | ---------------------------------------------------- |
| `MockL2MessageVerification` | `0x10009` | L2MessageVerification | All proof checks return `true`                       |
| `MockL1MessengerHook`       | `0x7001`  | L1_MESSENGER_HOOK     | No-op; real L1MessengerZKOS still emits events       |
| `MockMintBaseTokenHook`     | `0x7100`  | MINT_BASE_TOKEN_HOOK  | No-op; L2BaseToken pre-funded via `anvil_setBalance` |
| `DummyL1MessageRoot`        | L1        | L1MessageRoot         | All proof verification returns `true`                |

Real contracts used: `SystemContext` at `0x800b`, `L1MessengerZKOS` at `0x8008`, `L2BaseTokenZKOS` at `0x800a`, all other L2 system contracts at their production addresses.

### L2 Deployment: Synthetic Prestate + Real Genesis Upgrade

Contracts are first bootstrapped at hardcoded addresses via `anvil_setCode` and the base token is pre-funded via `anvil_setBalance` (production has this in genesis state). The real genesis upgrade calldata from L1's `GenesisUpgrade` event is then relayed to L2, initializing all contracts via `initL2()` with production-identical data.

### Impersonation

| What                          | Who                      | Production equivalent                 |
| ----------------------------- | ------------------------ | ------------------------------------- |
| Genesis upgrade relay         | `L2_FORCE_DEPLOYER_ADDR` | Bootloader executes upgrade tx        |
| Interop chain registration    | Default Anvil EOA        | Real L1 service-tx flow relayed to L2 |
| GW chain registration         | `ChainAssetHandler`      | Governance flow                       |
| Settlement layer notification | `L2_BOOTLOADER_ADDR`     | Bootloader at batch start             |
| Governance calls              | Governance contract      | Multi-sig / timelock                  |
| GW L2Bridgehub ownership      | Aliased CTM governance   | Shared governance from deployment     |

### Other Shortcuts

- **GW L2Bridgehub ownership transfer**: CTM deploys a per-chain Governance, but `fullRegistration` sends from ecosystem Governance. The test transfers ownership before relay.
- **Interop registration scope**: the harness only intentionally registers GW-settled L2 chains for interop. Routes involving the gateway chain or a direct-settled chain revert in the harness.
- **L2 genesis deployment via anvil_setCode**: System contracts are bootstrapped at hardcoded addresses, not via real genesis state. Production chains get that state directly from genesis.
- **Synthetic merkle proofs**: Encode settlement layer chain ID but contain no real cryptographic data
- **Interop proofs**: Correct struct shape but empty proof arrays
- **processLogsAndMessages impersonation**: The diamond proxy is impersonated instead of the operator (production uses the operator role)
- **Settlement layer notification via impersonation**: `SystemContext.setSettlementLayerChainId` is called by impersonating the bootloader. On ZKsync OS, this is only emitted during actual migration between settlement layers (and during genesis/v31 upgrades), not at every batch
- **v31 -> v32 upgrade harness**: `run-v31-to-v32-upgrade-test.ts` still applies two direct `anvil_setStorageAt` patches. Before governance it clears the genesis-upgrade tx hash the fixture's chains still carry, which a real chain's server clears once it processes the batch and which otherwise blocks a new upgrade with `PreviousUpgradeNotFinalized`. Before each per-chain upgrade, `forceBatchExecutedEqualsCommitted` copies `totalBatchesCommitted` onto `totalBatchesExecuted` so the upgrade's outstanding-batches check passes without a sequencer and prover. Both are test-only compatibility bridges, not a production upgrade flow.
- **L2 genesis bootstrap**: `l2-genesis-upgrade-deployer.ts` still bootstraps contract code and base-token balance via Anvil RPC before relaying the real genesis transaction. Production chains get that state directly from genesis.
- **Temporary upgrade inputs**: the upgrade harness copies the scenario's config inputs into `test/anvil-interop/outputs/upgrade-harness-inputs-<scenario label>/` and passes them to Forge via env overrides. It no longer mutates checked-in `upgrade-envs/.../local.toml`.

## Adding New Tests

Test specs are auto-discovered from `test/hardhat/` — any file matching `NN-*.spec.ts` is included automatically. To add a new test:

1. Create a new spec file in `test/hardhat/` (e.g., `07-my-test.spec.ts`)
2. The spec can load deployment state via `new DeploymentRunner().loadState()`

No need to register the file anywhere — it's picked up by the naming convention.

### Adding a New Chain

1. Add the chain entry to `config/anvil-config.json` (chain ID, port, role, settlement)
2. Add a chain config TOML in `config/` if needed (e.g., `chain-<id>.toml`)
3. Regenerate chain states with `yarn setup-and-dump`

Note: `cleanup.sh` reads ports from `anvil-config.json` automatically — no manual port list update needed.

## Cleanup

```bash
# Full cleanup: kill chains, remove outputs, reset state
cd contracts/l1-contracts/test/anvil-interop
yarn cleanup
```
