# Manual review procedure for v31 calldata

## Relevant files

- `protocol-ops/src/commands/ecosystem/verify_upgrade.rs` - PUVT entry point.
- `protocol-ops/src/upgrade_verification/` - PUVT calldata and state verifiers.
- `protocol-ops/README.md` - current PUVT build and run commands.
- `l1-contracts/test/anvil-interop/regen-and-verify-stage.sh` - stage calldata regeneration, replay, and PUVT flow.
- `l1-contracts/deploy-scripts/upgrade/v31/` - v31 upgrade script entry points.
- `l1-contracts/deploy-scripts/upgrade/default-upgrade/` - shared v31 upgrade payload construction.
- `l1-contracts/contracts/upgrades/` - governance and L2 upgrade structs used for decoding.
- `l1-contracts/upgrade-envs/` - reviewed environment and permanent-value inputs.
- `AllContractsHashes.json` - bytecode hash to artifact mapping.

This page is a step-by-step procedure for reviewing already-generated v31
upgrade calldata. Regeneration or fork replay can be used as supporting
evidence, but the reviewed object is still the provided calldata.

The reviewer starts from a calldata package, the reviewed `era-contracts`
commit, and L1 state access when live-state checks are in scope. The goal is to
prove that every provided transaction and every nested calldata blob matches the
reviewed source, artifact config, and on-chain state.

## Review Rule

Every calldata byte must end in one of these states:

- decoded and matched to reviewed source, artifact config, and on-chain state;
- intentionally out of scope and recorded as such;
- blocker.

Do not accept labels inside a JSON/TOML file as proof. A label is only useful
after the address, selector, bytecode, constructor args, or on-chain state behind
it has been checked.

## Review Phases

Use these phases to orient the detailed procedure below. They are review phases,
not the same thing as the v31 governance Stage 0/1/2 calldata blocks.

| Phase                                | What it proves                                                                                                              | Detailed steps                               |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Package integrity                    | the package is complete, ordered, signed by the right actors, and free of stale calldata                                    | Steps 1-3                                    |
| Address book and governance envelope | targets, owners, wrappers, operation hashes, and nested stage calls resolve to the reviewed source of truth                 | Steps 4-6 and 15                             |
| Deployed contracts and constructors  | deployed bytecode, CREATE2 addresses, constructor args, proxy init args, and proxy admins are correct                       | Steps 12-13                                  |
| Core L1 upgrade calls                | proxy upgrades, MessageRoot init, `setAddresses`, ChainRegistrationSender/AssetTracker ownership, NTV wiring, ValidatorTimelock upgrade, and migration pause/unpause are correct | Steps 7 and 14                               |
| CTM and chain creation params        | `setChainCreationParams`, genesis values, fixed force deployment data, and ZK token asset ID are correct                    | Step 8                                       |
| Protocol upgrade payload             | `setNewVersionUpgrade`, facet cuts, `ProposedUpgrade`, L2 upgrade tx, factory deps, and `IL2V31Upgrade.upgrade` are correct | Steps 9-11                                   |
| Per-chain phases                     | timestamp and per-chain `upgradeChainFromVersion` bundles match the phase-order evidence                                    | Step 16                                      |
| Stage3 and token migration           | token registration and balance migration calls match the reviewed token list and state                                      | Step 17                                      |
| Evidence and sign-off                | every decoded item has an evidence row, and all gaps or blockers are explicit                                               | Final evidence table, blockers, and sign-off |

Complete the phases in order. If a conditional phase is absent, such as Gateway
or Stage3, record that it is absent rather than skipping it silently.

## Minimal Handoff

Do not require reviewers to receive a large prebuilt evidence bundle. The
handoff should be as small as possible:

| Handoff item                                            | Why it is needed                                                             |
| ------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Reviewed v31 calldata package                           | the actual bytes, ordering, targets, and values under review                 |
| Reviewed `era-contracts` commit and submodule state     | ABIs, constants, `AllContractsHashes.json`, upgrade configs, genesis configs |
| L1 RPC URL and exact review block hash, for full review | Bridgehub, CTM, proxy, Safe, token, bytecode, and protocol-version state     |
| Requested scope                                         | local/fork/stage/prod and pre-signing/post-execution sign-off                |

The calldata package may be Safe JSON, governance proposal JSON, manifests, or
an ordered list of raw `(to, value, data)` transactions. If only a raw calldata
blob is provided without target, value, ordering, or wrapper context, the
review is limited to decoding that blob and cannot make package-level claims.

Everything else should be derived by the reviewer from the calldata package,
the reviewed source, fork replay, or block-pinned RPC reads.

## Value Source Matrix

When a later step says "expected", use this table first. Do not search other
repositories unless the table explicitly points outside the reviewed
`era-contracts` checkout.

| Value                                   | Authoritative source                                                                                                                        | Cross-check                                                                                                                           |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `ecosystem.toml`                        | provided package, or regenerated from the reviewed commit with the same `protocol_ops ecosystem upgrade-prepare-all` command                | file header and manifest command match reviewed calldata package                                                                      |
| stage 0/1/2 `Call[]`                    | `[governance_calls].stage0_calls`, `stage1_calls`, `stage2_calls` in `ecosystem.toml`                                                       | decoded calls match the Safe/governance wrapper bytes                                                                                 |
| global phase order                      | package order, root manifest, governance wrapper order, CI command log, or exact rollout command                                            | every referenced phase file exists once; no stale phase dirs                                                                          |
| Safe/EOA bundle target                  | `manifest.json.bundles[].target` and Safe transaction target                                                                                | for Safes, `getOwners()` and `getThreshold()` at the review block; for owners/executors, target matches the on-chain owner path below |
| governance owner / executor             | `Bridgehub.owner()`, CTM/proxy-admin owners, and wrapper target decoded from calldata                                                       | owner address has expected code/EOA type; Safe owners and threshold are reviewed at the block                                         |
| L1 chain ID                             | `eth_chainId` at the review RPC/block                                                                                                       | every Safe file `chainId` and decoded L1-chain field matches it                                                                       |
| Bridgehub proxy                         | `[core.upgrade_addresses.bridgehub].bridgehub_proxy_addr`                                                                                   | has code; equals the Bridgehub used for chain inventory and owner reads                                                               |
| transparent proxy admin                 | EIP-1967 admin slot of Bridgehub and other v31 transparent proxies                                                                          | all v31 proxy admin slots agree unless a proxy is intentionally not TUPP                                                              |
| core proxy / implementation addresses   | `[core.upgrade_addresses]`, `[core.upgrade_addresses.bridgehub]`, `[core.upgrade_addresses.bridges]`, and `[core].asset_tracker_proxy_addr` | Stage 1 proxy upgrade calls use exactly these pairs                                                                                   |
| CTM flavors and order                   | `[ctms.era]`, then `[ctms.zksync_os]` if present in `ecosystem.toml`                                                                        | on-chain CTM `isZKsyncOS()` agrees with the flavor                                                                                    |
| CTM state-transition addresses          | `[ctms.<flavor>.state_transition]` and `[ctms.<flavor>.deployed_addresses]`                                                                 | Stage 0/1 CTM calls and deployment provenance reference these addresses                                                               |
| ValidatorTimelock proxy/impl per CTM    | `[ctms.<flavor>.state_transition].validator_timelock_addr` and `validator_timelock_implementation_addr`                                      | Stage 1 per-CTM block `block_start + 5` upgrades this proxy through its proxy admin                                                   |
| PUH upgrade addresses (PUH-governed envs) | `[puh_guardians].new_puh_impl` and `[puh_guardians].new_guardians` in `ecosystem.toml`                                                   | Stage 0 PUH pair args; PUVT verifies decoded args against these values and checks new impl immutables |
| legacy GW decommission intervals        | `[[legacy_gateway.chain_intervals]]` in `upgrade-envs/permanent-values/<env>.toml`                                                          | Stage 2 decommission prefix; absent when `[legacy_gateway]` is not present                                                            |
| old/new protocol versions               | `[ctms.<flavor>.contracts_config].old_protocol_version` and `new_protocol_version`                                                          | old version equals CTM/chain state at the review block; new version is v31                                                            |
| chain inventory                         | `Bridgehub.getAllZKChainChainIDs()`, `chainTypeManager(chainId)`, and `getZKChain(chainId)` at the review block                             | every reviewed CTM has a representative chain; every registered reviewed chain has the expected old version                           |
| per-chain phase values                  | phase `manifest.json` metadata, otherwise decoded phase calldata plus exact rollout command/CI command log                                  | chain ID, chain admin target, timestamp, and protocol version all agree                                                               |
| v31 genesis values                      | reviewed v31 env config under `l1-contracts/upgrade-envs/v0.31.0-*` and decoded `setChainCreationParams`                                    | genesis root/index/commitment match the selected CTM flavor                                                                           |
| bytecode hashes and contract names      | reviewed `AllContractsHashes.json` plus Forge artifacts in the reviewed commit                                                              | decoded bytecode hashes map to one expected file, no aliases guessed from names                                                       |
| BytecodesSupplier                       | `[ctms.<flavor>.state_transition].bytecodes_supplier_addr`                                                                                  | all L2 factory deps are published when RPC is available                                                                               |
| Era chain ID in fixed force deployments | reviewed env config `era_chain_id` and representative Era chain state                                                                       | `FixedForceDeploymentsData.eraChainId` matches even for ZKsync OS CTMs                                                                |
| ZK token asset ID                       | reviewed `upgrade-envs/permanent-values/<env>.toml` `zk_token_asset_id`, or explicit stage input when reviewing a nonstandard package       | `NativeTokenVault.tokenAddress(assetId)` and Stage3 registrations agree                                                               |
| CREATE2 factory                         | transaction target; standard factory is `0x4e59b44847b379578588920ca78fbf26c0b4956c`                                                        | factory calldata is raw `salt ++ init_code`, not selector calldata                                                                    |
| CREATE2 salts and deployed addresses    | replayed prepare bundle `executed-bundles.json`, or equivalent ordered tx log                                                               | salt, init code, constructor args, and computed address match artifact references                                                     |
| Gateway config                          | `[new_gateway]` in `ecosystem.toml` and reviewed env config                                                                                 | Stage 2 Gateway appendage values and priority txs match                                                                               |
| Stage3 token list                       | stage3 command input, phase metadata, reviewed stage/permanent env config, or explicit package input                                        | token/address/asset registrations and balances match; absent list is a gap                                                            |
| receipts and post-state                 | L1 receipts, Safe service/export data, fork execution log, and post-state block hash                                                        | required only for post-execution sign-off                                                                                             |
| optional PUVT output                    | local `protocol_ops ecosystem verify-upgrade` run from the reviewed commit/tool commit                                                      | supporting evidence only; manual evidence rows still required                                                                         |

Calldata alone can prove byte-level decode and source compatibility. Full
review additionally needs a state anchor because the same bytes can be correct
or incorrect depending on proxy admins, Safe owners, registered chains, token
state, and already-published bytecodes. If a check cannot be derived from
calldata, reviewed source, fork replay, or block-pinned state, record it as a
gap. For stage or production signing, unresolved gaps are blockers.

## Step 1: Prepare Local References

Checkout the reviewed contracts commit so all ABIs, structs, hashes, scripts,
and configs come from the same source version as the reviewed calldata.

```bash
git clone https://github.com/matter-labs/era-contracts.git
cd era-contracts
git checkout <reviewed_contracts_commit>
git submodule update --init --recursive
git rev-parse HEAD
git submodule status --recursive
```

Record two commits when they differ: the commit that produced the reviewed
artifacts and the commit of any `protocol_ops` binary used for cross-checking.
Build `protocol_ops` from the artifact checkout only if that checkout contains
the required command; otherwise use the reviewed verifier/tool commit and record
why it differs.

```bash
cargo build --manifest-path protocol-ops/Cargo.toml --release
```

For Sepolia stage review, use the stage anchors appendix as an orientation
aid. For local, fork, or CI-generated packages, use the package's own commit,
config, manifests, and logs instead.

Use `cast` for ad hoc decoding:

```bash
cast sig "upgrade(address,address)"
cast calldata-decode "upgrade(address,address)" <calldata>
cast calldata-decode "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))" <calldata>
```

For stage calls, the TOML stores ABI-encoded `Call[]`:

```bash
cast decode-abi "f()((address,uint256,bytes)[])" <stage_calls_hex>
```

If a selector is unknown, first identify it:

```bash
cast 4byte-decode <selector_or_calldata>
```

Use this only for selector-based calldata. Do not run selector lookup on raw
CREATE2 factory calldata before classifying the transaction target.

If `cast 4byte-decode` is unavailable or unreliable, derive selectors locally:

```bash
cast sig "functionName(type1,type2)"
forge inspect <ContractName> abi
```

Then decode with the ABI from the reviewed source. A 4byte result is a hint,
not proof; local reviewed ABIs win over signature-database guesses.

All live reads must use the same review state point. If a command cannot accept
the block tag you need, record that limitation and do not mix its result with
block-pinned checks.

## Step 2: Inventory The Provided Calldata

Create an inventory before semantic review. Every row gets a stable ID that can
be referenced in notes.

For a multi-phase package, first list every phase directory:

```bash
find <package-root> -name manifest.json -print | sort
find <package-root> -name '*.safe.json' -print | sort
```

For the manifest:

```bash
jq -r '.bundles | sort_by(.index)[] |
  [.index, .target, .file, .tx_count, ((.steps // []) | join(","))] | @tsv' \
  <manifest.json>
```

For each Safe file:

```bash
jq -r --arg file "<safe-file>" '
  .chainId as $chain_id |
  .transactions | to_entries[] |
  [$file, $chain_id, .key, .value.to, .value.value, (.value.data[0:10])] | @tsv
' <safe-file>
```

The last column is only a data prefix. Treat it as a selector only after the
transaction target and call format are known. For raw calls to the standard
CREATE2 factory at `0x4e59...`, this prefix is the first four bytes of the
salt, not a selector.

For executed bundles:

```bash
jq -r '.transactions | to_entries[] |
  [.key, .value.tx_hash, .value.to, .value.value, .value.status, (.value.data[0:10])] | @tsv
' <executed-bundles.json>
```

The inventory must prove:

- manifest `bundles[]` sorted by `index` is the intended execution order;
- for a multi-phase package, each phase manifest orders only its own bundles;
  global phase order must come from the Value Source Matrix phase-order
  sources;
- each `bundles[].file` exists under the reviewed package;
- each `bundles[].tx_count` equals the Safe file `transactions | length`;
- each `bundles[].target` matches the Safe/EOA target derived in the Value
  Source Matrix; for Safes, derive owners and threshold from block-pinned Safe
  state;
- every Safe file `chainId` matches the matrix L1 chain ID;
- every top-level transaction has `value = 0` unless explicitly approved;
- no extra Safe files, duplicate manifests within the same phase, unexpected
  phase directories, or stale output directories are in the package;
- each executed-bundles transaction corresponds to a reviewed Safe transaction
  in order.

If there is no authoritative global phase order in the calldata package or
rollout command evidence, record it as a gap. For stage or production review,
missing global order is a blocker.

Generator scratch directories, such as `script-out`, are acceptable only when
the command log or package metadata shows they belong to this generation run.
Unreferenced old manifests/Safe files remain blockers.

For Safe Transaction Builder JSON, also check every transaction has only the
expected `to`, `value`, `data`, and optional method metadata when present.
For a real Safe
execution payload or Safe service export, additionally verify the Safe address,
nonce progression, `operation` is `0` unless explicitly approved, gas/refund
fields match the decoded transaction, EIP-712 domain uses the reviewed Safe
and chain ID, and the Safe transaction hash matches the operation approved by
signers.

Any extra transaction, missing transaction, unknown target, or mismatched order
is a blocker.

## Step 3: Run Optional Tool Cross-Check

Run `protocol_ops ecosystem verify-upgrade` against the reviewed calldata
package when possible. This verifies provided calldata and replay logs. If the
package does not include an executed-bundles log, generate one by replaying the
prepare bundle on a fork, the same way the PUVT stage script does.

The replay path is supporting evidence, not a replacement for reviewing the
provided bytes:

```bash
protocol_ops ecosystem upgrade-broadcast \
  --manifest <prepare_manifest.json> \
  --l1-rpc-url <fork_rpc_url> \
  --unlocked \
  --out <executed-bundles.json>
```

Extract CREATE2 salts from the replay log:

```bash
jq -r '.transactions[] |
  select((.to | ascii_downcase) == "0x4e59b44847b379578588920ca78fbf26c0b4956c") |
  .data[2:66]
' <executed-bundles.json> | sort -u
```

```bash
./target/release/protocol_ops ecosystem verify-upgrade \
  --ecosystem-toml <ecosystem.toml> \
  --l1-rpc-url <l1_rpc_url> \
  --contracts-commit <reviewed_contracts_commit> \
  --era-chain-id <representative_era_chain_id> \
  --genesis-config <era|zksync-os> \
  --executed-bundles <executed-bundles.json> \
  --create2-factory <create2_factory_address> \
  --create2-salt <salt1>[,<salt2_if_any>] \
  --zk-token-asset-id <expected_zk_token_asset_id>
```

Despite the current `--era-chain-id` flag name, pass the representative chain ID
that the verifier expects for this artifact and record which CTM flavor it
covers. If the package has multiple CTM flavors and the tool accepts only one
representative chain or genesis mode, run the strongest supported tool check
and complete the remaining per-flavor checks manually.

Record the exact command, commit, RPC state point, output, warnings, and errors.
Tool success is supporting evidence. Manual review still needs to decode the
calldata surfaces below, validate the Safe/manifest layer, and confirm there
are no unexplained actions. Tool errors are blockers unless the reviewer
documents an exact false positive and a strong manual substitute check.

## Step 4: Build The Address Book

Build an address table before decoding stage semantics. Use `ecosystem.toml`,
live L1 state, and the reviewed source.

| Name                                          | Source                                                                                                            | Required check                                                 |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `bridgehub_proxy`                             | `[core.upgrade_addresses.bridgehub].bridgehub_proxy_addr`                                                         | has code; all Bridgehub RPC reads use this address             |
| `transparent_proxy_admin`                     | `[core.upgrade_addresses.shared].transparent_proxy_admin`; cross-check against EIP-1967 admin slot of `bridgehub_proxy` | same admin owns all reviewed v31 TUPP proxies                  |
| `chain_asset_handler_proxy`                   | `[core.upgrade_addresses.bridgehub].chain_asset_handler_proxy_addr`                                               | has code and is the Stage 0/2 migration target                 |
| `chain_registration_sender_proxy`             | `[core.upgrade_addresses.bridgehub].chain_registration_sender_proxy_addr`                                         | pending owner is governance; `acceptOwnership()` called in Stage 1 index 7 |
| `l1_asset_router_proxy`                       | `[core.upgrade_addresses.bridges].l1_asset_router_proxy_addr`                                                     | `Bridgehub.assetRouter()` agrees when callable                 |
| `l1_nullifier_proxy`                          | `[core.upgrade_addresses.bridges].l1_nullifier_proxy_addr`                                                        | EIP-1967 proxy admin equals `transparent_proxy_admin`          |
| `native_token_vault`                          | `[core.upgrade_addresses].native_token_vault_addr`                                                                | `L1AssetRouter.nativeTokenVault()` agrees after Stage 1/replay |
| `asset_tracker_proxy`                         | `[core].asset_tracker_proxy_addr`                                                                                 | accepts ownership before NTV is wired to it                    |
| `ctm_deployment_tracker_proxy`                | `[core.upgrade_addresses.bridgehub].ctm_deployment_tracker_proxy_addr`                                            | upgraded before CTM asset registration                         |
| `message_root_proxy`                          | `[core.upgrade_addresses.bridgehub].message_root_proxy_addr`                                                      | upgraded with `initializeL1V31Upgrade()`                       |
| each CTM proxy                                | Stage 1 CTM proxy argument, plus `[ctms.<flavor>.state_transition].chain_type_manager_proxy` when serialized      | protocol version and proxy admin match the matrix sources      |
| each CTM timer/validator                      | `[ctms.<flavor>.deployed_addresses]`                                                                              | used in stage call blocks                                      |
| ValidatorTimelock proxy per CTM               | `[ctms.<flavor>.state_transition].validator_timelock_addr`                                                        | Stage 1 per-CTM upgrade; proxy admin fetched from EIP-1967 slot |
| ValidatorTimelock implementation per CTM      | `[ctms.<flavor>.state_transition].validator_timelock_implementation_addr`                                         | new impl adds `UPGRADER_ROLE` and `upgradeChainFromVersion`    |
| representative chain diamond per CTM flavor   | Bridgehub chain inventory                                                                                         | used for current facet and protocol-version checks             |
| each verifier/default/genesis/diamond address | `[ctms.<flavor>.state_transition]`                                                                                | used in chain params and upgrade params                        |
| BytecodesSupplier per CTM flavor              | `[ctms.<flavor>.state_transition].bytecodes_supplier_addr`                                                        | used for factory-dep publication checks                        |
| PermissionlessValidator per CTM flavor        | `[ctms.<flavor>.state_transition].permissionless_validator_addr` when serialized, otherwise deployment provenance | checked against CTM implementation immutable                   |
| EIP7702Checker                                | `[ctms.<flavor>.state_transition].eip7702_checker_addr` when serialized, otherwise deployment provenance          | constructor arg for v31 MailboxFacet                           |
| `new_gateway.*` (required in v31)             | `[new_gateway]`                                                                                                   | drives Stage 2 Gateway bring-up calls (mandatory 16-call block) |

Check proxy admin slots for v31 proxies. The EIP-1967 admin slot of the core
proxies must equal `transparent_proxy_admin`:

- `bridgehub_proxy`
- `l1_nullifier_proxy`
- `l1_asset_router_proxy`
- `native_token_vault`
- `message_root_proxy`
- `ctm_deployment_tracker_proxy`
- `chain_asset_handler_proxy`
- `chain_registration_sender_proxy`

For CTM and ValidatorTimelock proxies, each CTM flavor may use a per-CTM proxy
admin that differs from the global `transparent_proxy_admin`. PUVT reads the
EIP-1967 slot of each CTM proxy and VT proxy at verification time and uses
whatever it finds as the expected call target. Record the actual admin address
for each CTM proxy and VT proxy as part of the evidence.

Also record:

- L1 chain ID from RPC;
- expected new protocol version `0.31.0`;
- expected old protocol version per CTM flavor: Era `0.29.4`, ZKsync OS
  `0.30.1`;
- representative chain ID and diamond address per CTM flavor, for example via
  `Bridgehub.getZKChain(chainId)` and `Bridgehub.chainTypeManager(chainId)`;
- every registered chain using each reviewed CTM, from
  `Bridgehub.getAllZKChainChainIDs()` when available or an equivalent chain
  inventory;
- whether the environment is PUH-governed, detected by `Bridgehub.owner()` being
  a proxy with a nonzero EIP-1967 admin slot.

## Step 5: Decode Governance Stage Calls

Extract these fields from `ecosystem.toml`:

- `[governance_calls].stage0_calls`
- `[governance_calls].stage1_calls`
- `[governance_calls].stage2_calls`

Decode each as:

```bash
cast decode-abi "f()((address,uint256,bytes)[])" <stage_calls_hex>
```

For every decoded `Call`:

- `target` must resolve to the expected address-book name;
- `value` must be zero unless the step explicitly allows value;
- first 4 bytes of `data` must match the expected selector;
- nested bytes must be recursively decoded until no structured calldata remains.

## Step 6: Verify Stage 0

Stage 0 pauses migration and starts CTM timers.

Expected shape:

| Index   | Target                                | Selector           | Extra checks                  |
| ------- | ------------------------------------- | ------------------ | ----------------------------- |
| `0`     | `chain_asset_handler_proxy`           | `pauseMigration()` | no args, zero value           |
| `1 + i` | CTM `i` `l1_governance_upgrade_timer` | `startTimer()`     | one per CTM in artifact order |

Artifact CTM order is deterministic: `[ctms.era]` first, then
`[ctms.zksync_os]` if both are present. A package with only one of those
sections uses that single flavor. Any other CTM flavor label or disagreement
between CTM flavor and on-chain CTM behavior is a blocker.

If the environment is PUH-governed, Stage 0 has two additional calls immediately after the timer block
(`base_count = 1 + N` where `N = number_of_ctms`):

| Offset           | Target                          | Selector                                | Extra checks                                                            |
| ---------------- | ------------------------------- | --------------------------------------- | ----------------------------------------------------------------------- |
| `base_count`     | `Bridgehub.owner()` proxy admin | `upgradeAndCall(address,address,bytes)` | `proxy == Bridgehub.owner()`, `data` empty, `implementation == [puh_guardians].new_puh_impl`; PUVT also reads 10 immutable getters on the new impl (`L2_PROTOCOL_GOVERNOR`, `CHAIN_TYPE_MANAGER`, `BRIDGE_HUB`, `L1_NULLIFIER`, `L1_ASSET_ROUTER`, `L1_NATIVE_TOKEN_VAULT`, `CHAIN_ASSET_HANDLER`, `ERA_CHAIN_TYPE_MANAGER`, `ZKSYNC_OS_CHAIN_TYPE_MANAGER`, `ERA_CHAIN_ID`) and asserts they match expected values |
| `base_count + 1` | `Bridgehub.owner()`             | `updateGuardians(address)`              | `_newGuardians == [puh_guardians].new_guardians`; new Guardians address has code |

Detect PUH governance by reading `Bridgehub.owner()` and checking that its EIP-1967 admin slot is
non-zero (the owner is a TUPP-style proxy, i.e. ProtocolUpgradeHandler).

Additionally, when a prior `transferOwnership()` ceremony left CTM pending owners outstanding (the
`pre-governance-accept-ownerships` step), Stage 0 ends with `P` `acceptOwnership()` calls
(`0x79ba5097`). Each targets a CTM proxy whose `pendingOwner()` was left outstanding by the
ownership ceremony; they complete the two-step transfer before governance executes. These calls form
a strict tail starting at `base_count + 2` (PUH) or `base_count` (non-PUH). PUVT enforces this
position, queries live `pendingOwner()` on each registered CTM proxy to build the expected target
list, then asserts the tail matches exactly — no duplicates, no extras, no missing targets.

Record each `acceptOwnership()` target and confirm it is a CTM proxy in the address book as an
independent cross-check.

Expected Stage 0 count is `1 + N + P` for non-PUH governance, `1 + N + 2 + P` for PUH-governed
environments, where `P ≥ 0`.

Any call that is not `pauseMigration`, `startTimer`, the PUH pair (when applicable), or a
pre-governance `acceptOwnership` is a blocker.

## Step 7: Verify Stage 1 Shape

Stage 1 has an 11-call ecosystem prefix followed by one 6-call block per CTM.

Prefix:

| Index | Target                      | Selector                                | Required payload check                                                                     |
| ----- | --------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------ |
| `0`   | `transparent_proxy_admin`   | `upgrade(address,address)`              | `bridgehub_proxy -> bridgehub_implementation_addr`                                         |
| `1`   | `transparent_proxy_admin`   | `upgrade(address,address)`              | `l1_nullifier_proxy -> l1_nullifier_implementation_addr`                                   |
| `2`   | `transparent_proxy_admin`   | `upgrade(address,address)`              | `l1_asset_router_proxy -> l1_asset_router_implementation_addr`                             |
| `3`   | `transparent_proxy_admin`   | `upgrade(address,address)`              | `native_token_vault -> native_token_vault_implementation_addr`                             |
| `4`   | `transparent_proxy_admin`   | `upgradeAndCall(address,address,bytes)` | `message_root_proxy -> message_root_implementation_addr`, inner `initializeL1V31Upgrade()` |
| `5`   | `transparent_proxy_admin`   | `upgrade(address,address)`              | `ctm_deployment_tracker_proxy -> ctm_deployment_tracker_implementation_addr`               |
| `6`   | `transparent_proxy_admin`   | `upgrade(address,address)`              | `chain_asset_handler_proxy -> chain_asset_handler_implementation_addr`                     |
| `7`   | `chain_registration_sender_proxy` | `acceptOwnership()`                     | zero value; completes two-step ownership transfer to governance                            |
| `8`   | `asset_tracker_proxy`             | `acceptOwnership()`                     | zero value                                                                                 |
| `9`   | `native_token_vault`              | `setAssetTracker(address)`              | argument equals call 8 target (`asset_tracker_proxy`)                                      |
| `10`  | `chain_asset_handler_proxy`       | `setAddresses()`                        | zero value                                                                                 |

For each CTM `i`, `block_start = 11 + 6 * i`:

| Index             | Target                            | Selector                      | Required payload check                                                                        |
| ----------------- | --------------------------------- | ----------------------------- | --------------------------------------------------------------------------------------------- |
| `block_start + 0` | CTM timer                         | `checkDeadline()`             | `[ctms.<flavor>.deployed_addresses].l1_governance_upgrade_timer`                              |
| `block_start + 1` | CTM upgrade stage validator       | `checkMigrationsPaused()`     | `[ctms.<flavor>.deployed_addresses].upgrade_stage_validator`                                  |
| `block_start + 2` | CTM proxy admin                   | `upgrade(address,address)`    | CTM proxy and implementation match `[ctms.<flavor>.state_transition]`                         |
| `block_start + 3` | CTM proxy                         | `setChainCreationParams(...)` | perform Step 8                                                                                |
| `block_start + 4` | CTM proxy                         | `setNewVersionUpgrade(...)`   | perform Steps 9, 10, and 11                                                                   |
| `block_start + 5` | ValidatorTimelock proxy admin     | `upgrade(address,address)`    | PUVT verifies `proxy == validator_timelock_addr` and `impl == validator_timelock_implementation_addr` from the artifact; call target is the proxy admin read from the EIP-1967 admin slot of the VT proxy |

PUVT decodes the VT upgrade call and verifies the `proxy` and `implementation` args against the
artifact. The call target (proxy admin) is read from the EIP-1967 slot of the VT proxy at
verification time; it may differ from `transparent_proxy_admin` and from the CTM proxy admin.
Verify the implementation address maps to the expected ValidatorTimelock v31 artifact in
`AllContractsHashes.json` — the new implementation adds `UPGRADER_ROLE` and
`upgradeChainFromVersion`.

Expected Stage 1 count is `11 + 6 * number_of_ctms`. Any extra or missing call
is a blocker.

## Step 8: Verify `setChainCreationParams`

Decode:

```bash
cast calldata-decode \
  "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))" \
  <call_data>
```

For the CTM flavor being reviewed:

- `genesisUpgrade` equals `[ctms.<flavor>.state_transition].genesis_upgrade_addr`;
- `diamondCut.initAddress` equals `[ctms.<flavor>.state_transition].diamond_init_addr`;
- `genesisBatchHash` equals the selected v31 genesis config root;
- `genesisIndexRepeatedStorageChanges` equals the genesis config value when the
  config provides it;
- `genesisBatchCommitment` equals the genesis config value when the config
  provides it;
- `abi.encode(diamondCut)` equals
  `[ctms.<flavor>.contracts_config].diamond_cut_data`;
- `forceDeploymentsData` bytes equal
  `[ctms.<flavor>.contracts_config].force_deployments_data`.

Then decode `diamondCut.initCalldata` as:

```solidity
struct InitializeDataNewChain {
  bytes32 l2BootloaderBytecodeHash;
  bytes32 l2DefaultAccountBytecodeHash;
  bytes32 l2EvmEmulatorBytecodeHash;
}
```

Check the three hashes against `AllContractsHashes.json`:

- `Bootloader`
- `system-contracts/DefaultAccount`
- `EvmEmulator`

Then decode `forceDeploymentsData` as the v31 `FixedForceDeploymentsData`
struct from
`l1-contracts/contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol`.
The raw bytes can be decoded with:

```bash
cast decode-abi \
  "f()((uint256,uint256,uint256,address,bytes32,address,uint256,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,address,address,address,address,bytes32))" \
  <force_deployments_data_hex>
```

Verify each field:

- `l1ChainId` equals RPC chain ID;
- `eraChainId` equals the matrix Era chain ID, even when the reviewed CTM
  flavor is ZKsync OS (PUVT skips this check when `--era-chain-id` is not
  supplied; verify manually when the tool flag is absent);
- `gatewayChainId` is recorded; PUVT logs it as informational but does not
  assert the value — verify manually that it matches the intended Gateway
  topology;
- `l1AssetRouter` equals `l1_asset_router_proxy`;
- `l2TokenProxyBytecodeHash` maps to `l1-contracts/BeaconProxy`;
- `aliasedL1Governance` equals the L1-to-L2 alias of the actual governance
  executor: the PUH proxy for PUH-governed environments, otherwise the
  Governance owner/executor address used by the artifact. PUVT verifies this
  when `aliased_protocol_upgrade_handler_proxy` is present in the address book;
  when it is absent (non-PUH environments), PUVT issues a warning and logs the
  observed value — verify manually in that case;
- `maxNumberOfZKChains` is `100`;
- every `*BytecodeInfo` field maps to the expected v31 L2/core contract for
  the CTM flavor;
- `l2SharedBridgeLegacyImpl` and `l2BridgedStandardERC20Impl` are zero;
- `aliasedChainRegistrationSender` equals the L1-to-L2 alias of
  `Bridgehub.chainRegistrationSender()`;
- `dangerousTestOnlyForcedBeacon` is zero;
- `zkTokenAssetId` equals the matrix ZK token asset ID.

Expected `*BytecodeInfo` mappings:

| Field                           | Expected file                                                                                  |
| ------------------------------- | ---------------------------------------------------------------------------------------------- |
| `bridgehubBytecodeInfo`         | `l1-contracts/L2Bridgehub`                                                                     |
| `l2AssetRouterBytecodeInfo`     | `l1-contracts/L2AssetRouter`                                                                   |
| `l2NtvBytecodeInfo`             | `l1-contracts/L2NativeTokenVault` for Era, `l1-contracts/L2NativeTokenVaultZKOS` for ZKsync OS |
| `messageRootBytecodeInfo`       | `l1-contracts/L2MessageRoot`                                                                   |
| `chainAssetHandlerBytecodeInfo` | `l1-contracts/L2ChainAssetHandler`                                                             |
| `interopCenterBytecodeInfo`     | `l1-contracts/InteropCenter`                                                                   |
| `interopHandlerBytecodeInfo`    | `l1-contracts/InteropHandler`                                                                  |
| `assetTrackerBytecodeInfo`      | `l1-contracts/L2AssetTracker`                                                                  |
| `beaconDeployerInfo`            | `l1-contracts/UpgradeableBeaconDeployer`                                                       |
| `baseTokenHolderBytecodeInfo`   | `l1-contracts/BaseTokenHolder`                                                                 |

Do not stop at the hex equality against TOML. The decoded fields above are the
non-self-referential proof.

## Step 9: Verify `setNewVersionUpgrade`

Decode:

```bash
cast calldata-decode \
  "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256,address)" \
  <call_data>
```

For the CTM flavor being reviewed:

- `oldProtocolVersion` equals the CTM TOML value;
- CTM TOML old version is Era `0.29.4` or ZKsync OS `0.30.1`;
- when L1 RPC is available, `oldProtocolVersion` equals the current on-chain
  CTM `protocolVersion()`;
- `oldProtocolVersionDeadline` is `uint256.max`;
- `newProtocolVersion` equals the CTM TOML value;
- CTM TOML new version is `0.31.0`;
- `verifier` equals `[ctms.<flavor>.state_transition].verifier_addr`;
- `abi.encode(diamondCut)` equals `[ctms.<flavor>].chain_upgrade_diamond_cut`;
- `diamondCut.initAddress` equals
  `[ctms.<flavor>.state_transition].default_upgrade_addr`;
- `diamondCut.initCalldata` decodes as `DefaultUpgrade.upgrade(ProposedUpgrade)`.

Facet cuts must be reconstructed, not eyeballed. Use the representative chain
diamond for the same CTM flavor:

```bash
cast call <bridgehub> "getZKChain(uint256)(address)" <representative_chain_id> \
  --rpc-url <l1_rpc_url> --block <review_block>
cast call <bridgehub> "chainTypeManager(uint256)(address)" <representative_chain_id> \
  --rpc-url <l1_rpc_url> --block <review_block>
cast call <diamond> "facets()((address,bytes4[])[])" \
  --rpc-url <l1_rpc_url> --block <review_block>
cast call <diamond> "isFacetFreezable(address)(bool)" <facet> \
  --rpc-url <l1_rpc_url> --block <review_block>
```

Then verify:

- `Remove` operations come before `Add` operations;
- `Remove` operations use zero facet address;
- `Replace` and invalid actions are blockers;
- removed selectors match the current facets of a representative chain diamond
  on the reviewed CTM and old protocol version;
- added facets match the expected v31 facet addresses from the CTM artifact;
- added selectors are derived from the reviewed v31 facet ABIs/runtime bytecode;
- exclude the tooling-only `getName()` selector `0x17d7de7c` from facet-cut
  comparison;
- `isFreezable` values match the reviewed v31 facet table and the old diamond
  state for removed selectors.

If no representative chain can be inspected, record the gap. Do not claim exact
facet-cut verification.

## Step 10: Verify `ProposedUpgrade`

From `diamondCut.initCalldata`, decode
`DefaultUpgrade.upgrade(ProposedUpgrade)` using the v31 upgrade structs from
the reviewed commit. The relevant structs and constants live under
`l1-contracts/contracts/upgrades/`, especially `BaseZkSyncUpgrade.sol`,
`DefaultUpgrade.sol`, `L2UpgradeTxLib.sol`, and `L2V31Upgrade.sol`.

Useful decode signatures:

```bash
cast calldata-decode \
  "upgrade(((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes32,bytes32,bytes32,address,(bytes32,bytes32,bytes32),bytes,bytes,uint256,uint256))" \
  <default_upgrade_init_calldata>

cast calldata-decode \
  "forceDeployAndUpgrade((bytes32,address,bool,uint256,bytes)[],address,bytes)" \
  <l2_tx_data_for_era>

cast calldata-decode \
  "forceDeployAndUpgradeUniversal((uint8,bytes,address)[],address,bytes)" \
  <l2_tx_data_for_zksync_os>

cast calldata-decode "upgrade(bool,address,bytes,bytes)" <inner_l2_v31_upgrade_calldata>
```

Check the outer `ProposedUpgrade`:

- `newProtocolVersion` is `0.31.0`;
- bootloader hash maps to `Bootloader`;
- default account hash maps to `system-contracts/DefaultAccount`;
- EVM emulator hash maps to `EvmEmulator`;
- `verifier` equals the CTM verifier address;
- verifier params are zero;
- `l1ContractsUpgradeCalldata` is empty;
- `postUpgradeCalldata` is empty;
- `upgradeTimestamp` is zero.

Check `l2ProtocolUpgradeTx`:

| Field                    | Expected                                      |
| ------------------------ | --------------------------------------------- |
| `from`                   | L2 force deployer `0x8007`                    |
| `to`                     | L2 complex upgrader `0x800f`                  |
| `gasLimit`               | `72_000_000`                                  |
| `gasPerPubdataByteLimit` | `800`                                         |
| `maxFeePerGas`           | zero                                          |
| `maxPriorityFeePerGas`   | zero                                          |
| `paymaster`              | zero                                          |
| `nonce`                  | new protocol minor version, `31` for `0.31.0` |
| `value`                  | zero                                          |
| `reserved`               | four zero words                               |
| `signature`              | empty                                         |
| `paymasterInput`         | empty                                         |
| `reservedDynamic`        | empty                                         |

Then classify `tx.data`:

- Era path: `txType = 254` and `tx.data` decodes as
  `IComplexUpgrader.forceDeployAndUpgrade(...)`;
- ZKsync OS path: `txType = 126` and `tx.data` decodes as
  `IComplexUpgrader.forceDeployAndUpgradeUniversal(...)`.

For both paths:

- `factoryDeps` contain exactly the expected v31 bytecode set for that path;
- no duplicate factory dep exists;
- every factory dep hash maps to the expected file in `AllContractsHashes.json`;
- every factory dep is published in `BytecodesSupplier` when an L1 RPC and
  supplier address are available;
- the delegate target is the expected v31 upgrade contract address;
- the inner `IL2V31Upgrade.upgrade(...)` calldata decodes and passes Step 11.

For Era `forceDeployAndUpgrade(...)`, verify the force deployment list against
the expected v31 Era system/core contract set. Important checks include:

- every expected system/core contract address is present exactly once;
- bytecode hashes map to the expected files;
- value is zero;
- constructor input is empty except for `L2ChainAssetHandler`;
- `L2ChainAssetHandler` constructor input decodes to the matrix L1 chain ID,
  aliased owner, L2 Bridgehub, L2 AssetRouter, and L2 MessageRoot.

For ZKsync OS `forceDeployAndUpgradeUniversal(...)`, verify against the
expected v31 ZKsync OS fixed-address core/system contract set:

- every expected fixed-address core/system contract entry is present;
- each entry has the expected upgrade type, either system proxy upgrade or
  unsafe force deployment;
- each `deployedBytecodeInfo` maps to the expected deployed bytecode hash;
- the L2V31Upgrade delegate deployment exists exactly once;
- the delegate address equals ZKsync CREATE2 derivation from L2 CREATE2
  factory `0x0000000000000000000000000000000000010000`, zero salt, the
  reviewed `l1-contracts/L2V31Upgrade` bytecode hash, and
  `keccak256("")` constructor input hash.

## Step 11: Verify `IL2V31Upgrade.upgrade`

Decode the inner calldata from Step 10 as `IL2V31Upgrade.upgrade(...)`.

Check:

- `_isZKsyncOS` is `false` for Era CTM and `true` for ZKsync OS CTM;
- `_ctmDeployer` equals `ctm_deployment_tracker_proxy`;
- `_fixedForceDeploymentsData` bytes equal the CTM TOML
  `force_deployments_data`;
- decoded `_fixedForceDeploymentsData` passes the field-by-field checks from
  Step 8;
- `_additionalForceDeploymentsData` is empty.

Any nonempty additional force deployment template is a blocker unless the
reviewed source and phase-order/rollout command evidence explicitly expect it.

## Step 12: Verify Prepare Deployment Provenance

This step ties prepare bundle calldata to the deployed contracts referenced by
Stages 0-2.

Using `executed-bundles.json`, inspect every transaction whose `to` equals the
reviewed CREATE2 factory.

For the standard deterministic deployment factory at `0x4e59...`, calldata is
always raw `salt ++ init_code`. Do not 4byte-decode the first four bytes:
they are part of the salt and can coincidentally look like a selector. Only
decode a top-level helper selector when the transaction target is a reviewed
helper contract, not the standard `0x4e59...` factory.

For raw factory calls:

- first 32 bytes of `data` are the salt;
- salt is one of the reviewed CREATE2 salts;
- remaining bytes are init bytecode;
- init bytecode maps to a contract in `AllContractsHashes.json`;
- deployed address equals `keccak256(0xff ++ factory ++ salt ++ keccak256(init_code))[12:]`;
- constructor args decoded from init bytecode equal the expected args.

Split init bytecode from constructor args using the reviewed artifact for the
candidate contract. The Forge artifact `bytecode.object` is the creation-code
prefix; the suffix is ABI-encoded constructor args. If using
`AllContractsHashes.json` instead, compare against the `evmBytecodeHash` of the
creation prefix, not the deployed/runtime hash. Constructor args must then be
decoded with the reviewed constructor ABI and matched field-by-field.

For `Create2AndTransfer` deployments, the `Create2AndTransfer` bytecode appears
inside the raw `init_code` after the salt:

- outer salt matches the reviewed salt;
- inner `create2AndTransferParams(bytes bytecode, bytes32 salt, address owner)`
  salt matches;
- inner bytecode maps to `AllContractsHashes.json`;
- final contract address is derived through the intermediate
  `Create2AndTransfer` address using the standard CREATE2 formula;
- owner/temporary-owner assumptions are documented.

Then verify every named v31 deployment referenced by the artifact. For each
named address:

- there is exactly one matching deployment in the executed-bundles log;
- deployed bytecode file matches the expected file;
- constructor args match the reviewed source;
- proxy constructor args use the expected implementation, initial admin, and
  init calldata;
- live runtime code exists after replay.

Do not skip immutable-aware constructor checks. Runtime bytecode hashes alone
are not enough for contracts whose immutables depend on constructor args.

At minimum, v31 provenance must cover:

- core implementations: Bridgehub, L1AssetRouter, L1Nullifier,
  NativeTokenVault, AssetTracker, CTMDeploymentTracker, MessageRoot,
  ChainAssetHandler, ChainRegistrationSender, GovernanceUpgradeTimer, and EIP7702Checker;
- for Sepolia stage, MessageRoot may intentionally resolve to the
  `l1-contracts/L1MessageRootStageSepolia` implementation variant; this must
  come from the reviewed rollout source, not from a post-hoc label;
- per-CTM contracts: ChainTypeManager implementation, ValidatorTimelock
  proxy and implementation (implementation deployed by `CTMUpgrade_v31.s.sol`
  and referenced via `validator_timelock_implementation_addr` in the artifact),
  BytecodesSupplier proxy, PermissionlessValidator proxy, verifier pair,
  Dual/Testnet verifier, DiamondInit, L1GenesisUpgrade, settlement-layer
  default upgrade, and the six v31 facets;
- constructor or initializer args sourced from the reviewed artifact and live
  state: L1 chain ID, Bridgehub, WETH token, L1AssetRouter, L1Nullifier,
  MessageRoot, Era chain ID, Era diamond, governance owner/executor, CTM
  proxy, new protocol version, RollupDAManager, EIP7702Checker, `is_testnet`,
  and governance timer initial delay.

## Step 13: Verify Live State Invariants

Using L1 RPC at the review state point, before signing or before execution:

- `eth_chainId` equals the intended L1;
- Bridgehub address equals the matrix Bridgehub proxy;
- registered chain IDs and CTM mappings match the matrix chain inventory;
- every CTM in the artifact has a representative chain at the matrix old
  protocol version, or the missing representative is recorded;
- every chain using a reviewed CTM has the matrix old protocol version before
  upgrade;
- proxy admin slots for v31 proxies match `transparent_proxy_admin`;
- `L1AssetRouter.nativeTokenVault()` equals the matrix NTV proxy;
- `L1AssetRouter.legacyBridge()` equals the legacy bridge from the matrix core
  proxy/address sources when applicable;
- `AssetTracker` and `NativeTokenVault` ownership/wiring state is consistent
  with Stage 1;
- every CTM implementation's `PERMISSIONLESS_VALIDATOR()` equals the reviewed
  PermissionlessValidator proxy address from CTM deployment provenance,
  explicit address book, or artifact field when the artifact serializes it;
- `BytecodesSupplier` has published every L2 upgrade factory dep.

State changing between calldata generation and review can make calldata stale.
If relevant L1 state changed, require re-review from the new state point.

If the package has already been executed on stage, a fork, or a local
integration chain, also verify execution evidence at a post-state point:

- every Safe or EOA transaction hash has a successful L1 receipt;
- Safe nonce progression matches the signed order, when a real Safe execution
  was used;
- Stage 0 leaves `ChainAssetHandler.migrationPaused() == true` and each CTM
  timer with nonzero `deadline()` and `maxDeadline()`;
- Stage 1 leaves proxy implementations/admins and CTM upgrade params at the
  reviewed v31 values;
- Stage 2 leaves `ChainAssetHandler.migrationPaused() == false`, each reviewed
  CTM `protocolVersion()` at v31, and each `UpgradeStageValidator` call
  `checkProtocolUpgradePresence()` / `checkMigrationsUnpaused()` succeeds;
- when the legacy-GW decommission prefix was present, `Bridgehub.settlementLayerStatus(old_gw_chain_id)` is `false`;
- when `[new_gateway]` was present, `Bridgehub.settlementLayerStatus(new_gw_chain_id)` is `true`;
- every Gateway priority transaction has `NewPriorityRequest` /
  `NewPriorityRequestId` evidence from the target chain diamond and matching
  L2 execution or proof status, when the reviewed environment exposes it.

## Step 14: Verify Stage 2

Stage 2 unpauses migration and checks upgrade presence after chains are
upgraded. Its shape is: an optional legacy-GW decommission prefix, followed by
the canonical section, followed by a mandatory 16-call Gateway bring-up block
(v31 PUVT requires `[new_gateway]`).

### Legacy-GW decommission prefix (conditional)

When `upgrade-envs/permanent-values/<env>.toml` has a `[legacy_gateway]` section,
Stage 2 starts with `M + 1` decommission calls where `M` is the number of
`[[legacy_gateway.chain_intervals]]` entries:

| Index     | Target                      | Selector                                                                                                           | Extra checks                                    |
| --------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------- |
| `0..M-1`  | `chain_asset_handler_proxy` | `setHistoricalMigrationInterval(uint256,uint256,(uint256,uint256,uint256,uint256,uint256,bool))`                   | one per `[[legacy_gateway.chain_intervals]]`    |
| `M`       | `bridgehub_proxy`           | `setSettlementLayerStatus(uint256,bool)`                                                                           | second arg is `false`; blacklists the old GW    |

Decode each `setHistoricalMigrationInterval` call:

```bash
cast calldata-decode \
  "setHistoricalMigrationInterval(uint256,uint256,(uint256,uint256,uint256,uint256,uint256,bool))" \
  <call_data>
```

Match the decoded arguments against the corresponding
`[[legacy_gateway.chain_intervals]]` entry in `permanent-values/<env>.toml`:
- arg 1 (`_chainId`) = `chain_id`;
- arg 2 (`_migrationNumber`) = `0` (always zero in the current flow);
- `interval.migrateToGWBatchNumber` = `migrate_to_sl_batch`;
- `interval.migrateFromGWBatchNumber` = `migrate_from_sl_batch`;
- `interval.settlementLayerBatchLowerBound` = `sl_batch_lower_bound`;
- `interval.settlementLayerBatchUpperBound` = `sl_batch_upper_bound`;
- `interval.settlementLayerChainId` = `legacy_gateway.chain_id`;
- `interval.isActive` = `false`.

The `setSettlementLayerStatus` call must use `legacy_gateway.chain_id` as the
first argument and `false` as the second.

**PUVT coverage:** PUVT fully decodes and verifies every argument of each
`setHistoricalMigrationInterval` call against the corresponding
`[[legacy_gateway.chain_intervals]]` entry (all eight fields, including
`isActive == false` and `migrationNumber == 0`). PUVT also verifies that the
`setSettlementLayerStatus` call uses `legacy_gateway.chain_id` as the first
argument and `false` as the second. Mismatches are hard errors. The manual
decoding instructions above are for independent confirmation.

If `[legacy_gateway]` is absent, the decommission prefix is not present.
Record its absence as expected; any `setHistoricalMigrationInterval` or
blacklisting `setSettlementLayerStatus` call in a non-legacy-GW package is a
blocker.

Let `D = M + 1` when the prefix is present, `D = 0` when absent.

### Canonical section

| Index           | Target                          | Selector                         | Extra checks |
| --------------- | ------------------------------- | -------------------------------- | ------------ |
| `D`             | `chain_asset_handler_proxy`     | `unpauseMigration()`             | zero value   |
| `D + 1 + 2*i`   | CTM `i` upgrade stage validator | `checkProtocolUpgradePresence()` | one per CTM  |
| `D + 2 + 2*i`   | CTM `i` upgrade stage validator | `checkMigrationsUnpaused()`      | one per CTM  |

Canonical section count is `1 + 2 * N` (not counting the decommission prefix).

Total Stage 2 expected call count is `D + 1 + 2 * N + 16`. Any extra or
missing call is a blocker.

**Note:** v31 PUVT requires `[new_gateway]` to be present. A missing gateway
block is a hard error — PUVT does not accept a 12-call (no-gateway) Stage 2.
Complete the Gateway appendix after the canonical Stage 2 checks.

## Step 15: Verify Governance Wrappers

If signers receive governance Safe transactions or proposal calldata rather
than raw stage calls, decode both layers.

For the standard Governance contract flow emitted by
`AdminFunctions.governanceExecuteCalls(bytes,address)`, the Safe bundle should
contain Governance calls derived from the reviewed stage `Call[]`:

- `scheduleTransparent((Call[] calls, bytes32 predecessor, bytes32 salt), uint256 delay)`;
- `execute((Call[] calls, bytes32 predecessor, bytes32 salt))` when delay is
  zero;
- or `executeInstant((Call[] calls, bytes32 predecessor, bytes32 salt))` only
  when the reviewed flow intentionally uses the Security Council instant path.

For each governance operation:

- `operation.calls` equals the decoded reviewed stage `Call[]` byte-for-byte;
- `operation.predecessor` is the reviewed predecessor, normally zero for this
  flow;
- `operation.salt` is the reviewed salt, normally zero for this flow;
- `delay` matches the reviewed governance script input;
- operation ID/hash recomputed as
  `keccak256(abi.encode(Operation({calls, predecessor, salt})))` from
  `l1-contracts/contracts/governance/Governance.sol::hashOperation` matches
  the scheduled/executed operation;
- scheduled timestamp, ready timestamp, execution timestamp, and delay
  compliance are checked when reviewing executed stage transactions;
- the Safe bundle signer/target matches the matrix governance owner or
  Security Council executor for that operation.

For any external governance proposal wrapper:

1. Decode the outer Safe/governance transaction.
2. Extract proposal targets, values, calldatas, predecessor/salt/description
   hash, and executor if applicable.
3. Recompute the proposal ID using the reviewed governance contract's formula.
4. Decode any nested `governanceExecuteCalls(bytes,address)`,
   `governanceExecuteCallsDirect(bytes,address)`, or protocol-upgrade-handler
   payload.
5. Confirm the nested stage bytes exactly equal the reviewed
   `[governance_calls].stage{0,1,2}_calls`.
6. Confirm proposal target/executor/governance addresses match the address book.

Do not approve a proposal if only the outer proposal ID matches. The nested
calldata must be decoded and matched to the stage calls.

## Step 16: Verify Chain-Level Phase Bundles

If the package includes per-chain phases such as `set_upgrade_timestamp/` or
`chain_upgrade/`, review them separately from ecosystem Stage 0-2.

Use the per-chain rows in the Value Source Matrix before decoding. In
particular, identify the reviewed `chain_id`, chain admin or owner wrapper,
ServerNotifier, timestamp, protocol version, and chain diamond from phase
metadata, decoded calldata, and the exact rollout command evidence.

For `chain.set-upgrade-timestamp`:

- expect one or more timestamp transactions listed by phase metadata or rollout
  command evidence;
- top-level target is the chain admin or chain-admin owner wrapper identified
  from the matrix sources;
- a direct top-level call may be
  `setUpgradeTimestamp(uint256,uint256)` (`0xe2a9d554`) on
  `ChainAdminOwnable`;
- if wrapped through `ChainAdmin.multicall((address,uint256,bytes)[],bool)`,
  decode every inner call and require `_requireSuccess = true`;
- wrapper inner calls may be `setUpgradeTimestamp(uint256,uint256)` on the
  chain admin, or `ServerNotifier.setUpgradeTimestamp(uint256,uint256,uint256)`
  (`0x26079da9`);
- protocol version is the reviewed v31 packed version;
- timestamp matches phase metadata or rollout command evidence and is not zero;
- for `ServerNotifier.setUpgradeTimestamp`, the chain ID argument equals the
  reviewed chain ID;
- value is zero.

```bash
cast calldata-decode "multicall((address,uint256,bytes)[],bool)" <call_data>
cast calldata-decode "setUpgradeTimestamp(uint256,uint256)" <inner_data>
cast calldata-decode "setUpgradeTimestamp(uint256,uint256,uint256)" <inner_data>
```

For `chain.upgrade`:

- expect one upgrade transaction for the reviewed chain unless phase metadata
  or rollout command evidence explicitly lists more;
- top-level target is the chain admin or chain-admin owner wrapper identified
  from the matrix sources;
- if wrapped through `ChainAdmin.multicall((address,uint256,bytes)[],bool)`,
  decode every inner call and require `_requireSuccess = true`;
- inner target is the chain diamond from the matrix chain inventory row;
- inner calldata is `upgradeChainFromVersion(...)`;
- use the legacy two-argument signature for pre-v31 chains and the
  three-argument signature only when the reviewed chain already exposes it;
- old protocol version equals the chain's current on-chain version;
- diamond cut equals the CTM upgrade cut for that old version;
- decode the diamond cut init calldata and apply the `ProposedUpgrade` and
  `IL2V31Upgrade.upgrade` payload checks from Steps 10 and 11.

```bash
cast calldata-decode "upgradeChainFromVersion(uint256,((address,uint8,bool,bytes4[])[],address,bytes))" <inner_data>
cast calldata-decode "upgradeChainFromVersion(address,uint256,((address,uint8,bool,bytes4[])[],address,bytes))" <inner_data>
```

The timestamp phase must appear before a chain upgrade when the rollout relies
on nodes observing an upgrade timestamp.

## Step 17: Stage3, If Included

Stage3 is separate from the Stage 0-2 governance proof unless its transaction is
included in the reviewed package. If stage3 calldata is present:

- identify the exact Forge script or `protocol_ops ecosystem stage3` command
  that produced it;
- source the authoritative token list using the Stage3 row in the Value Source
  Matrix; if no token list is available, token-list and balance checks are
  gaps;
- for `protocol_ops ecosystem stage3`, expect calls emitted by
  `EcosystemUpgrade_v31.stage3(bridgehub)`:
  `addLegacyTokenToBridgedTokensList(address)` (`0x2e270c4c`) on NTV for each
  legacy token needing NTV list registration, and
  `registerLegacyToken(bytes32)` (`0xf711f28a`) on AssetTracker for each
  migrated asset ID;
- decode every top-level transaction target and selector;
- verify Bridgehub, AssetRouter, NativeTokenVault, AssetTracker, and token list
  against the reviewed environment;
- verify each registered token asset ID and token address against the rollout
  token list, with no extras;
- verify NativeTokenVault and AssetTracker balances or chain balances before
  and after migration for every token/chain touched;
- verify stage3 ordering matches the global phase-order evidence, especially
  when registration must happen after Stage 1 wiring and before per-chain
  upgrades;
- verify it does not include unexpected asset registrations, balance moves, or
  owner/admin changes;
- record simulation or execution evidence separately from the Stage 0-2 proof.

```bash
cast calldata-decode "addLegacyTokenToBridgedTokensList(address)" <call_data>
cast calldata-decode "registerLegacyToken(bytes32)" <call_data>
```

## Appendix: Sepolia Stage Anchors

Use these only for Sepolia stage review. They are repo-local anchors in the
reviewed commit.

- stage generation and PUVT replay script:
  `l1-contracts/test/anvil-interop/regen-and-verify-stage.sh`
- stage v31 input:
  `l1-contracts/upgrade-envs/v0.31.0-interopB/stage.toml`
- stage permanent values:
  `l1-contracts/upgrade-envs/permanent-values/stage.toml`
- PUVT command implementation:
  `protocol-ops/src/commands/ecosystem/verify_upgrade.rs`

## Appendix: Gateway Stage 2 Bring-Up

Use this appendix only when `[new_gateway]` is present.

This block is appended by `write_merged_ecosystem_toml` from the output of
`GatewayVotePreparation.s.sol`. It starts with a `registerLegacyToken` prefix
injected by the merge step, then a `setSettlementLayerStatus(newGwChainId, true)`
call at offset 1 that whitelists the new GW chain ID as a valid settlement layer,
then the bring-up priority transactions interleaved with base-token approvals.

Expected 16-call block:

| Offset | Target                         | Selector                                     | Required check                                                                    |
| ------ | ------------------------------ | -------------------------------------------- | --------------------------------------------------------------------------------- |
| `0`    | `asset_tracker_proxy`          | `registerLegacyToken(bytes32)`               | asset ID matches the matrix ZK token asset ID                                     |
| `1`    | `bridgehub_proxy`              | `setSettlementLayerStatus(uint256,bool)`     | second arg is `true`; whitelists the new GW chain ID as a valid settlement layer  |
| `2`    | base token                     | `approve(address,uint256)`                   | spender is L1 AssetRouter; all 6 approve targets must be the same base token      |
| `3`    | `bridgehub_proxy`              | `requestL2TransactionDirect(...)`            | inner `addChainTypeManager(new_gw_ctm)` to L2 Bridgehub `0x10002`                 |
| `4`    | `l1_asset_router_proxy`        | `setAssetDeploymentTracker(bytes32,address)` | asset ID and tracker address match `[new_gateway]`                                |
| `5`    | `ctm_deployment_tracker_proxy` | `registerCTMAssetOnL1(address)`              | argument matches `[new_gateway]` CTM asset                                        |
| `6`    | base token                     | `approve(address,uint256)`                   | same approve target family                                                        |
| `7`    | `bridgehub_proxy`              | `requestL2TransactionTwoBridges(...)`        | decode and verify set-asset-handler payload                                       |
| `8`    | base token                     | `approve(address,uint256)`                   | same approve target family                                                        |
| `9`    | `bridgehub_proxy`              | `requestL2TransactionTwoBridges(...)`        | decode and verify GW CTM registration payload                                     |
| `10`   | base token                     | `approve(address,uint256)`                   | same approve target family                                                        |
| `11`   | `bridgehub_proxy`              | `requestL2TransactionDirect(...)`            | inner `acceptOwnership()` on GW RollupDAManager                                   |
| `12`   | base token                     | `approve(address,uint256)`                   | same approve target family                                                        |
| `13`   | `bridgehub_proxy`              | `requestL2TransactionDirect(...)`            | inner `acceptOwnership()` on GW ServerNotifier                                    |
| `14`   | base token                     | `approve(address,uint256)`                   | same approve target family                                                        |
| `15`   | `bridgehub_proxy`              | `requestL2TransactionDirect(...)`            | inner `setGatewaySettlementFee(...)` on GW asset tracker                          |

The approve calls are at offsets 2, 6, 8, 10, 12, 14 (six total). The priority
transaction calls are at offsets 3, 7, 9, 11, 13, 15 (six total).

Use the Gateway row in the Value Source Matrix for chain ID, CTM asset,
base-token asset ID, settlement fee, L2 gas limit, pubdata limit, and refund
recipient.

**Approve calls:** PUVT decodes each `approve` call, verifies the `spender`
equals `l1_asset_router_proxy`, and checks that all six share the same token
target.

For every Gateway priority transaction:

- chain ID is the new Gateway chain ID; PUVT verifies all six share the same
  chain ID;
- L2 gas limit equals `MAX_PRIORITY_TX_GAS_LIMIT` (72,000,000) and pubdata
  limit equals `L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT` (800); PUVT verifies
  these against hardcoded constants;
- `factoryDeps` are empty unless explicitly expected;
- refund recipient matches `[new_gateway]` or the reviewed env config.

**PUVT coverage:** PUVT deep-decodes inner payloads for all six priority
transactions and both two-bridge calls:

- Offsets 3, 11, 13, 15: verifies `l2Contract` is L2 Bridgehub `0x10002` (offset 3),
  GW RollupDAManager (offset 11), GW ServerNotifier (offset 13), or GW asset
  tracker `0x10010` (offset 15); verifies the inner `l2Calldata` selector for
  each; also verifies the GW CTM address argument of the offset 3
  `addChainTypeManager` call.
- Offset 7 (`requestL2TransactionTwoBridges`): verifies `secondBridgeAddress`
  equals `l1_asset_router_proxy`; decodes `secondBridgeCalldata` and verifies
  asset ID equals the representative CTM asset ID and handler equals
  `L2_CHAIN_ASSET_HANDLER_ADDR`.
- Offset 9 (`requestL2TransactionTwoBridges`): verifies `secondBridgeAddress`
  equals `ctm_deployment_tracker_proxy`; decodes `secondBridgeCalldata` and
  verifies both L1 CTM and L2 CTM addresses.
- Offset 15 (`requestL2TransactionDirect`): decodes inner calldata and verifies
  the settlement fee value matches the reviewed env config.

Manually verify the refund recipient using the Gateway row in the Value Source
Matrix. L2 gas limit and pubdata limit are verified by PUVT against hardcoded
constants.

## Final Evidence Table

Fill one row per handoff item, derived evidence source, calldata block, or
nested blob. For full pre-signing or post-execution sign-off, first add rows
showing where each live-state or replay-dependent conclusion came from.

| ID                                             | Artifact path | Decoded as                   | Expected source                        | Result | Notes |
| ---------------------------------------------- | ------------- | ---------------------------- | -------------------------------------- | ------ | ----- |
| `handoff.commit`                               |               | source anchor                | reviewed `era-contracts` commit        |        |       |
| `handoff.calldata`                             |               | calldata set                 | provided files / ordered calldata list |        |       |
| `evidence.phase-order`                         |               | global order                 | package / wrapper / command log        |        |       |
| `evidence.signers`                             |               | Safe owners / threshold      | block-pinned Safe state                |        |       |
| `evidence.pre-state`                           |               | live-state anchor            | block-pinned RPC / snapshot            |        |       |
| `evidence.assets`                              |               | token and asset inventory    | Value Source Matrix asset rows         |        |       |
| `manifest[0]`                                  |               | bundle metadata              | manifest/Safe shape                    |        |       |
| `safe[0].tx[0]`                                |               | top-level transaction        | manifest/address book                  |        |       |
| `stage0.call[0]`                               |               | `pauseMigration()`           | Stage 0 table                          |        |       |
| `stage1.call[block_start+3]`                         |               | `setChainCreationParams`           | matrix CTM/genesis rows                |        |       |
| `stage1.call[block_start+4].diamondCut.initCalldata` |               | `DefaultUpgrade.upgrade`           | reviewed v31 source                    |        |       |
| `stage1.call[block_start+5]`                         |               | `ValidatorTimelock upgrade`        | matrix `validator_timelock_*` rows     |        |       |
| `proposedUpgrade.l2ProtocolUpgradeTx.data`           |               | complex upgrader call              | reviewed v31 source                    |        |       |
| `fixedForceDeploymentsData`                          |               | struct fields                      | matrix chain/token/bytecode rows       |        |       |
| `stage2.decommission[0..M-1]`                        |               | `setHistoricalMigrationInterval`   | `[[legacy_gateway.chain_intervals]]`   |        |       |
| `stage2.decommission[M]`                             |               | `setSettlementLayerStatus(id,false)` | `legacy_gateway.chain_id`            |        |       |
| `stage2.gateway[7]`                                  |               | two-bridges priority tx            | matrix Gateway row                     |        |       |
| `governance.wrapper`                           |               | proposal envelope            | governance source                      |        |       |
| `chain.timestamp`                              |               | `setUpgradeTimestamp`        | matrix per-chain phase values          |        |       |
| `chain.upgrade`                                |               | `upgradeChainFromVersion`    | matrix per-chain and CTM rows          |        |       |
| `stage3.tx[0]`                                 |               | token registration/migration | matrix Stage3 token-list row           |        |       |

## Blockers

Treat any of these as a signing blocker:

- unknown selector or undecoded nested calldata;
- claimed sign-off level is not supported by the handoff plus derived evidence;
- unexpected target, signer, executor, or chain ID;
- nonzero `value` without explicit approval;
- extra, missing, duplicated, or reordered transaction;
- Safe manifest does not match Safe files;
- provided stage bytes do not match governance wrapper bytes;
- protocol version mismatch;
- CTM flavor mismatch;
- proxy upgrade points at an unexpected implementation;
- per-CTM Stage 1 block is missing the ValidatorTimelock upgrade at `block_start + 5`, or its
  proxy/implementation/proxy-admin args do not match the address book;
- proxy admin slot mismatch;
- CREATE2 salt, deployed address, bytecode file, or constructor args mismatch;
- bytecode hash missing from reviewed `AllContractsHashes.json`;
- factory dep missing, duplicated, unpublished, or mapped to the wrong file;
- wrong L2 upgrade tx type, sender, target, nonce, gas, fee, or reserved field;
- nonempty unexpected post-upgrade, L1-contract-upgrade, or additional force
  deployment calldata;
- dangerous test-only beacon is nonzero;
- ZK token asset ID is zero or does not match the matrix value;
- legacy-GW decommission prefix present in a non-legacy-GW package, or absent
  in a legacy-GW package; any decoded `setHistoricalMigrationInterval` argument
  does not match the corresponding `[[legacy_gateway.chain_intervals]]` entry;
  `setSettlementLayerStatus` second argument is not `false`;
- tool cross-check warnings that the reviewer cannot independently close.
