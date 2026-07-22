# Registry-Driven Protocol Upgrades

**Status:** Architecture implemented in era-contracts PR #2270. v32 bootstraps each CTM's
`currentRelease` through the legacy governance-calldata pipeline. Deploying the bound executors and
handing them CTM / `ProxyAdmin` ownership is explicit v33 protocol-ops integration work; see
"Legacy path" below.
**Scope:** L1 + L2 era-contracts, upgrade tooling, governance proposal shape.

The model separates two concepts that earlier drafts conflated:

- a **release** — what a chain _is_: the complete installed state (explicit facet routing,
  `DiamondInit`, base-system hashes, genesis parameters, force-deployment descriptor). A release
  is **version-independent** reusable chain state — a verifier-only patch reuses the same
  release — and carries **no VM flag** (VM identity is single-sourced from the pinned
  `DiamondInit.IS_ZKSYNC_OS` immutable).
- a **transition** — how release A _becomes_ release B. Crucially, the transition's facet cuts
  and base-system hash changes are **NOT authored**: they are **DERIVED** from the
  `(fromRelease, newRelease)` pair at initialization and stored (`TransitionDeltaLib`). What
  governance reviews is two releases plus the transition's own concerns: the version edge
  (`oldProtocolVersion -> newProtocolVersion`), the pinned verifier, the pinned `upgradeEngine`,
  the schedule, and the typed `L2UpgradePlan`.

Both are storage-backed, **write-once** contracts generated per upgrade, initialized exactly once
from an audited manifest, committing `manifestHash = keccak256(manifest)`. Canonical factories
deploy each object with CREATE2 using that hash as the salt and attest the resulting address.
Executors reject objects not attested by their bound factory, and the CTM itself holds the
canonical `releaseFactory` (set at `initialize`, or by the owner-gated `setReleaseFactory`
migration call on CTMs whose storage predates the field): `setCurrentRelease` rejects any release
that factory did not attest, covering bootstrap and every transition target from one place — a
transition carries no factory pointer to spoof. Every executable address the objects name carries
its expected `EXTCODEHASH` **inline and mandatorily** — there is no detached, optional pin list,
and a pin only holds against an account that HAS code. Governance only approves "apply this
factory-attested transition".

## Contract map

```mermaid
flowchart TB
    subgraph auth["Authority (bound domain executors)"]
      PUH["Governance / PUH (owner)"]
      BG["Break-glass governor<br/>(separately governed)"]
      CTMEXE["CTMUpgradeExecutor — bound to ONE CTM +<br/>ONE TransitionFactory (immutables)<br/>applyCTMUpgrade(transition)<br/>upgradeChain(transition, chainId)<br/>acceptCTMOwnership()"]
      ECOEXE["EcosystemUpgradeExecutor — bound to ONE ProxyAdmin +<br/>ONE CoreRegistryFactory (immutables)<br/>applyL1Upgrade(coreRegistry)"]
      PUH -->|owns| CTMEXE
      PUH -->|owns| ECOEXE
      BG -.->|"forward(Call[]) only"| CTMEXE
      BG -.->|"forward(Call[]) only"| ECOEXE
    end

    subgraph objects["Write-once upgrade objects (one set per upgrade)"]
      FACT["CTMReleaseFactory / CTMTransitionFactory /<br/>CoreRegistryFactory<br/>CREATE2 salt = manifest hash;<br/>atomic + idempotent deployOrGet*"]
      REL["CTMRelease<br/>explicit facet routing + inline pins,<br/>DiamondInit, system hashes,<br/>genesis params, force-deploy data<br/>(version- and VM-flag-independent)"]
      TRA["CTMTransition<br/>DERIVED final facet cuts + hash delta (stored at init),<br/>version edge, pinned verifier + upgradeEngine,<br/>schedule, typed L2UpgradePlan"]
      COREREG["CoreRegistry<br/>source-checked rows:<br/>proxy, expectedOldImpl -> implNew + pin"]
      FACT -->|"deploys + initializes"| REL
      FACT -->|"deploys + initializes"| TRA
      FACT -->|"deploys + initializes"| COREREG
      TRA -->|"validates BOTH releases;<br/>pins fromRelease -> newRelease"| REL
    end

    subgraph libs["Readers / composers (libraries)"]
      DELTA["TransitionDeltaLib<br/>deriveFacetCuts / deriveHashChanges"]
      READER["ReleaseFacetReader<br/>newChainInstallations(release)"]
      COMPOSER["CTMUpgradeComposer<br/>buildUpgradeCutData / buildL2UpgradeTx /<br/>buildProposedUpgrade (from a transition)"]
      GENLIB["GenesisManifestLib<br/>GenesisConfig -> genesis ReleaseManifest<br/>(explicit routing + pins at build time)"]
    end

    subgraph chain["Chain-type manager + chain"]
      CTM["ChainTypeManager<br/>currentRelease (single pointer) +<br/>canonical releaseFactory (provenance anchor)"]
      DI["DiamondInit<br/>(new-chain genesis; IS_ZKSYNC_OS =<br/>the VM identity source)"]
      BASE["BaseZkSyncUpgrade<br/>upgradeFromTransition(transition)"]
    end

    CTMEXE -->|owns| CTM
    CTMEXE -->|factory-attest + validate + apply| TRA
    CTMEXE -->|"buildUpgradeCutData<br/>(cut = upgradeEngine.upgradeFromTransition)"| COMPOSER
    ECOEXE -->|factory-attest + validate + read rows| COREREG

    TRA -->|"derivation at initialization"| DELTA
    DELTA -->|"reads both releases'<br/>routing + hashes"| REL
    CTMEXE -->|"setNewVersionUpgrade(cut w/ transition)<br/>setCurrentRelease(newRelease)"| CTM
    CTM -.currentRelease.-> REL
    CTM -.->|"setCurrentRelease requires<br/>releaseFactory attestation"| FACT
    DI -->|reads CTM.currentRelease| READER
    READER -->|genesisFacets| REL
    BASE -->|"facetCuts() (derived, applied verbatim) + proposal"| TRA
    BASE -->|"buildProposedUpgrade / buildL2UpgradeTx"| COMPOSER
    COMPOSER -->|"reads L2UpgradePlan,<br/>schedule, version edge"| TRA
    COMPOSER -.->|"L2 tx type via<br/>newRelease.diamondInit().IS_ZKSYNC_OS"| REL
    GENLIB -->|builds| REL
```

## Contracts

| Contract                                                             | Where                          | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------------------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CTMRelease`                                                         | `contracts/upgrades/registry/` | Write-once description of one release: `DiamondInit` + pin, complete `GenesisFacet[]` (address, freezability, **explicit non-empty selectors**, **inline pin**), base-system hashes, `fixedForceDeploymentsData`, genesis params (+ genesis-upgrade pin). **No version, no verifier, no VM flag.**                                                                                                                                                                                                                                                           |
| `CTMTransition`                                                      | `contracts/upgrades/registry/` | Write-once description of one hop. Authored: version edge, pinned `verifier`, pinned `upgradeEngine`, schedule, `L2UpgradePlan`. **Derived at init** from `(fromRelease, newRelease)` and stored: final `Diamond.FacetCut[]` + base-system hash changes. Release provenance is the CTM's job (its stored `releaseFactory` attests every `setCurrentRelease` target); `fromRelease` is never zero. A nonempty `L2UpgradePlan` must carry a delegate target (`L2ComplexUpgrader` unconditionally delegatecalls — a deployments-only plan could never execute). |
| `CoreRegistry`                                                       | `contracts/upgrades/registry/` | Write-once **source-checked** L1 ecosystem rows: `ecosystemRows()` returns `EcosystemContractRow[]` (`proxy`, `expectedOldImpl`, `implNew`, inline pin). The proxy address is the row identity; human labels live off-chain. No proxy admin or protocol version is stored.                                                                                                                                                                                                                                                                                   |
| `TransitionDeltaLib`                                                 | `contracts/upgrades/registry/` | DERIVES final ready-to-execute facet cuts (all removals, then additions) + hash changes from a release pair; rejects duplicate selectors within either release's routing. There is no execution-time selector resolution or re-diffing.                                                                                                                                                                                                                                                                                                                      |
| `ICTMRelease` / `ICTMTransition` / `ICoreRegistry`                   | `contracts/upgrades/registry/` | Read interfaces used by consumers (CTM, DiamondInit, `BaseZkSyncUpgrade`, composer, executors).                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `ReleaseFacetReader`                                                 | `contracts/upgrades/registry/` | `newChainInstallations(release)` — genesis facet cuts straight from the release's explicit routing (no self-description fallback).                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `GenesisManifestLib`                                                 | `contracts/upgrades/registry/` | `buildGenesisManifest(GenesisConfig)` → the genesis `ReleaseManifest`. Explicit routing + codehash pins are captured from the just-deployed facets AT BUILD TIME (`ISelfDescribingFacet.selectors()` / `EXTCODEHASH`); nothing self-describes at consumption time.                                                                                                                                                                                                                                                                                           |
| `CTMUpgradeComposer`                                                 | `contracts/upgrades/registry/` | Pure composition **from a transition**: `buildUpgradeCutData`, `buildL2UpgradeTx` (composed whenever the plan has ANY L2 side — deployments **or** a delegate call), `buildProposedUpgrade`. L2 tx type comes from the target release's `DiamondInit.IS_ZKSYNC_OS`.                                                                                                                                                                                                                                                                                          |
| `CTMReleaseFactory` / `CTMTransitionFactory` / `CoreRegistryFactory` | `contracts/upgrades/registry/` | Atomic, **idempotent** deploy-and-initialize (`deployOrGet*`) via CREATE2 with `salt = keccak256(abi.encode(manifest))`. Addresses are manifest commitments and nonce-independent; same-manifest races return the attested instance, while different manifests cannot displace it. One factory per type because combining their embedded creation code exceeds EIP-170.                                                                                                                                                                                      |
| `CTMUpgradeExecutor`                                                 | `contracts/upgrades/registry/` | Executor **bound to one immutable CTM and one immutable `CTMTransitionFactory`**. It rejects transitions not attested by that factory. Fixed logic: `applyCTMUpgrade`, `upgradeChain` (owner during the window, permissionless after the deadline), and `acceptCTMOwnership`.                                                                                                                                                                                                                                                                                |
| `EcosystemUpgradeExecutor`                                           | `contracts/upgrades/registry/` | Executor **bound to one immutable ecosystem `ProxyAdmin` and one immutable `CoreRegistryFactory`**. It rejects non-attested registries, then applies source-checked rows: at `implNew` ⇒ skip, at `expectedOldImpl` ⇒ upgrade, anything else ⇒ revert.                                                                                                                                                                                                                                                                                                       |
| `UpgradeExecutorBase`                                                | `contracts/governance/`        | Shared base: `Ownable2Step` (owner = PUH) drives the fixed entrypoints; `forward(Call[])` is gated by a **separately governed `breakGlassGovernor`** (own two-step handover) — raw authority that CAN bypass transition invariants, so it belongs to a distinct holder (e.g. a security council).                                                                                                                                                                                                                                                            |

**Validation API and provenance.** Executors first require factory attestation using the object's
`manifestHash`, then call `validate()`. Release provenance is enforced by the CTM itself: its
stored canonical `releaseFactory` must attest every release passed to `setCurrentRelease` —
bootstrap and every transition target alike. `validate()` **reverts**
(`RegistryCodehashMismatch`, uninitialized, …) on execution paths; `verifyAll()` returns `bool` for
inspection and deployment tooling. Enforcement is never left to an advisory predicate.

## Data model: the CTM stores one pointer

`ChainTypeManagerBase` keeps a single release pointer and derives all genesis data by reading it:

- **`currentRelease`** — the release every new chain is created at. Set at CTM initialization and
  moved by `setCurrentRelease` (owner-only; the executor calls it inside `applyCTMUpgrade`).
  `storedBatchZero()` / `l1GenesisUpgrade()` are views over
  `ICTMRelease(currentRelease).genesisParams()`. When the release is pinned, the CTM validates
  VM identity against `IDiamondInit(release.diamondInit()).IS_ZKSYNC_OS()` — one source, no
  manifest flag to drift.

There is no per-version registry map: the upgrade cut itself carries the transition address
(`upgradeEngine.upgradeFromTransition(transition)` as init calldata), so the committed cut and
the final-facet-cut source are the _same object_ — the registry identity cannot be carried twice.
CTM binding is commitment-based: the cut hash is written only by the CTM-bound executor, and a
chain accepts only the cut its own CTM committed. The old `genesisRegistry` /
`upgradeRegistryForVersion` / inline-genesis slots are retained only as `__DEPRECATED_`
placeholders for the upgradeable-proxy layout.

## Flow A — genesis (creating a new chain)

1. `L1Bridgehub.createNewChain(chainId, chainTypeManager, baseTokenAssetId, admin)` records the
   base-token asset id + settlement layer, then calls the CTM with the **minimal**
   `createNewChain(chainId, admin)`.
2. The CTM builds a genesis `DiamondCutData` with **empty** `facetCuts`,
   `initAddress = currentRelease.diamondInit()`, empty `initCalldata`, and deploys the
   `DiamondProxy`.
3. `DiamondInit.initialize(chainId, admin)` — delegatecalled from the proxy constructor, so
   `msg.sender` is the CTM — reads the CTM's `currentRelease`, installs the release's explicit
   facet routing via `ReleaseFacetReader.newChainInstallations`, and reads the base system
   contract hashes from the release.
4. The CTM runs the genesis upgrade (`IAdmin.genesisUpgrade`) using the release's
   `fixedForceDeploymentsData` + genesis-upgrade address. Genesis factory-dep **bytecodes** are
   published out-of-band (bytecodes supplier) and referenced by hash.

Chain migration between settlement layers: `forwardedBridgeBurn` forwards only
`(admin, protocolVersion)`; the destination CTM rebuilds the genesis cut from its **own**
`currentRelease` in `forwardedBridgeMint` → `_deployNewChain(chainId, admin)`.

## Flow B — a registry-driven protocol upgrade

Governance (PUH) owns the two bound executors, which own the CTM and the ecosystem `ProxyAdmin`
respectively. A per-upgrade proposal is a sequence of fixed-signature executor calls:

- `EcosystemUpgradeExecutor.applyL1Upgrade(coreRegistry)` — requires attestation by the executor's
  immutable `CoreRegistryFactory`, `validate()`s the registry, then
  walks the source-checked rows: a proxy already at `implNew` is skipped (idempotence), a proxy
  at `expectedOldImpl` is upgraded, a proxy at anything else **reverts** — replaying a stale
  registry cannot downgrade a proxy a later upgrade already moved.
- `CTMUpgradeExecutor.applyCTMUpgrade(transition)` — requires attestation by the executor's
  immutable `CTMTransitionFactory`, `validate()`s the transition, then asserts
  **both edges independently, before any mutation**:
  - release edge: `ctm.currentRelease() == transition.fromRelease()` — rejects execution from the
    wrong release and (since the call moves `currentRelease`) replays;
  - version edge: `ctm.protocolVersion() == transition.oldProtocolVersion()`.
    It then calls `setNewVersionUpgrade(cut, oldV, deadline, newV, verifier)` — where the cut's
    init is `upgradeEngine.upgradeFromTransition(transition)` — and
    `setCurrentRelease(transition.newRelease())`, so chains created after the upgrade start at the
    new release. Schedule (timestamp, deadline) comes from the transition, not call arguments,
    and the transition refuses to exist with `deadline < upgradeTimestamp`
    (`TransitionDeadlineBeforeUpgrade`) — the old protocol can never be disabled before chains
    are allowed to upgrade.
- Per chain, `CTMUpgradeExecutor.upgradeChain(transition, chainId)` — recomposes the same cut
  (checked against the committed `upgradeCutHash`). **Execution policy:** owner-driven during
  the upgrade window; **permissionless** once the old-version deadline passes — at that point the
  upgrade is operationally mandatory and execution carries no discretionary inputs (chain admins
  additionally retain their own direct execution path on the chain diamond).

When a chain executes the upgrade, `BaseZkSyncUpgrade.upgradeFromTransition` validates the
transition, applies the **derived final** `transition.facetCuts()` verbatim, then runs the
transition-composed `ProposedUpgrade`. Selector resolution and `DiamondCutBuilder` re-diffing no
longer exist: one object sources both the final cuts and the proposal, and its delta is a pure
function of two factory-attested releases.

**Bootstrap (migration into this architecture).** `fromRelease` is **never zero**: one-time
migration accommodations live in one-time migration code, not in every future transition. The
v32 legacy upgrade scripts install `currentRelease` on every CTM (`setCurrentRelease` in the
governance calldata; fresh Gateway CTMs pin it at genesis), so every v33+ transition has a real,
validated source release. A pre-v32 CTM that never received its v32 leg must get one before it
can take a registry-driven transition.

**Patches.** There is exactly ONE patch representation: a same-release transition. (The old
side-door — `createNewPatchUpgrade` + `DefaultUpgrade.patchUpgrade`, which accepted an arbitrary
delegatecalled upgrade contract outside the transition model — is removed.) The rules compose:
a SemVer patch bump must reuse the departing release (`PatchMustReuseRelease`); a same-release
transition's derived facet/hash delta is **empty by construction**, and it must not carry an L2
payload either (`SameReleaseTransitionHasPayload`) — verifier/schedule-only. A patch keeps
`currentRelease` at the same release, so genesis for new chains keeps resolving by identity.
Transitions also refuse `newProtocolVersion <= oldProtocolVersion` (`ProtocolVersionTooSmall`) —
the same rule chains enforce at execution and the CTM enforces in `setNewVersionUpgrade`.

**Derivation, and the honest scope of the guarantee.** For representable release pairs, the
L1-side guarantee is: _the facet routing and base-system hashes an existing chain ends up with are
byte-for-byte what a fresh chain at `newRelease` gets_ — the final cuts and hash changes are
derived from the release pair (duplicate selectors in either release's routing are rejected).
Base-system upgrade calldata uses zero as "leave unchanged", so a nonzero → zero hash transition
is not representable and must not appear in an accepted release pair. The **L2 side is
reviewed-and-pinned data, not proven**: L1 cannot verify L2 execution effects, so the
`L2UpgradePlan` (typed force-deployments, delegate target + calldata, factory deps) is
shape-validated at initialization — a plan whose data the composed transaction would never
execute is rejected (`MalformedL2UpgradePlan`), and delegate-only plans compose a real
transaction (they are never silently dropped) — but what the delegate _does_ on L2 is covered by
review of the pinned payload, not by an on-chain proof.

**Atomic, deterministic, idempotent deployment.** The registry objects have unauthenticated
one-shot initializers, so deploying and initializing in separate transactions would leave a
front-runnable instance. The factories (`deployOrGetRelease` / `deployOrGetTransition` /
`deployOrGetCoreRegistry`) deploy with CREATE2 using the manifest hash as salt, initialize in the
same transaction, and record `manifestHash -> instance`. A same-manifest front-run merely does the
caller's work; a different manifest has a different salt and cannot consume or displace the
approved address. CREATE2 derivation is VM-specific, so predictors use the EVM or EraVM formula
for the deployment chain.

On Gateway, the CTM deployer calls a directly deployed `CTMReleaseFactory` (embedding the release
creation code would exceed the EIP-3860 initcode cap). The helper rebuilds the exact genesis
manifest from the deployment artifacts and predicts the manifest-salted release address. The
prediction is independent of factory nonce, closing the earlier different-manifest griefing race.

**Legacy path.** `deploy-scripts/upgrade/default-upgrade/*` still targets _pre-v32_ CTMs and keeps
encoding the old `setChainCreationParams`; the struct + entrypoint live in
`ILegacyChainTypeManager` (not on the current CTM) so those scripts still compile.
`CTMUpgrade_v32` deploys the genesis release as part of the v32 deploy and emits
`setCurrentRelease` in the governance calldata — v32 itself ships through this legacy pipeline.
Deploying the domain executors and factories, transferring CTM / `ProxyAdmin` ownership, and
accepting the two-step CTM handover are explicit protocol-ops deliverables for the first v33+
registry-executed upgrade; they are not performed by the v32 script in this PR.

## Manifest tooling

The local-environment manifest (`scripts/registry-manifests/v32-local.json`) is emitted and
consumed by the anvil registry-driven upgrade runner
(`test/anvil-interop/run-registry-driven-upgrade-test.ts`): `REGEN_REGISTRIES=1` rebuilds it from
a live deployment (emit), the CI default replays it and fails on any drift (consume). The
manifest carries the two releases' complete explicit routing and the transition's authored
fields, including its release-factory address — **no facet cuts**: the reviewable artifact is the
state, not a hand-written delta. Generated addresses use the same manifest-salted CREATE2 scheme
as the on-chain factories.
The v32 upgrade-prepare pipeline deploys only the bootstrap release used by `currentRelease`.
Deploying production transition/core objects and their bound factories/executors is part of the
v33 protocol-ops integration described above.

## Assumptions / invariants

- **`currentRelease` is mandatory.** A CTM with `currentRelease == 0` cannot create chains;
  `setCurrentRelease(0)` reverts `ZeroAddress`.
- **`fromRelease` is mandatory.** Transitions never accept a zero source; pre-registry migration
  is the v32 legacy scripts' job (see Bootstrap above).
- **Releases and transitions are pinned deployed contracts, write-once.** `initialize` reverts if
  already set; the committed `manifestHash` is what a proposal pins; the addresses referenced by
  governance are implementation addresses, never proxies.
- **Factory provenance is mandatory.** CTM and ecosystem executors accept objects only from their
  immutable transition/core factories; the CTM's stored canonical `releaseFactory` must attest
  every release pinned via `setCurrentRelease` (a spoofable manifest-carried factory pointer
  does not exist).
- **Registry addresses are deterministic.** Factories use CREATE2 with the manifest hash as salt;
  off-chain prediction must use the correct EVM/EraVM formula and exact creation code.
- **Pins are inline and mandatory.** Every executable address a
  release/transition/core-registry names carries its expected `EXTCODEHASH` beside it, checked at
  initialization and by `validate()` / `verifyAll()` through `CodehashPinLib`. A pin only holds
  against an account that HAS code (`RegistryPinTargetHasNoCode`) — an empty account can never
  satisfy a pin, whatever hash the manifest carries.
- **Validation reverts on execution paths.** `validate()` everywhere on-chain; `verifyAll()` is
  tooling-only.
- **Releases carry explicit complete routing.** Enforced at release initialization: the facet
  array must be nonempty, every facet row must have selectors (`RegistryEmptySelectors`), and a
  selector may appear in at most one row (`RegistryDuplicateSelector`); transition derivation
  re-checks duplicates when flattening routing. Core-registry rows are likewise real unique
  edges (all fields nonzero, per-proxy dedup — `RegistryDuplicateProxyRow`). Facet
  self-description (`ISelfDescribingFacet.selectors()`) is a BUILD-time tool for manifest
  generators, not a consumption-time code read.
- **Zero hash means unchanged in an upgrade.** Release pairs must not require a nonzero → zero
  base-system hash change; that state transition is not representable by `BaseZkSyncUpgrade`.
- **VM identity has one source**: the pinned `DiamondInit.IS_ZKSYNC_OS` immutable, validated by
  the CTM against its own flavour when a release is pinned, and read by the composer for the L2
  tx type.
- **The enums are a cross-version ABI — append-only.** New variants go at the end; never reorder
  or delete.
- **The facet set for a protocol version is uniform across all chains on a CTM** — the invariant
  the derived delta and `upgradeCutHash[version]` rely on.
- **VM-specific genesis validation** happens when the release is set, reading its
  `genesisParams()`: Era requires `genesisIndexRepeatedStorageChanges != 0`; ZKsyncOS requires
  `genesisBatchCommitment == bytes32(uint256(1))`.
- **Reproducible bytecode is load-bearing** for every codehash pin — pinned implementations are
  built with a CBOR-metadata-free profile so hashes are byte-identical across platforms (this is
  also why `AllContractsHashes` is regenerated only on CI, never on macOS).
- **Nothing large flows through `createNewChain`.** Genesis force-deployment bytecodes are
  published out-of-band and referenced by hash; the bridgehub → CTM call carries only
  `(chainId, admin)`.

## Governance layer: self-migration (design — lives in zk-governance)

The registry model's authority chain bottoms out at the governance layer
([zk-governance](https://github.com/zksync-association/zk-governance)): the domain executors'
`owner` is the `ProtocolUpgradeHandler` (PUH), and break-glass is separately governed. That layer
upgrades itself by **redeploy + ownership migration**, not by proxy-impl swaps — a fresh PUH
implementation + proxy (CREATE3), fresh **immutable** multisigs (Guardians, SecurityCouncil,
EmergencyUpgradeBoard), and then a proposal through the OLD PUH that re-points ownership of every
owned contract to the new one. Today that proposal is hand-authored calldata — the **last
remaining hand-authored upgrade surface** in the system.

The completion of the model is NOT a standing `GovernanceUpgradeExecutor`:

- the payload is an ownership-migration set, not proxy swaps, so a ProxyAdmin-bound executor
  does not describe it;
- the PUH already executes arbitrary calls — a permanently-owned executor between the PUH and
  itself adds indirection without any new authority separation (the same reasoning that removed
  the generic delegatecall modules here).

What fits is a **write-once `GovernanceMigration` object** — the same data discipline applied to
governance succession:

- **Factory-deployed** (`deployOrGet`, CREATE3-compatible for their deployment flow), write-once,
  `validate()` reverting, `manifestHash` as the 32-byte commitment.
- Pins the new PUH implementation and each new multisig **with inline codehashes**.
- Carries **source-checked ownership edges** — `(target, expectedCurrentOwner → newOwner)` (plus
  the analogous proxy-admin edges) — so a stale or replayed migration can never re-point
  ownership backwards: the exact `expectedOldImpl` property of `EcosystemContractRow`, applied to
  authority instead of implementations.
- Executed by **one call in one PUH proposal** (`migration.execute()`, gated
  `msg.sender == PUH`). The proposal collapses from a page of ownership calls to one pinned
  object; the audit unit is the migration manifest. The EmergencyUpgradeBoard remains the
  break-glass analogue, unchanged.

Coupling to this repo: the era-contracts executor fleet's `owner` / `breakGlassGovernor` pointers
are themselves edges such a migration must move (`CTMUpgradeExecutor`,
`EcosystemUpgradeExecutor`), so the source-checked-edge row shape should be shared (a small
extracted library) rather than reimplemented. The implementation itself belongs in the
zk-governance repository (its own audit scope); nothing in this repo blocks on it.
