# Deploying a new ecosystem

This document describes how a fresh ecosystem is brought up on an L1: what an ecosystem consists
of, which contracts each step deploys, who ends up owning them, where the inputs come from, and
which tools drive it. It is the operational counterpart of the architecture pages: the on-chain
mechanics of chain creation are in {protocol-docs/chain-lifecycle.md}, the roles of the contracts
in {protocol-docs/system/README.md}. Upgrading an ecosystem that already exists is a separate
pipeline, described in {protocol-docs/ecosystem-upgrade.md}.

## What an ecosystem is

An ecosystem is one `L1Bridgehub` together with the core contracts wired to it, one or more chain
type managers (CTMs) registered on it, and the chains created through those CTMs. Everything the
chains of an ecosystem share on L1 is scoped to that Bridgehub:

- the canonical bridge (`L1AssetRouter`, `L1NativeTokenVault`, `L1Nullifier`, `L1InteropHandler`),
  which custodies every L1-native asset bridged into any chain of the ecosystem;
- the `L1MessageRoot`, which aggregates the chains' batch roots and anchors interop and withdrawal
  proofs;
- per CTM, the verifier, facets, genesis definition and protocol version that all chains of that
  CTM run.

Two ecosystems deployed from the same code on the same L1 share none of this: they are separate
contract instances under separate governance, and a chain belongs to exactly one Bridgehub. A
private ecosystem is therefore exactly this deployment, done once, with its own owner. The public
ZKsync ecosystem contracts are not involved.

Interop between two chains exists only if both are registered on the same Bridgehub and have been
explicitly registered for interop with each other (see "Interop registration" below); it is never a
side effect of creating a chain.

## Layers and the tooling

A deployment has three layers, each with its own Forge script and its own `protocol_ops`
subcommand. `protocol_ops` never broadcasts to the target L1 itself: it runs the scripts on a
temporary Anvil fork of `--l1-rpc-url`, records every transaction, and writes Safe Transaction
Builder bundles (one per consecutive run of transactions by the same signer) plus a `manifest.json`
into `--out`. Each bundle is then executed on the real L1 by its signer, in manifest order. For
bundles whose signer is an EOA whose key you hold, `protocol_ops ecosystem upgrade-broadcast
--manifest <out>/manifest.json --l1-rpc-url <l1> --key <addr>=<key>` sends them (it defaults to
`http://localhost:8545` without `--l1-rpc-url`, needs a `--key` for every signer in the manifest,
and signs each transaction directly), as does `protocol_ops dev execute-safe` for a single bundle.
Bundles whose signer is a multisig, such as an `owner_address` Safe, are imported into that
multisig's own transaction flow; see `protocol-ops/README.md` for the execution model.

| Layer | `protocol_ops` command                                     | Forge scripts                                                | Signers                                                       |
| ----- | ---------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------- |
| Hub   | `hub init` (also the first half of `ecosystem init`)       | `ecosystem/DeployL1CoreContracts.s.sol`, `AdminFunctions`    | deployer EOA; owner (accepts ownership)                       |
| CTM   | `ctm init` (also the second half of `ecosystem init`)      | `ctm/DeployCTM.s.sol`, `ecosystem/RegisterCTM.s.sol`         | deployer EOA; owner (accepts ownership, registers the CTM)    |
| Chain | `chain init` (CI: `generate-chain-init-calldata` workflow) | `ctm/RegisterZKChain.s.sol`, `chain/FinalizeChainInit.s.sol` | deployer EOA; Bridgehub admin owner; chain owner (ChainAdmin) |

All scripts live under `l1-contracts/deploy-scripts/`. They need the contracts built first (`yarn
da build:foundry && yarn sc build:foundry && yarn l1 build:foundry` from the repository root), since
chain creation embeds the compiled L2 built-ins as factory dependencies. An EraVM `chain init` that
deploys its L2 contracts (no `--skip-priority-txs`) also needs `yarn l2 build:foundry`, since it
reads `l2-contracts/zkout/`.

## Hub: the core contracts

`DeployL1CoreContracts.s.sol` deploys, through the deterministic CREATE2 factory:

- **Governance contracts.** `Governance` (the timelock that will own the ecosystem; its owner and
  security council come from the input), `ChainAdminOwnable` (the Bridgehub admin, owned by the
  configured owner), and a `ProxyAdmin` owned by `Governance` that administers every transparent
  proxy below.
- **Registry proxies.** `L1Bridgehub`, `L1ChainAssetHandler`, `L1MessageRoot`,
  `CTMDeploymentTracker`, `ChainRegistrationSender`.
- **Bridge proxies.** `L1Nullifier`, `L1AssetRouter`, `L1NativeTokenVault`, `L1InteropHandler`,
  plus the `BridgedStandardERC20` implementation and its `BridgedTokenBeacon` (owned by the
  configured owner) used for bridged-token deployments.

It then wires them: the asset router and nullifier learn the vault and the interop handler, the
vault registers ETH, and `L1Bridgehub.setAddresses` records the asset router, CTM deployment
tracker, message root, chain asset handler and chain registration sender. Finally it starts the
ownership hand-off: the Bridgehub, asset router, nullifier, interop handler, CTM deployment tracker
and chain asset handler are transferred (two-step) to `Governance`, the native token vault to the
configured owner, and `ChainAdminOwnable` is set as the Bridgehub's pending admin.
`ChainRegistrationSender` is initialized with the deployer as its owner and is not transferred.

`hub init` accepts part of the hand-off as the owner: `AdminFunctions.chainAdminAcceptAdmin`
accepts the Bridgehub admin role and `AdminFunctions.governanceAcceptOwnerAggregated` accepts the
pending ownership of the Bridgehub, asset router, nullifier, CTM deployment tracker and chain
asset handler on behalf of `Governance`. It does not complete the rest, so after `hub init` the
deployer EOA still owns three core contracts:

| Contract                  | State after `hub init`                          | Deployer can still                      | Manual step to complete the hand-off                                                                                                     |
| ------------------------- | ----------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `L1InteropHandler`        | owner: deployer, pending owner: `Governance`    | `pause()` withdrawal finalization       | `Governance` calls `acceptOwnership()` (signed by `owner_address`: `AdminFunctions.governanceAcceptOwner(governance, l1InteropHandler)`) |
| `L1NativeTokenVault`      | owner: deployer, pending owner: `owner_address` | `pause()` the vault                     | `owner_address` calls `acceptOwnership()` on the vault directly                                                                          |
| `ChainRegistrationSender` | owner: deployer, no pending owner               | nothing today (no owner-gated function) | the deployer calls `transferOwnership(governance)`, then `owner_address` runs `AdminFunctions.governanceAcceptOwner(governance, sender)` |

Until these are done the ownership table below does not hold. Making `hub init` perform them
itself is an open tooling follow-up.

Two inputs are immutable once deployed and therefore must be right the first time: the L1 WETH
address (baked into the asset router and vault implementations; resolved from the L1 chain id when
omitted, so `hub init` needs `--token-weth-address` on any other network) and the Era chain id
(default `270`). Note that `ctm init` and `ecosystem init` currently resolve the L1 network from
its chain id unconditionally and refuse to run on any L1 other than mainnet, Sepolia, Holesky or a
local Anvil (`L1Network::from_l1_rpc`); a private L1 needs a tooling change first.

## CTM: the chain type manager

`DeployCTM.s.sol` discovers the core addresses from the Bridgehub (`AddressIntrospector`) and
deploys one CTM for one VM type (`--vm-type zksyncos|eravm`):

- **Governance.** The hub's `Governance`, `ChainAdminOwnable` and `ProxyAdmin` are reused:
  always by `ecosystem init`, and by `ctm init` unless it is run with `--reuse-gov-and-admin false`,
  in which case the CTM gets its own set.
- **`ChainTypeManager`** (proxy) and the diamond it will clone for every chain: the `Admin`,
  `Getters`, `Mailbox`, `Executor`, `Committer` and `Migrator` facets and `DiamondInit`.
- **Verifiers.** The PLONK verifier and the main verifier for the VM; with `testnet_verifier` the
  main verifier is the testnet variant, which accepts unproven batches and must never be used on
  mainnet.
- **Upgrade contracts.** The VM's `DefaultUpgrade` (stored on the CTM via `setDefaultUpgrade`;
  verifier-only upgrades run it) and `L1GenesisUpgrade` (runs the genesis upgrade of every new
  chain).
- **Operator infrastructure.** `ValidatorTimelock`, `PermissionlessValidator`, `BytecodesSupplier`
  (all proxies) and `ServerNotifier` (proxy; pointed at the CTM), plus `EIP7702Checker` and
  `Multicall3` if the network lacks it.
- **Data availability.** `RollupDAManager` and the L1 DA validators a chain can pick from:
  `RollupL1DAValidator`, `BlobsL1DAValidatorZKsyncOS` (ZKsync OS only), `ValidiumL1DAValidator`,
  and an Avail validator (a real one when `avail_l1_da_validator` is configured, a dummy
  otherwise). The rollup pairs are whitelisted in the DA manager, which is what
  `makePermanentRollup` later restricts a chain to. They are whitelisted with the
  `BLOBS_AND_PUBDATA_KECCAK256` commitment scheme only, also on ZKsync OS, while a ZKsync OS chain
  in rollup mode commits with `BlobsZKSyncOS`. A ZKsync OS chain created with the default flags
  therefore cannot become a permanent rollup (see "Chain" below).

The chain creation parameters the CTM stores (`setChainCreationParams`: genesis upgrade, genesis
root, initial diamond cut, force deployment data) are built from `configs/genesis/<vm>/latest.json`
and from the compiled L2 built-ins. The ZKsync OS genesis file is produced by
`tools/zksync-os-genesis-gen` (the EraVM one is generated separately, by the zksync-era genesis
tooling) and is what the operator's node must be started with; deploying a CTM from a build whose bytecodes
do not match it produces chains whose genesis the node cannot reproduce.

`DeployCTM.s.sol` ends by starting five two-step ownership transfers: the CTM to `Governance`
(and `ChainAdminOwnable` as its pending admin), `ValidatorTimelock` to `owner_address`,
`ServerNotifier` to `ChainAdminOwnable`, and `RollupDAManager` to `Governance`.

`ctm init` then accepts two of them as the owner (`governanceAcceptOwner` on the CTM,
`chainAdminAcceptAdmin` for the CTM admin) and registers the CTM on the Bridgehub with
`RegisterCTM.s.sol`, a `Governance` operation of three calls: `L1Bridgehub.addChainTypeManager`,
`L1AssetRouter.setAssetDeploymentTracker` for the CTM's asset id, and
`CTMDeploymentTracker.registerCTMAssetOnL1`. The other three stay with the deployer EOA until they
are accepted by hand:

| Contract            | Pending owner       | Deployer can still                                                         | Manual step                                                                              |
| ------------------- | ------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `ValidatorTimelock` | `owner_address`     | `setExecutionDelay`                                                        | `owner_address` calls `acceptOwnership()`                                                |
| `ServerNotifier`    | `ChainAdminOwnable` | `setChainTypeManager`                                                      | `owner_address` has the `ChainAdminOwnable` call `acceptOwnership()` on it (`multicall`) |
| `RollupDAManager`   | `Governance`        | `updateDAPair`, i.e. whitelist DA pairs that `makePermanentRollup` accepts | `owner_address` runs `AdminFunctions.governanceAcceptOwner(governance, rollupDAManager)` |

As with the hub, making `ctm init` perform these itself is a tooling follow-up.

Run `ctm init` as part of `ecosystem init` for a fresh ecosystem. Run on its own against a hub
deployed by `hub init` (default `--reuse-gov-and-admin`), it signs the two acceptance steps as the
Bridgehub's `ChainAdminOwnable` contract instead of that contract's owner, so `chainAdminAcceptAdmin`
should revert on the `onlyOwner` `multicall` (derived from the code, not run). `ecosystem init`
passes the real owner.

The ZK token asset id (`--zk-token-asset-id`, or `zk_token_asset_id` of the env preset) must be
non-zero: it is passed to `InteropCenter.initL2` during every chain's genesis, which reverts on
zero, so the CTM deployment script rejects a zero id up front.

## Chain: registering and initializing a chain

`RegisterZKChain.s.sol`, run as the deployer, performs the L1 side of chain creation:

1. Deploys the chain's administration contracts: a `ChainAdminOwnable` owned by the chain owner
   (with no access-control restriction) and a `ProxyAdmin`, plus a per-chain `Governance`.
2. Registers the base token: on the `L1NativeTokenVault` if it is an ERC20 that is not registered
   yet, and its asset id on the Bridgehub through the Bridgehub admin (`addTokenAssetId`).
3. Calls `L1Bridgehub.createNewChain` through the Bridgehub admin. This is the transaction
   documented in {protocol-docs/chain-lifecycle.md#chain-creation-createnewchain}: the CTM deploys
   the diamond, runs `DiamondInit`, records the genesis upgrade transaction, and the Bridgehub
   registers the chain in the message root and, for a ZKsync OS chain only, seeds its genesis batch
   root.
4. Grants the operator addresses their `ValidatorTimelock` roles: the commit operator becomes the
   committer; the prove operator becomes the prover and also the precommitter, reverter and
   upgrader; on ZKsync OS a separate execute operator (`--execute-operator`, optional) becomes the
   executor. Without it, and always on EraVM, the prove operator executes too.
5. Sets the base-token price multiplier and, for a validium-priced chain, the validium pricing
   mode.
6. Sets the chain's pending admin to the new `ChainAdmin`.

`FinalizeChainInit.s.sol`, run as the chain owner through that `ChainAdmin`, then accepts the admin
role and configures what only the chain admin can set: it unpauses deposits (unless
`--pause-deposits`), sets the token multiplier setter for a custom base token, sets the DA
validator pair (`--l1-da-validator`, one of the validators the CTM deployed, plus the L2
commitment scheme derived from `--da-mode`), sets the pubdata content when the mode implies a
non-default one, and optionally makes the chain a permanent rollup (`--make-permanent-rollup`,
irreversible; incompatible with logs-only pubdata). On ZKsync OS, `--make-permanent-rollup` with
the default `--da-mode rollup` currently reverts with `InvalidDAForPermanentRollup`: the chain
commits with `BlobsZKSyncOS`, a scheme the CTM's `RollupDAManager` has not whitelisted (see "CTM"
above). See
{protocol-docs/system/contracts/settlement_contracts/data_availability/README.md} for what the
DA choices mean and {protocol-docs/system/contracts/chain_management/admin_role.md} for the
admin role.

On EraVM chains `chain init` additionally deploys the L2 contracts through priority transactions
(`ConsensusRegistry`, `Multicall3`, `TimestampAsserter`), unless `--skip-priority-txs` is set; it
enables the EVM emulator only with `--evm-emulator` and deploys the testnet paymaster only with
`--deploy-paymaster`. ZKsync OS chains get all of their L2 built-ins from genesis and skip this
block.

### Interop registration

Creating a chain does not make it reachable for interop. `chain init --register-for-interop`
(or `RegisterOnAllChains.s.sol` on its own) registers the new chain on every other chain of the
ecosystem and vice versa through `ChainRegistrationSender`, which is permissionless and
once-per-ordered-pair. It skips, without failing, every pair that is not registrable yet: a chain
with no batch in the message root (an EraVM chain until its first settled batch, since only ZKsync
OS chains are seeded at creation) and a destination whose deposits are paused. A successful run
therefore does not mean every pair is registered; re-run it once the skipped chains qualify. It is
off by default on purpose: which chains of a production ecosystem may
talk to each other is a decision, not a side effect of creating one. The guards the sender applies
are described in {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}.

## Inputs and where they come from

| Input                                    | Source                                                                                                                  |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| L1 RPC, deployer EOA                     | `--l1-rpc-url`, `--deployer-address` (the bundle's signer; no key is given to the simulation)                           |
| Owner, Era chain id, ZK token asset id   | flags; `ecosystem init` and `ctm init` also take `--env <name>` (see below)                                             |
| Bridgehub (for `ctm init`, `chain init`) | `--bridgehub` (required by `chain init`), or the env preset for `ctm init`                                              |
| CTM (for `chain init`)                   | `--ctm-proxy`; pass it explicitly (see below)                                                                           |
| VM type, testnet verifier                | `--vm-type`, `--with-testnet-verifier` (defaults to true; pass `false` for a production ecosystem)                      |
| CREATE2 salt                             | `--create2-factory-salt` (random by default; the same salt and init code return the existing contract, never a new one) |
| Genesis and L2 bytecodes                 | `configs/genesis/{era,zksync-os}/latest.json` (committed) and the locally built artifacts (not committed)               |
| Chain parameters                         | chain id, owner, operators, base token and price ratio, `--da-mode`, `--l1-da-validator`, pubdata delivery overrides    |

`--env <name>` exists only on `ecosystem init` and `ctm init`; `hub init` and `chain init` take
flags only. It reads two files: the owner and the Era chain id come from the release input
`l1-contracts/upgrade-envs/<release>/<name>.toml`, the ZK token asset id from
`l1-contracts/upgrade-envs/permanent-values/<name>.toml`. Since `permanent-values` requires
`bridgehub_proxy_addr`, `--env` cannot be used for an ecosystem that does not exist yet; a fresh
ecosystem is deployed with flags.

When `--ctm-proxy` is omitted, `chain init` takes the CTM of the first chain registered on the
Bridgehub, which is silently wrong in an ecosystem with several CTMs, and on a Bridgehub without
chains it scans `ChainTypeManagerAdded` from block 0, which hosted RPCs may refuse.

`upgrade-envs/permanent-values/<env>.toml` is the per-environment fact sheet (L1 chain id,
Bridgehub, CTMs, governance kind); a new ecosystem gets a new file there once its addresses exist,
so that the upgrade tooling can address it by name later.

## Ownership after deployment

| Role                 | Contract                                                                | Powers                                                                                                                                             |
| -------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ecosystem governance | `Governance` (owner of the core proxies, the CTMs and the `ProxyAdmin`) | protocol upgrades, CTM registration, freezing chains, pausing migrations; see {protocol-docs/system/contracts/chain_management/upgrade_process.md} |
| Bridgehub admin      | `ChainAdminOwnable`                                                     | `createNewChain`, registering base-token asset ids                                                                                                 |
| CTM admin            | `ChainAdminOwnable` (reused from the hub)                               | operational CTM-side calls (for example the `ServerNotifier` proxy)                                                                                |
| Chain admin          | the chain's `ChainAdmin`                                                | the per-chain settings listed in {protocol-docs/system/contracts/chain_management/admin_role.md}, applying published upgrades                      |
| Operators            | `ValidatorTimelock` roles                                               | committing, proving, executing and reverting batches                                                                                               |

The public ecosystems do not keep `Governance` as the owner: ownership is moved to the
`ProtocolUpgradeHandler` of the `zk-governance` repository (Security Council, Guardians, and the
emergency upgrade board), which is what `governance_kind = "puh"` in the env preset refers to. A
fresh ecosystem starts under `Governance` owned by `owner_address`; moving it under a different
governance means transferring ownership of the same contracts through the current `Governance`:
two-step for the core proxies and the CTM (the new governance accepts), single-step for the
`ProxyAdmin`. `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps` covers the CTM
and `ProxyAdmin` half, given an owner-wrap entry of kind `legacy_governance` for the current
`Governance`; the two-argument variant reverts on any contract owner. For an ecosystem run by a single organization, `owner_address` should be a multisig from
the start: every power in the table above flows from it.

## Verifying a deployment

- The Forge scripts write their output TOMLs under `l1-contracts/script-out/` and `protocol_ops
--out` writes the command envelope with every address; these are the inputs of the node
  configuration (Bridgehub, diamond proxy, validator timelock, DA validator, chain id) and of the
  `permanent-values` entry.
- `l1-contracts/test/anvil-interop/test/hardhat/01-deployment-verification.spec.ts` is the
  checklist a successful deployment satisfies: Bridgehub, asset router and vault have code, the CTM
  is registered, every chain has a diamond proxy, and every ZKsync OS built-in is present on the
  chain.
- Verify the deployed contracts on the explorer from `l1-contracts` with
  `yarn verify-contracts <log-file> --chain <stage|testnet|mainnet>`, where the log file holds the
  `forge verify-contract` lines the scripts print. It only targets mainnet (`mainnet`) and Sepolia (`stage`, `testnet`);
  on any other L1, run those lines with that explorer's verifier settings.
- Check ownership: `owner()` of the core proxies and the CTM must be the governance contract and
  no `pendingOwner()` may be left dangling; the Bridgehub's `admin()` must be the
  `ChainAdminOwnable`. After `hub init` and `ctm init` alone this check fails until the manual
  steps listed under "Hub" and "CTM" have been executed; check `L1InteropHandler`,
  `L1NativeTokenVault`, `ChainRegistrationSender`, `ValidatorTimelock`, `ServerNotifier` and
  `RollupDAManager` explicitly.

## Local and test deployments

The anvil-interop fixture (`l1-contracts/test/anvil-interop/`) deploys a complete ecosystem for
tests: L1 core contracts and CTM, then the registration and initialization of every chain, then
interop registration, plus a Gateway. `yarn setup-and-dump` runs it from scratch and snapshots the
Anvil states that CI and the interop tests load. It is the quickest way to see a deployment run
end to end, but it is not a production reference: it uses the test entry points (`runForAnvil`
with `DummyL1MessageRoot`, `runForAnvilTest` without governance reuse, `RegisterCTM.runForTest`
calling the Bridgehub directly as the deployer, so `Governance` never takes ownership), skips
`FinalizeChainInit` (deposits are unpaused directly) and registers interop with direct
`registerChain` calls instead of `RegisterOnAllChains`. For a production deployment follow
`ecosystem init` and `chain init` as described above.
