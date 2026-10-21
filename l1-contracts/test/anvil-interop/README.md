# Multi-Chain Anvil Interop Tests

End-to-end tests for ZKsync interoperability across 6 Anvil chains: L1 contract deployment, L1<->L2 bridging (ETH + ERC20), L2<->L2 interop between L1-settled chains, and gateway setup with chain migration.

## Chain Topology

```
┌──────────────┐
│  L1 (31337)  │  port 9545 — Bridgehub, CTM, L1AssetRouter, L1NTV
│  settlement  │
└──────┬───────┘
       │
       ├──► L2  (10)  port 4050 — settled on L1, interop
       ├──► L2  (12)  port 4052 — settled on L1, interop
       ├──► L2  (14)  port 4054 — custom-base-token chain settled on L1, interop
       │
       └──► GW  (11)  port 4051 — gateway chain (settled on L1, settlement layer for chain 13)
             │
             └──► L2  (13)  port 4053 — registered on L1, migrated to GW
```

Setup enables interop for the chains marked `interop` in `config/anvil-config.json` and allows each of them as an
interop peer of the others, following {protocol-docs/interop-gating.md#order-per-chain}. Interop is tested between
those chains only; the GW-settled chain covers deposits and withdrawals through the gateway.

## Quick Start

```bash
# From the repository root — run all tests with pregenerated state (~85s)
cd l1-contracts
yarn test:hardhat:interop

# Force full deployment from scratch (~5 min)
ANVIL_INTEROP_FRESH_DEPLOY=1 yarn test:hardhat:interop

# Keep chains running after tests finish
yarn test:hardhat:interop --keep-chains
```

## Pregenerated Chain States

Tests load pregenerated Anvil snapshots from `chain-states/<stateVersion>/` by default (the current snapshot version, `v0.35.0`, configured as `stateVersion` in `config/anvil-config.json`; the frozen upgrade-test fixtures are described in `chain-states/README.md`). This skips the full deployment and cuts test time from ~5 min to ~85s.

The runner auto-detects pregenerated state by checking for `chain-states/<state-version>/addresses.json`. If found, it gunzips each `<chainId>.json.gz` dump and starts each Anvil process with `--load-state`. If not found (or `ANVIL_INTEROP_FRESH_DEPLOY=1`), it runs the full deployment.

Only the current snapshot directory, selected by `stateVersion`, is regenerated. Upgrade scenarios select their frozen source fixture explicitly; those fixtures must not be regenerated from current contracts.

The per-chain state dumps are committed **gzip-compressed** (`<chainId>.json.gz`). These snapshots are multi-MB; storing them as raw JSON floods every regeneration with an enormous, unreviewable diff. GitHub renders `.gz` as binary ("Binary file not shown"), keeping them out of PR diffs, and gzip shrinks them ~10x. `addresses.json` stays plain text so contract-address changes remain reviewable. Compression/decompression is handled automatically by `dumpAllStates()` / `loadChainStates()` in `deployment-runner.ts` — no manual step.

To regenerate pregenerated state after contract changes, first finalize `configs/genesis/zksync-os/latest.json` from the production build, then build the `anvil-interop` profile and generate the snapshots. The genesis root is part of CTM deployment data; changing it afterward invalidates the snapshot addresses.

```bash
cd l1-contracts/test/anvil-interop
yarn setup-and-dump
```

This runs the full deployment with pinned settings (`blockTime=1`, `timestamp=1`) and dumps each chain's state to the `chain-states/` directory. Interval mining makes the final block height and block-indexed state wall-clock-dependent, so the CI determinism check uses `compare-chain-states.ts` to normalize the documented drift and requires every non-normalized field to match.

Spec `01` compares all predeploy runtimes byte-for-byte against a reference chosen by how the chains
were started, which the run records in its deployment state, so reruns against kept chains use the
same one. On loaded snapshots the reference is the current sources built with the `anvil-interop`
Foundry profile the snapshots use, so a stale snapshot fails: its setup builds those artifacts in
`outputs/predeploy-identity<run-suffix>/`, leaving the default artifacts used by coverage intact. A
cold identity build adds compilation time; reruns reuse that separate cache. A fresh deployment
(`ANVIL_INTEROP_FRESH_DEPLOY=1`, `run-coverage.ts --fresh-deploy`, or no snapshots for the state
version) installs the predeploys from `out/`, whatever profile built it, so the spec compares
against those artifacts and skips the reference build.

## Upgrade Tests

```bash
cd l1-contracts/test/anvil-interop
yarn test:upgrade             # the v35 bootstrap via protocol-ops on the frozen v0.34.0 states, then two registry-driven hops
yarn test:upgrade-recurring   # the recurring registry-driven hop on the current-genesis states
```

`yarn test:upgrade` reviews each package the way governance would before replaying it:
`protocol-ops ecosystem verify-package` against the live anvil L1, with `--env local`, the
fixture's Bridgehub as `--expected-bridgehub` (`local` names another ecosystem's), the fixture's
governance as `--expected-governance-owner` and, for the hops, the bootstrap package as
`--executor-record`. It holds the deployments against the hashes of the build it deployed from
(`scripts/calculate-hashes.ts --output`, passed as `--contract-hashes`), because the committed
`AllContractsHashes.json` is regenerated last. Beyond a report without errors, the harness requires
every construction record the package carries to be consulted (each deployment of these prepares is
a member the package installs) and, for the bootstrap, the freeze-authority check. Every prepare
deploys under a salt of its own, as production rotates its salt per release, so the recurring hop's
`L1MessageRoot` row really applies.

The pipeline caps each replayed L1 prepare/governance transaction at EIP-7825's 16,777,216 gas
limit and logs its phase, bundle, index, target, hash and gas usage. Per-chain L1 upgrade calls
are checked and logged too. These calls impersonate the bundle signer: the measurements exclude
the outer Safe/governance envelope.

`L1_GAS_RULES=amsterdam` runs the same test under Glamsterdam's gas schedule, as CI's
`upgrade-test-glamsterdam` job does. It needs `ANVIL_AMSTERDAM_BIN`, the anvil pinned in
`.github/amsterdam-anvil.env`:

```bash
ANVIL_AMSTERDAM_BIN="$(scripts/install-amsterdam-anvil.sh "$HOME/.cache/anvil-amsterdam")" \
  ANVIL_BIN="$HOME/.foundry/versions/v1.5.1/anvil" L1_GAS_RULES=amsterdam yarn test:upgrade
```

The L1 then runs `--hardfork amsterdam` at mainnet's 60M block gas limit, loaded from a copy of the
fixture without its block history, which that build cannot parse. The L2s keep `ANVIL_BIN`;
protocol-ops' forks use the `anvil` on `PATH` (v1.5.1 in CI). A canary first fails the run unless
the binary's estimates for a few probe transactions match EIP-2780, EIP-7976, EIP-8037 and EIP-8038.
EIP-8037 state gas lets a deploy's `tx.gas` exceed 2^24, so each L1 transaction declares its estimate.

Anvil runs one gas pool where Glamsterdam splits execution gas from a state gas reservoir, so every
recorded transaction is read back from the node (prestate diff, refund counter, call tree) and
logged with its state, execution, intrinsic and floor gas and its call depth. The run fails when the
larger of intrinsic and floor gas exceeds 2^24, or when the execution gas does not fit what
Glamsterdam guarantees the transaction's deepest frame: 2^24 less the intrinsic gas, less a 64th per
call level, as if all of it ran there. When `floorBinding` is set, the receipt reports the calldata
floor, so the logged execution gas is only an upper bound.

A fresh deployment is born into the registry-driven model: `DeployL1CoreContracts` gives the
ecosystem ProxyAdmin to the `CoreUpgradeExecutor`, and `DeployCTM` gives the CTM, its own ProxyAdmin and
the ServerNotifier to the `CTMUpgradeExecutor`. Governance is only nominated on the two executors, and
the deployment never accepts, so they stay owned by the deployer; anything needing the CTM,
ServerNotifier or a ProxyAdmin owner must go through that executor's `forward`.
`run-recurring-upgrade-test.ts` finds each executor through the custody it holds (the CTM's owner, the
ecosystem ProxyAdmin's owner), has governance accept both nominations, and drives the hop, with no
bootstrap, as one `Governance` bundle of the ordered legs `applyL1Upgrade` -> `applyCTMUpgrade`
(`applyInfrastructureUpgrade` between them when a CTM-domain proxy changes); a bundle whose last leg
fails must first roll back completely. (`yarn test:upgrade`'s hops hold the merged package to the same
contiguous leg run and assert that one transaction emitted every leg's domain event, in order.)
The recurring runner builds its objects from the committed manifest `scripts/registry-manifests/v35-local.json`
and fails on any drift; `yarn regen:registry-manifest` (`REGEN_REGISTRIES=1`) rewrites it from the live deployment.
`ANVIL_INTEROP_FRESH_DEPLOY=1` runs it against a fresh deployment instead of the chain states. The
committed manifest describes the chain states, which are built with the `anvil-interop` profile, so a
fresh deployment from the default build only matches in emit mode — restore the manifest afterwards.

## Running Tests Without Redeployment

After running once with `--keep-chains`, the Anvil chains and deployment state persist. Re-run just the hardhat tests:

```bash
# Run all test specs (no redeployment)
cd l1-contracts
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

## Live Interop State

`ANVIL_INTEROP_LIVE=1` skips Anvil setup and cleanup, writes the normal test manifest at `outputs/live-state/chains.json`
from live RPCs and env, and runs specs `07`, `08`, and `09` by default. This file is not simulated chain state; it is
the small manifest the existing specs load for RPC URLs, chain roles, and token addresses. The live setup
deploys a fresh L1 `TestnetERC20Token`, mints it to `LIVE_SOURCE_PRIVATE_KEY`, deposits it to Chain A through the
`@matterlabs/zksync-js` viem adapter, and records the resulting L2 token address. Specs derive the token asset ID from
`L2NativeTokenVault` at execution time.

```bash
cd l1-contracts

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

| Spec                         | What it tests                                                                                                                                                                                                                  |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `01-deployment-verification` | L1 core contracts wired together, CTM registered, all 5 L2 chains registered on L1 with chain ID + CTM, interop enabled and peers allowed for exactly the interop chains, exact predeploy runtimes, test token decimals/supply |
| `02-direct-bridge`           | L1->L2 ETH deposit + L2->L1 ETH withdrawal, and an L1-native ERC20 round trip, on chain 10 (direct L1 settlement), net flow assertions                                                                                         |
| `03-interop-transfer`        | Interop transfers between the interop chains; routes involving a chain without interop revert                                                                                                                                  |
| `04-gateway-setup`           | GW chain contracts deployed, the GW-settled chain registered on GW L2Bridgehub, GW designated as settlement layer on L1                                                                                                        |
| `05-gateway-bridge`          | L1->L2 ETH deposit + L2->L1 ETH withdrawal on chain 13 (via GW)                                                                                                                                                                |
| `07-interop-bundles`         | Direct, indirect, and mixed bundles; fees, replay protection, and execution-address checks                                                                                                                                     |
| `08-interop-messages`        | Base-token and ERC20 messages across ETH and custom-base-token chains                                                                                                                                                          |
| `09-interop-unbundle`        | Bundle verification and recovery of calls that cannot execute                                                                                                                                                                  |
| `13-imt-atomic-swap`         | IMT-backed atomic swaps, timeout refunds, and invalid-flow rejection                                                                                                                                                           |
| `14-interop-fee-units`       | Interop fee units: L2->L2 calls counted on the source only, withdrawals never; L1 fee manager ships off, prepaid balance round trip                                                                                            |
| `15-interop-peer-whitelist`  | Governance removes an allowed peer from one side: that chain can't send to the peer and its receive filter rejects the peer's bundle; once the admin allows the peer again, both directions work and the held bundle executes  |
| `16-interop-suspension`      | Governance suspends a chain on L1: once its peer reads L1 at a newer anchor, transfers to it, sends from it and its pending bundle are refused; resuming restores the pair and the held bundle executes                        |

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
(a few seconds), and takes a substring to narrow it: `yarn test:unit trace` runs only the trace
guard. CI runs the whole set in the jobs that depend on it.

Two coverage runs can coexist: pass `--port-offset N` or export `ANVIL_INTEROP_PORT_OFFSET=N`
(the flag wins) and both the Anvil ports and the output paths move with it — shard reports go to
`coverage/anvil/shards-pN/`, the merged report to `coverage/anvil/anvil-lcov-pN.info`, single-process
output to `coverage/anvil/run-pN/`, and `--html` to `coverage/anvil/html-pN/`, so one run cannot
delete the other's. Offset 0 keeps the unsuffixed paths that CI and `yarn l1 coverage:merge` expect.

**Valid offsets are 0, 2000, 4000, …** — whole multiples of 2000. A run reserves 2000 ports (up to
twenty shards, 100 apart), so bases closer than that overlap: a run at 500 would allocate the same
ports as shards 6 to 20 of a run at 0, and the later run's `startChain` kills the earlier run's
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
| `ANVIL_INTEROP_PRIVATE_KEY=0x…`        | Spec sender; token specs also need `ANVIL_INTEROP_FRESH_DEPLOY=1`       |
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
├── run-upgrade-test.ts            # Default upgrade (the v35 bootstrap) + the patch and v36 hops, via protocol-ops
├── run-recurring-upgrade-test.ts  # Registry-driven v35 -> v36 hop through the executors the deployment created
├── setup-and-dump-state.ts        # Generate pregenerated chain state snapshots
├── cleanup.sh                     # Kill Anvil processes, reset state
├── config/
│   ├── anvil-config.json          # Chain IDs, ports, settlement, interop chains
│   ├── l1-deployment.toml         # L1 contract deployment params
│   ├── ctm-deployment.toml        # ChainTypeManager params
│   ├── permanent-values.toml      # Immutable protocol values
│   └── chain-{10,11,12,13,14}.toml # Per-chain deployment params (generated)
├── chain-states/
│   ├── v0.34.0/                   # FROZEN previous-release snapshots (`upgradeSourceStateVersion`)
│   └── v0.35.0/                   # Current-source Anvil state snapshots (`stateVersion`, regenerated)
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
│   │   ├── interop-chain-registrar.ts      # Enable interop + allow interop peers
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
│   ├── 07-interop-bundles.spec.ts
│   ├── 08-interop-messages.spec.ts
│   ├── 09-interop-unbundle.spec.ts
│   ├── 13-imt-atomic-swap.spec.ts
│   ├── 14-interop-fee-units.spec.ts
│   ├── 15-interop-peer-whitelist.spec.ts
│   └── 16-interop-suspension.spec.ts
└── outputs/                       # Deployment outputs (gitignored)
```

## Limitations & Deviations from Production

### Not Supported

- **L1→L2 transaction failures / refundRecipient**: Priority requests always succeed on Anvil; failure + refund logic is untested
- **Batch settlement**: No real sequencer or prover; batches are never committed/proved/executed
- **Custom pubdata pricing**: Gas and pubdata costs use Anvil defaults, not ZKsync fee models
- **Validium mode**: All chains run as rollup (validium carries no meaning without batch settlement)

### Mock Contracts

Source of truth for the Anvil predeploy layout lives in
`src/core/predeploys.ts` via `PREDEPLOY_SYSTEM_CONTRACTS`.

| Mock                        | Address   | Replaces              | Difference                                                                                           |
| --------------------------- | --------- | --------------------- | ---------------------------------------------------------------------------------------------------- |
| `MockL2MessageVerification` | `0x10009` | L2MessageVerification | All proof checks return `true`                                                                       |
| `MockL1MessengerHook`       | `0x7001`  | L1_MESSENGER_HOOK     | No-op; real L1Messenger still emits events                                                           |
| `MockMintBaseTokenHook`     | `0x7100`  | MINT_BASE_TOKEN_HOOK  | No-op; L2BaseToken pre-funded via `anvil_setBalance`                                                 |
| `MockL1SloadPrecompile`     | `0x101`   | L1SLOAD precompile    | Serves L1 slots the harness copies from the L1 at each anchor (`src/helpers/l1-reads.ts`), no proofs |
| `DummyL1MessageRoot`        | L1        | L1MessageRoot         | All proof verification returns `true`                                                                |

Real contracts used: `SystemContext` at `0x800b`, `L1Messenger` at `0x8008`, `L2BaseToken` at `0x800a`, all other L2 system contracts at their production addresses.

### L2 Deployment: Synthetic Prestate + Real Genesis Upgrade

Contracts are first bootstrapped at hardcoded addresses via `anvil_setCode` and the base token is pre-funded via `anvil_setBalance` (production has this in genesis state). The real genesis upgrade calldata from L1's `GenesisUpgrade` event is then relayed to L2, initializing all contracts via `initL2()` with production-identical data.

### Impersonation

| What                          | Who                      | Production equivalent             |
| ----------------------------- | ------------------------ | --------------------------------- |
| Genesis upgrade relay         | `L2_FORCE_DEPLOYER_ADDR` | Bootloader executes upgrade tx    |
| Interop enabling and peers    | Default Anvil EOA        | Governance and chain admins       |
| GW chain registration         | `ChainAssetHandler`      | Governance flow                   |
| Settlement layer notification | `L2_BOOTLOADER_ADDR`     | Bootloader at batch start         |
| Governance calls              | Governance contract      | Multi-sig / timelock              |
| GW L2Bridgehub ownership      | Aliased CTM governance   | Shared governance from deployment |

### Other Shortcuts

- **GW L2Bridgehub ownership transfer**: CTM deploys a per-chain Governance, but `fullRegistration` sends from ecosystem Governance. The test transfers ownership before relay.
- **Interop scope**: the harness only enables interop for the chains marked `interop`, all of which settle on L1. Routes involving the gateway chain or the GW-settled chain revert in the harness.
- **ZiSK verifier stand-in**: the CTM uses the multi-proof verifier so that chains can lock their second proof system. Its ZiSK Plonk verifier is an `EmptyContract`, since the harness submits no proofs.
- **L2 genesis deployment via anvil_setCode**: System contracts are bootstrapped at hardcoded addresses, not via real genesis state. Production chains get that state directly from genesis.
- **Synthetic merkle proofs**: Encode settlement layer chain ID but contain no real cryptographic data
- **Interop proofs**: Correct struct shape but empty proof arrays
- **Settlement layer notification via impersonation**: `SystemContext.setSettlementLayerChainId` is called by impersonating the bootloader. On ZKsync OS, this is only emitted during actual migration between settlement layers (and during genesis/v31 upgrades), not at every batch
- **Upgrade harness storage patches**: the upgrade runners apply two direct `anvil_setStorageAt` patches on L1. Before governance, `clearGenesisUpgradeTxHash` clears the genesis-upgrade tx hash the fixture's chains still carry, which a real chain's server clears once it processes the batch and which otherwise blocks a new upgrade with `PreviousUpgradeNotFinalized`. Before each per-chain upgrade, `forceBatchExecutedEqualsCommitted` copies `totalBatchesCommitted` onto `totalBatchesExecuted` so the upgrade's outstanding-batches check passes without a sequencer and prover. Both are test-only compatibility bridges, not a production upgrade flow.
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
cd l1-contracts/test/anvil-interop
yarn cleanup
```
