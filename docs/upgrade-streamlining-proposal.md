# Registry-Driven Protocol Upgrades

**Status:** Implemented for v32 (era-contracts PR #2270). v32 is the first registry-driven
upgrade; later phases (self-wiring L1 constructors, L2 registry) remain future work.
**Scope:** L1 + L2 era-contracts, upgrade tooling, governance proposal shape

> **Reading guide.** [§ Current implementation (as built)](#current-implementation-as-built)
> describes the flow and invariants **as they exist in the tree today**. The numbered sections
> §§1–7 are the original design proposal, kept for rationale and history; where a decision
> changed during implementation it is flagged inline with an **As built** note and summarized in
> the as-built section. When the two disagree, the as-built section wins.

---

## 1. Summary

Adopt the registry model with four refinements that come from grounding it in the current
codebase:

1. **The orchestrator already exists — in the wrong place.** `DefaultCoreUpgrade` /
   `DefaultCTMUpgrade` (`l1-contracts/deploy-scripts/upgrade/`) already compute every
   stage-0/1/2 governance call _in Solidity_, from config, off-chain
   (`prepareStage0GovernanceCalls()` etc.). The proposal is largely a **port, not a
   greenfield build**: move that composition logic from forge scripts (serialize `Call[]`
   to JSON) into deployable contracts (execute the calls), swapping TOML/env config reads
   for registry getters. This is the strongest feasibility argument and should anchor the
   implementation plan.
2. **The authority model is the missing piece of the design.** `Governance`/PUH executes
   plain `CALL`s, so `orchestrator.applyCTMUpgrade(reg)` has no standing to call
   `CTM.setNewVersionUpgrade` (which is `onlyOwner`). Proposal: a tiny permanent
   **`UpgradeExecutor`** that holds the ownership PUH holds today and exposes only
   `execute(address module, bytes data)` (delegatecall) + a raw-call escape hatch, both
   PUH-gated. Per-upgrade orchestrator logic ships as stateless modules. Audited once;
   per-upgrade audit surface = one module + the registries.
3. **Compose against the registry, not against live diamond state, in phase 1.** The
   self-describing-facet diff (`executeUpgradeBySwaps`) requires the entrypoint to already
   exist in the diamond, so it can't help the upgrade that introduces it. But the diff
   doesn't need live state at all: for a given old protocol version the facet set is
   uniform across chains and pinned in the _old_ registry. Phase 1 composes
   `DiamondCutData` on-chain inside the orchestrator from `(oldRegistry, newRegistry)`
   and feeds the **existing, unchanged** `setNewVersionUpgrade` / `setChainCreationParams`
   / `upgradeChainFromVersion` entrypoints. `executeUpgradeBySwaps` becomes a phase-2
   optimization, not a dependency.
4. **Match the real L2 upgrade path.** The universal (Era + ZKsyncOS) force-deploy vehicle
   is `ComplexUpgrader.forceDeployAndUpgradeUniversal(UniversalContractUpgradeInfo[], …)`
   with per-entry `ContractUpgradeType` (`EraForceDeployment` /
   `ZKsyncOSSystemProxyUpgrade` / `ZKsyncOSUnsafeForceDeployment`), not raw
   `ContractDeployer.forceDeployOnAddresses`. The CTM registries must pin the upgrade
   _type_ per contract alongside the bytecode hash; `CoreOnGatewayHelper` already encodes
   exactly this mapping (`_resolveUpgradeType`, `getEraForceDeployment`) and is the
   generator's source of truth.

Everything else in the brief survives contact with the code. Detailed grounding, decisions,
risks, and a phased rollout follow.

---

## Current implementation (as built)

v32 is the first registry-driven upgrade. This section is the source of truth for how the flow
works today; it also calls out where the implementation diverged from the proposal below (most
notably registries became **storage-backed** rather than constants-in-bytecode, and the CTM's
inline `ChainCreationParams` **collapsed** into a single genesis-registry pointer).

### Contracts

| Contract                                      | Where                          | Role                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CTMRegistry`                                 | `contracts/upgrades/registry/` | Storage-backed, write-once registry of everything a chain-type-manager needs for one `(oldVersion, newVersion)` pair: facet rows + selectors, freezability, per-version addresses (`DiamondInit`, `DefaultUpgrade`, …), verifier, base system contract hashes, genesis params, force-deployments blob, L2 deployment rows, codehash pins. Era vs ZKsyncOS is a manifest flag (`isZKsyncOS`), not a separate contract. |
| `CoreRegistry`                                | `contracts/upgrades/registry/` | Same shape for L1 ecosystem contracts (`EcosystemContract` rows: proxy + new impl) + codehash pins.                                                                                                                                                                                                                                                                                                                   |
| `ContractIdentifiers.sol`                     | `contracts/upgrades/registry/` | The cross-version ABI: `EcosystemContract` / `CoreContract` / `CTMContract` / `ZKsyncOSUpgradeType` enums **and** the shared `CodehashPin` struct.                                                                                                                                                                                                                                                                    |
| `ICTMRegistry` / `ICoreRegistry`              | `contracts/upgrades/registry/` | Read interfaces used by consumers (CTM, DiamondInit, composer, reader).                                                                                                                                                                                                                                                                                                                                               |
| `RegistryFacetReader`                         | `contracts/upgrades/registry/` | `newChainInstallations(registry)` (genesis facet cuts) and `facetSwapPlan(registry)` (`UpgradeFacetSwap[]` for an upgrade), derived from the registry's rows.                                                                                                                                                                                                                                                         |
| `GenesisManifestLib`                          | `contracts/upgrades/registry/` | `buildGenesisManifest(GenesisConfig)` → a `CTMRegistry` manifest for a freshly deployed chain-type manager's genesis registry.                                                                                                                                                                                                                                                                                        |
| `CTMUpgradeComposer`                          | `contracts/upgrades/registry/` | Pure composition from a registry: `buildUpgradeCutData`, `buildL2UpgradeTx`, `buildProposedUpgrade`.                                                                                                                                                                                                                                                                                                                  |
| `CTMUpgradeModule` / `EcosystemUpgradeModule` | `contracts/upgrades/registry/` | Stateless per-upgrade modules, delegatecalled by the executor: `applyCTMUpgrade(registry, oldDeadline, timestamp)` + `upgradeChain(...)`, and `applyL1Upgrade(coreRegistry)`.                                                                                                                                                                                                                                         |
| `UpgradeExecutor`                             | `contracts/governance/`        | Permanent `Ownable2Step` (owner = PUH) exposing `execute(module, data)` (delegatecall) + `forward(Call[])` (raw-call escape hatch). Holds the ownerships PUH used to hold.                                                                                                                                                                                                                                            |

Both registry flavours are **generated per environment** by `scripts/gen-registry.ts` from an
audited `manifest.json`, `initialize(manifest)`d exactly once, and commit
`manifestHash = keccak256(manifest)` so a governance proposal can reference exactly the reviewed
bytes. `verifyAll()` checks the pinned `CodehashPin`s (EXTCODEHASH) against the live deployment.

### Data model: the CTM stores pointers, the registry holds the data

`ChainTypeManagerBase` keeps only two registry pointers and derives all genesis/upgrade data by
reading them:

- **`genesisRegistry`** (single, current-version) — set by `setGenesisRegistry(address)`, emits
  `NewGenesisRegistry`. The source of everything a **new** chain needs.
- **`upgradeRegistryForVersion[protocolVersion]`** — set by `setNewVersionUpgrade(…, registry)`.
  The source of the facet-swap plan when an **existing** chain upgrades to that version.

The former inline genesis data is gone: the `ChainCreationParams` struct, the `InitializeData`
init struct, and the `storedBatchZero` / `initialCutHash` / `l1GenesisUpgrade` /
`initialForceDeploymentHash` storage slots have been removed (slots retained as `__DEPRECATED_`
placeholders to preserve the upgradeable-proxy layout). `storedBatchZero()` and
`l1GenesisUpgrade()` are now views that read `genesisRegistry.genesisParams(protocolVersion)`.

### Flow A — genesis (creating a new chain)

1. `L1Bridgehub.createNewChain(chainId, chainTypeManager, baseTokenAssetId, admin)` records the
   base-token asset id + settlement layer, then calls the CTM with the **minimal**
   `createNewChain(chainId, admin)`. The base token asset id and factory deps are _not_ forwarded
   — DiamondInit reads the asset id from the bridgehub; the genesis force-deployments live in the
   registry.
2. The CTM builds a genesis `DiamondCutData` with **empty** `facetCuts`, `initAddress =
genesisRegistry.ctmAddress(DiamondInit, protocolVersion)`, and empty `initCalldata`, and
   deploys the `DiamondProxy`.
3. `DiamondInit.initialize(chainId, admin)` — delegatecalled from the proxy constructor, so
   `msg.sender` is the CTM — reads the CTM's `genesisRegistry`, installs the facet set via
   `RegistryFacetReader.newChainInstallations` (each facet's selectors from its own
   `ISelfDescribingFacet.selectors()`, or a registry-pinned override), and reads the base system
   contract hashes from the registry.
4. The CTM runs the genesis upgrade (`IAdmin.genesisUpgrade`) using the registry's
   `fixedForceDeploymentsData` + `l1GenesisUpgrade()`. Genesis factory-dep **bytecodes** are
   published out-of-band (bytecodes supplier) and referenced by hash, so an empty `factoryDeps`
   is passed.

Chain migration between settlement layers: `forwardedBridgeBurn` forwards only
`(admin, protocolVersion)`; the destination CTM rebuilds the genesis cut from its **own** registry
in `forwardedBridgeMint` → `_deployNewChain(chainId, admin)`.

### Flow B — a registry-driven protocol upgrade

Governance (PUH) owns the permanent `UpgradeExecutor`, which owns the CTMs / ecosystem
`ProxyAdmin` / `ValidatorTimelock`. A per-upgrade proposal is a sequence of
`executor.execute(module, registryImpl)` calls:

- `EcosystemUpgradeModule.applyL1Upgrade(coreRegistry)` — L1 ecosystem implementation swaps, etc.,
  read from the `CoreRegistry`.
- `CTMUpgradeModule.applyCTMUpgrade(ctmRegistry, oldDeadline, timestamp)` — reads the CTM proxy +
  old/new protocol versions from the registry, composes the upgrade cut and L2 upgrade tx via
  `CTMUpgradeComposer`, then calls `setNewVersionUpgrade(cut, old, deadline, new, verifier,
ctmRegistry)` (which pins `upgradeRegistryForVersion[new] = ctmRegistry`) **and**
  `setGenesisRegistry(ctmRegistry)`, so chains created after the upgrade start at the new version.
- Per chain, `CTMUpgradeModule.upgradeChain(ctmRegistry, chainId, timestamp)`.

When a chain executes the upgrade, `BaseZkSyncUpgrade` reads `upgradeRegistryForVersion` (via the
CTM), `RegistryFacetReader.facetSwapPlan(registry)` produces the `UpgradeFacetSwap[]` (one entry
per changed facet: old→new address, freezability, selector lists), and `_upgradeFacets` performs
the `Diamond.diamondCut` (selectors resolved from `ISelfDescribingFacet.selectors()` or a
registry override).

**Legacy path.** `deploy-scripts/upgrade/default-upgrade/*` still targets _pre-v32_ CTMs and keeps
encoding the old `setChainCreationParams`; the struct + entrypoint were moved out of the current
CTM into `ILegacyChainTypeManager` so those scripts still compile. `CTMUpgrade_v32` deploys its
genesis `CTMRegistry` as part of the v32 deploy and overrides the governance call to emit
`setGenesisRegistry` instead of `setChainCreationParams`.

### Assumptions / invariants

- **The genesis registry is mandatory.** A CTM with `genesisRegistry == 0` cannot create chains;
  `setGenesisRegistry(0)` reverts `ZeroAddress`.
- **The enums are a cross-version ABI — append-only.** New variants go at the end; never reorder
  or delete.
- **Registry instances are write-once.** `initialize` reverts if already set; the committed
  `manifestHash` is what a proposal pins.
- **The facet set for a protocol version is uniform across all chains on a CTM** — the invariant
  the swap plan and `upgradeCutHash[version]` rely on.
- **VM-specific genesis validation** happens in `_setGenesisRegistry`, reading the registry's
  `genesisParams`: Era requires `genesisIndexRepeatedStorageChanges != 0`; ZKsyncOS requires
  `genesisBatchCommitment == bytes32(uint256(1))`.
- **Reproducible bytecode is load-bearing** for CREATE2 address prediction and every codehash
  pin — registries are built with a CBOR-metadata-free profile so hashes are byte-identical
  across platforms (this is also why `AllContractsHashes` is regenerated only on CI, never on
  macOS).
- **Nothing large flows through `createNewChain`.** Genesis force-deployment bytecodes are
  published out-of-band and referenced by hash; the bridgehub → CTM call carries only
  `(chainId, admin)`.

---

## 2. What the codebase already provides

| Brief assumption                       | Reality in tree                                                                                                                                                                                                                   | Consequence                                                                                                                                         |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CoreContract` enum                    | `deploy-scripts/ecosystem/CoreContract.sol` — 23 variants, with `CoreOnGatewayHelper.resolve(bool isZKsyncOS, CoreContract)` picking Era/ZKsyncOS variants, `getDeployedBytecodeHash` per VM, `_resolveUpgradeType` per contract  | Reuse as-is as registry key; generator reuses the resolvers                                                                                         |
| `CTMContract` enum                     | `deploy-scripts/ctm/DeployCTML1OrGateway.sol` — 17 variants incl. all facets, verifiers, `DiamondInit`, `ValidatorTimelock`, `ChainTypeManager`                                                                                   | Reuse as-is; note `GettersFacet` is not in it — add before generating                                                                               |
| L1 ecosystem contracts as enum         | Only structs (`Types.sol`: `BridgehubContracts`, `BridgeContracts`, …)                                                                                                                                                            | New `EcosystemContract` enum needed (small, mechanical)                                                                                             |
| SemVer packing                         | `SemVer.sol` packs into **uint96** (patch 0–31, minor 32–63, major 64–95); CTM stores `protocolVersion` as `uint256`                                                                                                              | Registry version keys: `uint256` at the ABI, packed via `SemVer.packSemVer`                                                                         |
| Upgrade-cut commitment                 | `upgradeCutHash[protocolVersion]` stores **hash only** (`ChainTypeManagerBase.sol:83`); chain-creation params stored as `initialCutHash` + `initialForceDeploymentHash`                                                           | Orchestrator can pass fully-composed structs to existing entrypoints; no CTM storage change needed for phase 1                                      |
| L2 upgrade tx                          | `BaseZkSyncUpgrade._setL2SystemContractUpgrade` requires **`nonce == new minor version`** (`:249`) and factory deps **already published to `BytecodesSupplier`** (`_verifyFactoryDeps`, `:267`, capped at `MAX_NEW_FACTORY_DEPS`) | Orchestrator derives nonce from registry's `NEW_PROTOCOL_VERSION`; deployment plan needs a permissionless "publish bytecodes" step before execution |
| On-chain calldata composition is novel | `GatewayCTMDeployer` already builds `DiamondCutData` on-chain from a config struct with selector lists                                                                                                                            | Accepted pattern in this codebase; extract/share the composition code                                                                               |
| Two CTMs                               | `EraChainTypeManager` / `ZKsyncOSChainTypeManager` exist; **no "Atlas" naming anywhere**                                                                                                                                          | Name the registry `ZKsyncOSCTMRegistry` to match the code                                                                                           |
| Off-chain call generation              | `DefaultCoreUpgrade` / `DefaultCTMUpgrade` / `Default{Chain,Gateway}Upgrade` already produce stage-0/1/2 `Call[]` programmatically                                                                                                | The orchestrator is a port of this logic to executing contracts                                                                                     |
| Hash pinning precedent                 | `AllContractsHashes.json` at repo root, CI-checked                                                                                                                                                                                | Extend the same mechanism to registry `EXTCODEHASH` commitments                                                                                     |

Two repo rules (AGENTS.md) that constrain the design:

- **L2 contracts must not have constructors or immutables** (ZKsync OS). The L2 registry
  must be pure `constant`s — which is exactly the constants-in-bytecode design, so this is
  compatible, but the generator must never emit an L2 constructor.
- **No `try`/`catch`, no `staticcall`.** `verifyAll()` and all registry reads must be plain
  external view calls that revert on failure; enum switch defaults revert.

---

## 3. Design decisions

### D1. Registries: three contracts, code-aligned naming

> **As built:** **two** base contracts, `CTMRegistry` + `CoreRegistry`, and they are
> **storage-backed write-once** (`initialize(manifest)` + `manifestHash`), _not_
> constants-in-bytecode. Era vs ZKsyncOS is a manifest flag on `CTMRegistry`, not a separate
> `EraCTMRegistry` / `ZKsyncOSCTMRegistry` contract. Per-environment instances are generated
> (`gen-registry.ts`) and committed. See the as-built section above.

`CoreRegistry`, `EraCTMRegistry`, `ZKsyncOSCTMRegistry` (not "Atlas" — nothing in the tree
uses that name; if Atlas is the product name, keep it in docs only). Split, keying, and
constants-in-bytecode as in the brief. Version keys are `uint256` holding
`SemVer.packSemVer` values; getters are `pure`; unknown `(enum, version)` combinations
revert via the switch default.

**Enum discipline:** the enums become a cross-version ABI. Rule: **append-only** — new
variants go at the end, no reordering, no deletion (deprecate by returning 0/reverting in
new registry versions). The generator must assert this against the previous version's enum.

**Registry size:** each registry impl holds only `(v(N-1), v(N))` values, keeping runtime
code far under the EIP-170 24 KB limit even with per-entry `*_HASH` verification constants.
History = the chain of old impls at their CREATE2 addresses, as in the brief.

### D2. Authority: a permanent `UpgradeExecutor` + per-upgrade stateless modules

The brief's proposal shape — "run these orchestrator calls" — silently assumes the
orchestrator can act on `onlyOwner` targets. It can't: PUH/Governance executes plain calls,
and `setNewVersionUpgrade`, `setChainCreationParams`, `upgradeChainFromVersion`, and
`ProxyAdmin.upgrade` are all owner-gated. Three options:

- **(a) Standing intermediary owner** — a permanent orchestrator owns the CTMs/ProxyAdmin.
  Audited once, but must anticipate every future upgrade shape; one-off steps (v31 has
  token migration, legacy GW decommission) force escape-hatch raw calls, eroding the model.
- **(b) Delegatecall executor inside PUH** — authority stays exactly at PUH, but requires
  a PUH change and delegatecall storage discipline at the root of trust.
- **(c) Hybrid (recommended):** a tiny, permanent **`UpgradeExecutor`** takes over the
  ownerships PUH holds today (CTMs, ecosystem `ProxyAdmin`, `ValidatorTimelock`, …). It is
  `Ownable` by PUH and exposes exactly two functions:

  ```solidity
  contract UpgradeExecutor is Ownable2Step /* owner = PUH */ {
      /// Per-upgrade logic, stateless, delegatecalled. The module address and the
      /// registry address are the proposal's only meaningful arguments.
      function execute(address _module, bytes calldata _data) external onlyOwner {
          // delegatecall into an audited, stateless orchestrator module
      }
      /// Escape hatch: raw calls, so governance never loses direct control
      /// (emergency upgrades, one-off actions).
      function forward(Call[] calldata _calls) external onlyOwner { ... }
  }
  ```

  The executor is ~50 lines, audited once, and holds no storage beyond the owner slot (so
  delegatecalled modules can't clobber anything that matters). Each upgrade ships one
  **orchestrator module** — stateless, per-upgrade-audited, absorbing that upgrade's
  one-off quirks — plus the registries. The governance proposal becomes:
  `PUH → executor.execute(v32Module, abi.encode(coreRegistryV32Impl))` per phase.

  The module _dereferences the registry impl address directly_ (passed in the proposal),
  not through the registry proxy — so what governance signed is exactly what's read,
  independent of proxy state.

### D3. Registry proxies: keep them, but constrain what trusts them

The proxy-at-well-known-address is needed for self-wiring impl constructors, but it
reintroduces mutability into a design whose selling point is immutability. Constraints:

- Registry proxy admin = ecosystem `ProxyAdmin` (i.e. `UpgradeExecutor` → PUH). The
  proxy swap is a step _inside_ `applyL1Upgrade`, executed by the module.
- **Only deploy-time self-wiring reads go through the proxy** (new impl constructors
  resolving proxy addresses of their dependencies — version-independent values). The
  orchestrator and all verification always read a pinned impl address.
- Bootstrap: a fresh ecosystem must deploy the three registry proxies (behind CREATE2, so
  the well-known addresses hold across ecosystems) before any self-wiring impl. Add to
  the ecosystem genesis deploy scripts. This is also what makes **one-impl,
  many-ecosystems** work: same creation code → same CREATE2 impl addresses; different
  registry impls behind the same proxy address → different immutables.

### D4. Diamond cuts: registry-diff first, self-describing facets second

Phase 1 needs **no protocol-contract changes**:

```
FacetCut[] = diff( oldReg.selectors(CTMContract.X, V31),   // pinned in old registry
                   newReg.selectors(CTMContract.X, V32) )   // pinned in new registry
```

Selector lists per facet per version become CTM-registry constants (generated from
`forge inspect <Facet> methodIdentifiers`, exactly as the brief's `SelfDescribingFacet`
would embed them — just embedded in the registry instead of the facet). This is sound
because for a given protocol version the facet set is uniform across all chains on the
CTM — which is already the invariant `upgradeCutHash[version]` relies on. The composed
`DiamondCutData` feeds the existing `setNewVersionUpgrade` / `upgradeChainFromVersion`
unchanged.

Phase 2 ships `SelfDescribingFacet.selectors()` on the new facets and
`AdminFacet.executeUpgradeBySwaps(FacetSwap[], initAddress, initCalldata)` — usable from
the _following_ upgrade (the entrypoint must pre-exist in the diamond). Notes from
`Diamond.sol`:

- `FacetSwap` must carry `isFreezable` per new facet; the library enforces uniform
  freezability across a facet's selectors (`Diamond.sol:243–247`).
- Old selectors read from `facetToSelectors` storage before any cut is applied, so
  swapping `GettersFacet` itself is safe.
- Trust surface: `selectors()` is an external call to a CTM-supplied address — same
  authority as today's `executeUpgrade(DiamondCutData)`, so no new privilege, but a wrong
  selector list bricks/miswires the diamond exactly as a wrong hand-built cut does today.
  The audit unit is the facet source (where the list is generated from), which is the
  intended shift.

Once `executeUpgradeBySwaps` is live, `upgradeCutHash` can become `upgradeSwapsHash` — or
be dropped entirely in favor of "the CTM pins the registry impl address for the version",
which is the stronger commitment. Suggested end state: `upgradeRegistry[protocolVersion]
= registryImplAddress`.

### D5. L2 upgrade composition: `UniversalContractUpgradeInfo`, not `ForceDeployment`

The orchestrator composes the `l2ProtocolUpgradeTx` calling
`ComplexUpgrader.forceDeployAndUpgradeUniversal` with one `UniversalContractUpgradeInfo`
per `CoreContract` variant:

- `upgradeType` from the registry (mirroring `CoreOnGatewayHelper._resolveUpgradeType`:
  `EraForceDeployment` for Era, `ZKsyncOSSystemProxyUpgrade` / `Unsafe` for ZKsync OS),
- `deployedBytecodeInfo` from `reg.l2BytecodeHash(c, V32)`,
- `newAddress` from predeploy constants,
- `_delegateTo`/`_calldata` carrying the post-deploy init (today's
  `FixedForceDeploymentsData` role).

Hard requirements picked up from `BaseZkSyncUpgrade`:

- `tx.nonce = minor(NEW_PROTOCOL_VERSION)` — derive via `SemVer.unpackSemVer`.
- `factoryDeps` (≤ `MAX_NEW_FACTORY_DEPS`) must be pre-published to `BytecodesSupplier`;
  this is permissionless and becomes an explicit pre-execution step in the deployment
  plan (§5 step 4b).

**Ordering** stays as in the brief: L2 registry first, system contracts second, init third
— all inside the one upgrade tx.

### D6. `chainCreationParams` from the same source

> **As built:** taken further — `ChainCreationParams` was **removed entirely**. Rather than the
> module rebuilding the struct and calling `setChainCreationParams`, the CTM stores a single
> `genesisRegistry` pointer (`setGenesisRegistry(address)`) and reads facet set, base system
> hashes, verifier, genesis params, `DiamondInit` address and force-deployments straight from it.
> `setChainCreationParams` + the struct survive only in `ILegacyChainTypeManager` for the
> pre-v32 default-upgrade scripts. Drift is impossible not by co-locating two calls but because
> there is only one source. See the as-built section above.

As in the brief: the module builds `ChainCreationParams` from the CTM registry
(`genesisParams(V32)` + empty-diff cut + the same `UniversalContractUpgradeInfo[]`
serialized into `forceDeploymentsData`) and calls the existing `setChainCreationParams` in
the same module call as `setNewVersionUpgrade` — drift between the two becomes impossible
by construction. VM-specific validation already exists downstream
(`EraChainTypeManager` requires `genesisIndexRepeatedStorageChanges != 0`;
`ZKsyncOSChainTypeManager` requires `genesisBatchCommitment == bytes32(uint256(1))`) and
the generator should pre-validate the same predicates.

Patch upgrades: `createNewPatchUpgrade` already carries params forward
(`ChainTypeManagerBase.sol:413`). A patch registry = child contract inheriting the parent
version's constants overriding only the verifier entries — one-file audit, as in the brief.

### D7. L2 registry

As in the brief, with two code-grounded adjustments:

- **No constructor, no immutables** (repo rule / ZKsync OS constraint): pure constants,
  deployed as the first entry of the upgrade tx's deployment array.
- Its role overlaps what `FixedForceDeploymentsData` threads into
  `L2GenesisUpgrade` today (L1 addresses, bytecode info). The end state is that
  `forceDeploymentsData` shrinks to (mostly) "deploy the L2 registry"; system contracts
  read ecosystem-specific values from the registry at runtime instead of receiving them
  via genesis-storage init. That's what delivers **one audited L2 bytecode per VM** — the
  only per-ecosystem L2 artifact left is the generated registry itself.
- Migration is gradual: contracts move from `initL2`-style storage reads to registry reads
  one at a time; both can coexist during transition.

### D8. Generation and reproducibility

`manifest.json → gen-registry → .sol → forge build`, with the generator reusing
`CoreOnGatewayHelper` / `DeployCTML1OrGateway` resolvers so deploy scripts and registries
cannot drift. Practical requirements the brief omits:

- **Reproducible bytecode is a hard dependency** of both CREATE2 address prediction and
  every `EXTCODEHASH` commitment: pin solc + settings, set `bytecode_hash = "none"` /
  `cbor_metadata = false` for registry builds (or pin the metadata), and CI-check
  registry hashes the same way `AllContractsHashes.json` is checked today.
- The generator emits the getter `switch` bodies _and_ a machine-readable summary
  (address ↔ enum ↔ version table) that the review tooling diffs against the manifest —
  auditors read Solidity, tooling cross-checks JSON.

### D9. Verification layer (optional, as in brief)

`verifyAll()` with plain external view calls (no `staticcall`/`try` per repo rules),
proxy = shell-hash + EIP-1967-slot impl hash, diamond = sorted facet-set commitment via
`Getters.facetAddresses()`. One addition: on Era VM chains the pinned hash for L2
contracts must be the **versioned zk bytecode hash** (`AccountCodeStorage.getRawCodeHash`
semantics), not keccak; `CoreOnGatewayHelper.getDeployedBytecodeHash` already branches per
VM — reuse it in the generator so the right hash lands in the right registry.

---

## 4. v31-shape mapping (sanity check)

Against the 61-call v31 stage proposal, the module surface:

| Group                                                         | Today  | Proposed                                                                                                                                                                         |
| ------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Atlas CTM PA handover                                         | 2      | 0 — PA deployed PUH-owned via CREATE2                                                                                                                                            |
| ChainAdmin multicalls                                         | 2      | 2 — outside PUH authority by design (unchanged)                                                                                                                                  |
| PUH stage 0                                                   | 6      | 1 — `executor.execute(module, beginUpgrade(reg))`                                                                                                                                |
| Ecosystem L1 (TPA upgrades, reinit, setters, acceptOwnership) | 11     | 1 — `applyL1Upgrade`; setters die via self-wiring constructors, acceptOwnership via deploy-time owner                                                                            |
| Per-CTM (2 CTMs)                                              | 12     | 2 — `applyCTMUpgrade(reg, ctm)`; cut + creation params + VT from one source                                                                                                      |
| Stage 2 finalize + gates + decommission                       | 14     | 1 — `finalizeUpgrade`; one-off decommission logic lives in the v-specific module                                                                                                 |
| GW configuration priority txs                                 | 14     | 1 — `configureGW`; approve+priority-tx pairs composed internally (module needs the same base-token approvals governance issues today — keep the approval inside the module call) |
| **Total**                                                     | **61** | **8**                                                                                                                                                                            |

The per-upgrade audit surface: 3 registry files + 1 orchestrator module + (already-audited)
executor.

---

## 5. Rollout plan

**Phase 0 — Shadow mode (v32 prep; zero protocol change).**
Build `gen-registry` + the three registry contracts as artifacts. Retroactively generate
v31 registries from the shipped v31 config. Build a differ that recomposes the 61-call v31
proposal from the registries (porting `prepareStage0/1/2GovernanceCalls` reads to registry
reads) and diffs byte-for-byte against the actual shipped proposal. **Exit criterion: zero
diff.** This validates the composition logic against a real upgrade before any of it holds
authority.

**Phase 1 — On-chain composition through existing entrypoints (v32).**
Deploy `UpgradeExecutor`; transfer CTM/ProxyAdmin/VT ownership to it (one-time
`Ownable2Step` handover inside the v32 proposal). Ship the v32 orchestrator module
composing cuts/params/L2-tx from registries (registry-diff variant, §D4) into the
_unchanged_ CTM entrypoints. v32's new facets already implement `SelfDescribingFacet`, and
v32's `AdminFacet` ships `executeUpgradeBySwaps` — dormant. Registry proxies deployed and
pointed at v32 impls.

**Phase 2 — Self-describing swaps + self-wiring (v33).**
Modules use `executeUpgradeBySwaps`; new L1 impls use argless self-wiring constructors
reading the registry proxy (killing the setter/acceptOwnership call groups); CTM commitment
moves from `upgradeCutHash` toward pinning the registry impl address.

**Phase 3 — L2 registry + verification layer (v33+).**
L2 registry predeploy in the upgrade tx; system contracts migrate reads incrementally;
`verifyAll()` + `EXTCODEHASH` CI pinning; cross-chain verification last.

Each phase is independently shippable and independently abortable — phase 1 falls back to
today's flow by simply not using the executor (escape hatch preserves raw governance).

---

## 6. Risks and open questions

1. **Registry proxy admin is a new root of trust** for self-wiring constructors. Mitigated
   by: orchestrator/verification never read through the proxy; only deploy-time
   constructor wiring does, and only for version-independent proxy addresses. Worst case
   from a malicious impl swap is incorrectly wired _future_ deployments, which CREATE2-address
   verification (step 4 of the deployment plan) catches.
2. **Reproducible builds are load-bearing.** A solc bump or metadata drift silently breaks
   every hash commitment. Needs CI enforcement from day one (extend the
   `AllContractsHashes.json` check).
3. **One-off upgrade steps never fully disappear** (v31: token migration, legacy GW
   decommission). The per-upgrade module absorbs them as audited Solidity, which is still
   a major improvement over opaque calldata — but the "orchestrator is generic
   infrastructure" framing oversells; the honest framing is "the calldata becomes audited
   per-upgrade source code."
4. **Enum evolution**: append-only rule must be generator-enforced. `GettersFacet` missing
   from `CTMContract` today is a concrete example of the enum lagging reality — reconcile
   enums with the actual deployed set before first generation.
5. **`executeUpgradeBySwaps` timing**: only usable one version after it ships. Phase plan
   accounts for this; don't let phase-2 features leak into phase-1 commitments.
6. **Gateway configuration costs**: priority txs need base-token approvals and gas
   budgeting; the module composes them, but funding/refund flows for governance-initiated
   priority txs need explicit design (same problem exists today, calls 47–60).
7. **Emergency path**: EmergencyUpgradeBoard/security-council flows must keep working when
   ownership moves to `UpgradeExecutor` — the `forward()` escape hatch covers actions, but
   the emergency-upgrade _of the executor itself_ (PUH swapping executor ownership back)
   should be an explicitly tested path.
8. **Genesis VM-state values** (`genesisBatchHash` etc.) remain off-chain-computed
   constants whose audit is "re-run the genesis VM" — unchanged from the brief; tooling
   should make this one command.
9. **Open**: does the security council / decentralization story accept the executor
   indirection? (It's ownership-chain-neutral — PUH remains the root — but it's a new
   contract in the critical path and needs sign-off.)
10. **Open**: `ZKsyncOSChainTypeManager` vs "Atlas" naming; and whether the
    `EcosystemContract` enum should be promoted into `Types.sol` structs' place or live
    alongside them (recommend alongside, generated getters map enum → struct field).

---

## 7. Concrete work items

1. `EcosystemContract` enum + reconcile `CTMContract` (add `GettersFacet`) — small PR.
2. `gen-registry` generator (TS or forge script) reusing `CoreOnGatewayHelper` /
   `DeployCTML1OrGateway` resolvers; reproducible-build config + CI hash check.
3. v31 shadow re-composition differ (phase-0 exit criterion).
4. `UpgradeExecutor` (~50 lines) + tests incl. emergency/ownership-return paths.
5. `DiamondCutBuilder` library (registry-diff + empty-diff modes) — extract/share with
   `GatewayCTMDeployer`'s existing composition code.
6. v32 orchestrator module: `beginUpgrade` / `applyL1Upgrade` / `applyCTMUpgrade` /
   `finalizeUpgrade` / `configureGW`, ported from `Default*Upgrade` scripts.
7. `SelfDescribingFacet` base + `AdminFacet.executeUpgradeBySwaps` (ships v32, dormant).
8. L2 registry template (constants-only, no constructor) + predeploy address constant.
9. Optional: `verifyAll()` generation, per-VM hash handling via `getDeployedBytecodeHash`.
