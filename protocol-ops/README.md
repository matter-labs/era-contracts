# protocol-ops

Rust CLI that runs Foundry scripts and optionally generates calldata for ecosystem, chain, CTM and upgrade flows.

## Build

```bash
cd protocol-ops
cargo build --release
```

## Use

Run all commands below from the `protocol-ops` directory.

```bash
cargo run --release --bin protocol_ops -- --help
```

### Example: register a new chain

```bash
cargo run --release --bin protocol_ops -- chain init \
  --ctm-proxy 0x0000000000000000000000000000000000000001 \
  --l1-da-validator 0x0000000000000000000000000000000000000002 \
  --era-validator-operator 0x0000000000000000000000000000000000000003 \
  --commit-operator 0x0000000000000000000000000000000000000004 \
  --prove-operator 0x0000000000000000000000000000000000000005 \
  --execute-operator 0x0000000000000000000000000000000000000006 \
  --chain-id 271 \
  --private-key 0x… \
  --l1-rpc-url http://localhost:8545
```

See `chain init --help` for owners, bridgehub admin keys, and forge passthrough flags.

### Common flags (most init / upgrade commands)

Most subcommands flatten **`SharedRunArgs`** from `common/args.rs`:

| Flag                  | Role                                                                |
| --------------------- | ------------------------------------------------------------------- |
| **`--l1-rpc-url`**    | L1 RPC (default `http://localhost:8545`).                           |
| **`--out`**           | Output directory for Safe bundles + `manifest.json`.                |
| _(forge passthrough)_ | Forwarded via **`ForgeScriptArgs`** (see `--help` on each command). |

> **`--deployer-address` / `--private-key`** are **not** part of `SharedRunArgs`.
> Bootstrap and apply commands declare their own deployer key flags because they need
> an EOA to simulate forge scripts against the Anvil fork. Extra signers (e.g.
> **`--owner`**, bridgehub keys) stay on specific commands.

## Execution model

Every command that generates Safe bundles runs **exclusively against a temporary Anvil fork**
of `--l1-rpc-url`. The real L1 is **never modified** by the CLI. The fork exists only for
the duration of the command and stops when it exits.

To apply the generated Safe bundles to a real chain, use `dev execute-manifest` (or any
Safe-bundle-aware executor) with the keys from `wallets.yaml`.

## Output

Commands that support **`--out`** write a **`CommandEnvelope`** snapshot after a successful run:

| Field              | Meaning                                                                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **`command`**      | CLI path id (e.g. `chain.init`, `ecosystem.upgrade`).                                                                        |
| **`version`**      | Envelope format version (currently `1`).                                                                                     |
| **`runs`**         | One entry per Forge script: `script` (path) and `run` (broadcast JSON for that script).                                      |
| **`transactions`** | Flat array in execution order: `{ "to", "data", "value" }` for replay (normalized like `cast send`). Built from every `run`. |
| **`input`**        | Serialized command input (may be `{}` if the command passes an empty object).                                                |
| **`output`**       | Command-specific result object (may be `{}`).                                                                                |

## Requirements

You need a working Foundry toolchain (`forge`, `cast`, etc.) and repo contract artifacts as expected by the scripts this tool wraps. From the repo root, `l1-contracts` must be built (`forge build`).

### Verifying a deployed ecosystem (`ecosystem verify-deployment`)

Where PUVT (below) checks an _upgrade_ against the artifacts that produced it,
`verify-deployment` checks a _live_ ecosystem against a local contracts build.
It takes one address — the Bridgehub proxy — and discovers everything else on
chain, so it works the same against an ecosystem somebody else deployed and
needs no deployment output file. It is read-only (`eth_call`, `eth_getCode`,
`eth_getStorageAt`, `eth_getLogs`) and safe to point at mainnet.

Check out the commit the ecosystem was deployed from and build the contracts
first — the tool compares against `l1-contracts/out` and `da-contracts/out`:

```bash
yarn da build:foundry && yarn l1 build:foundry

cd protocol-ops
cargo run --release --bin protocol_ops -- ecosystem verify-deployment \
  --bridgehub 0xb9415d43c7753ccebaa1ac05c8baba36159ab13f \
  --l1-rpc-url "$SEPOLIA_RPC_URL" \
  --from-block 11579085 \
  --era-chain-id 270 \
  --weth 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9 \
  --zk-token-l1-address 0x… \
  --expect-testnet-verifier true
```

`--from-block` should be at or before the ecosystem's first deployment block:
the chain creation parameters, the pending-admin history and the DA pair
whitelist all come from logs, and hosted RPCs reject a scan from genesis.

What it checks:

| Section                  | What it proves                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Bytecode**             | Every discovered contract against the local build, with the artifact's own `immutableReferences` masked and CBOR metadata digests blanked. Reports `exact` vs `metadata-only`, and warns when anything is metadata-only — that also means the genesis root and the L2 force-deployment hashes are not independently reproducible.                                        |
| **Immutables**           | Values read back out of deployed runtime code at the artifact's immutable offsets and checked against what discovery says they should be (bridgehub, chain id, WETH, asset router, verifier, …). Unrecognised ones are printed.                                                                                                                                          |
| **Wiring**               | Every setter the deploy scripts are supposed to have run: `setNativeTokenVault`, the three `L1Nullifier` setters, `setL1InteropHandler`, `CAH.setAddresses`, `ServerNotifier.setChainTypeManager`, `setDefaultUpgrade`, `registerEthToken`, and the three-call CTM registration.                                                                                         |
| **Chain creation**       | Recomputes `storedBatchZero`, `initialCutHash` and `initialForceDeploymentHash` from the `NewChainCreationParams` event and binds them to what the CTM stores; then checks the diamond cut (selectors against the deployed facets' dispatchers, freezability, no collisions) and every force-deployments field, including the L2 implementations' blake2s/length/keccak. |
| **Verifier and genesis** | Which verifier flavour is deployed, and the deployed genesis root and prover VK hash against `configs/genesis/zksync-os/latest.json`.                                                                                                                                                                                                                                    |
| **Data availability**    | The `RollupDAManager` whitelist, and whether each live chain's DA pair is one `makePermanentRollup()` would accept.                                                                                                                                                                                                                                                      |
| **Roles**                | `owner` / `pendingOwner` / `admin` / `pendingAdmin` / `securityCouncil` / `tokenMultiplierSetter` across the ecosystem, grouped by holder. Fails on stalled two-step handoffs, warns on `transferOwnership(currentOwner)` no-ops and on roles held by an EOA.                                                                                                            |
| **Registered chains**    | Each chain's protocol version, verifier, facet set, base token registration, genesis batch and settlement layer against the CTM.                                                                                                                                                                                                                                         |

Expectations the tool cannot derive from chain state are flags:
`--era-chain-id`, `--weth`, `--max-number-of-zk-chains` (default 100),
`--expect-testnet-verifier`, `--zk-token-l1-address`. `--env` supplies the
bridgehub and era chain id from `permanent-values/<env>.toml`.

> **`--zk-token-l1-address` is worth passing.** The ZK token asset id is
> `keccak(abi.encode(originChainId, L2_NTV, token))`. Copying another
> ecosystem's value points every chain at an asset nothing in this ecosystem
> can bridge, and `InteropCenter` writes it once in `initL2` with no setter —
> so it cannot be fixed on a chain that already exists. Without the flag the
> tool can only report the value.

Exit code is non-zero when there are errors; warnings do not fail the run.

### Running the Protocol Upgrade Verification Tool (PUVT)

The PUVT requires we have already run the upgrade scripts that deploy all new protocol contracts. For v31 stage, regenerate the calldata and replay the prepare bundles on a pinned Sepolia fork, then run PUVT against the same fork.

Start a read-only Sepolia fork. Keep the RPC URL out of committed files:

```bash
export L1_RPC_URL='<sepolia-rpc-url>'

anvil \
  --fork-url "$L1_RPC_URL" \
  --port 48546 \
  --auto-impersonate \
  --disable-block-gas-limit \
  --base-fee 0
```

In a second shell, generate the stage artifact:

```bash
cd protocol-ops

cargo run --release --bin protocol_ops -- ecosystem upgrade-prepare-all \
  --env stage \
  --bridgehub 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE \
  --l1-rpc-url http://127.0.0.1:48546 \
  --deployer-address 0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7 \
  --out ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/prepare \
  --additional-args=--memory-limit=536870912 \
  --additional-args=--offline \
  --additional-args=--skip-simulation
```

This writes the canonical merged calldata to `l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml`. The `prepare/` subdirectory contains `manifest.json` and replayable `*.safe.json` bundles.
We can send these to the local L1 fork via:

```bash
cargo run --release --bin protocol_ops -- ecosystem upgrade-broadcast \
  --manifest ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/prepare/manifest.json \
  --l1-rpc-url http://127.0.0.1:48546 \
  --unlocked \
  --out ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/executed-bundles.json
```

The deployment tx hashes are appended to the committed `transactions.txt` next to `ecosystem.toml`.
PUVT reads that file, fetches each tx via `--l1-rpc-url`, and reconstructs the deployment provenance.

```bash
export L1_RPC_URL=http://127.0.0.1:48546
export GW_RPC_URL=<gateway-rpc-url>

cargo run --release --bin protocol_ops -- ecosystem verify-upgrade \
  --env stage \
  --ecosystem-toml "../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml" \
  --l1-rpc-url "$L1_RPC_URL" \
  --gw-rpc-url "$GW_RPC_URL" \
  --zk-governance-commit 41ad762d7478c80e1e8c3a2c8cabbdfca9f7ffce
```

Other knobs (all read from `permanent-values/<env>.toml` and the v31 input
TOML when `--env` is set — pass an explicit flag to override):

| Flag                            | Default source                                                               | When to override                                                                                                                                                                                                          |
| ------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--transactions-log <path>`     | `<l1-contracts>/upgrade-envs/v0.31.0-interopB/output/<env>/transactions.txt` | Verifying a custom rollout output dir.                                                                                                                                                                                    |
| `--contracts-commit <hash>`     | local checkout                                                               | Verifying against contract metadata from a different commit. When omitted, local `AllContractsHashes.json` and `SystemConfig.json` are authoritative, so first verify the checkout matches the reviewed contracts commit. |
| `--zk-governance-commit <hash>` | required                                                                     | PUVT fetches zk-governance `AllContractsHashes.json` at this commit and uses it to provenance-check the deployed contracts recorded in `[zk_governance]`.                                                                 |
