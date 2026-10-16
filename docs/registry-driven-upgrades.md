# Registry-Driven Protocol Upgrades

A protocol upgrade is a set of **write-once contracts** deployed ahead of time. Governance approves
the object addresses and the contents they commit to; the contracts validate them and the executors
apply them. What governance signs is one fixed-signature call on one coordinator plus whatever the
prepare declared as an external action.

**Scope:** L1 + L2 era-contracts, upgrade tooling, governance proposal shape.

This is the architecture document. Two other documents complete it and are not restated here:

- [`protocol-docs/ecosystem-upgrade-coordination.md`](../protocol-docs/ecosystem-upgrade-coordination.md)
  is the **coordinator spec**: what `EcosystemUpgradeExecutor.execute` does, the operation
  commitment and the authorization of the domain executors.
- [`l1-contracts/deploy-scripts/upgrade/README.md`](../l1-contracts/deploy-scripts/upgrade/README.md)
  is the **runbook**: how a prepare is run, composed, verified, replayed and how chains cross.

[`upgrade-operations.md`](upgrade-operations.md) keeps the operational policies that belong to
neither: the ServerNotifier handover, coordinator succession, monitoring, recovery and the
incident-only migration pauses.

Read in this order: [objects](#objects), [authority](#authority), [upgrading](#flow-upgrading),
[bootstrap](#bootstrap). The central security question is whether the reviewed objects and the
declared external actions account for every executable change: review source/target edges,
target identities, the deployed code at every named address, initializers, engine and composer
code and ownership changes together, and include governance's `forward` and coordinator-replacement
powers. Execution verifies the applied L1 state, not completion on every L2 chain.

## Model

Two objects, deliberately separate:

|          | **Release**                                                                                                               | **Transition**                                   |
| -------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| Answers  | what a chain **is**                                                                                                       | how release A **becomes** release B              |
| Contains | complete facet set (routing self-described by the facets), `DiamondInit`, verifier, genesis params, force-deployment data | upgrade engine, chain schedule, L2 plan          |
| Version  | the protocol version it IS — one release per version                                                                      | reads its `old -> new` edge off its two releases |
| VM flag  | none — every release is a ZKsync OS release                                                                               | —                                                |

A release is the chain state of ONE protocol version: everything a chain _runs_ belongs to it,
including the verifier (the chain stores it as `s.verifier`), and so does the version number itself.
What a release does **not** carry is anything about _when_ — the schedule is the transition's. A
transition authors no version edge: it reads it off its two releases. The CTM moves its version and
its `currentRelease` in one call on both version edges — `setNewVersionUpgradeFromTransition` installs
the transition's `newRelease`, the bootstrap's cut-taking `setNewVersionUpgrade` its genesis release —
and refuses a release of any other version, so the pointer and the version cannot come apart. A bump
that changes no member still publishes a release, differing from its predecessor in the version alone.

**A transition's facet cuts are not authored.** They are derived from its
`(fromRelease, newRelease)` pair in the constructor and stored: a full reinstall — remove the
departing release's routing, install the target's. One shortcut to an empty cut, by value: two
releases whose routing is byte-identical. Governance
reviews two releases plus the transition's own fields; the cuts are computed, not written.

A transition describes one CTM's chain-version edge and nothing else. Infrastructure changes belong
to the third object — the **operation**, named only by the coordinator — which is also what makes
them separable: replacing an ecosystem singleton
behind a CTM-domain proxy is an operation with no transition at all, and therefore costs no
chain-version edge. See
[the coordination document](../protocol-docs/ecosystem-upgrade-coordination.md).

## Objects

All are storage-backed, built once from a manifest they take in the constructor, and commit
`manifestHash = keccak256(abi.encode(manifest))`. The struct definitions and their field docs are
in `l1-contracts/contracts/upgrades/registry/RegistryTypes.sol`.

| Contract                     | Holds                                                                                                                                                                                                                                                                   |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CTMRelease`                 | `diamondInit`, `verifier`, `GenesisFacet[]` (address + freezability), `fixedForceDeploymentsData`, genesis params incl. the genesis upgrade, `l2BytecodeInfos` (the `L2EcosystemContract`-indexed implementation table), one shared `l2SystemProxyBytecodeInfo` shell   |
| `CTMTransition`              | version edge, `fromRelease`, `newRelease`, `upgradeEngine`, `oldProtocolVersionDeadline`, `upgradeTimestamp`, `AuthoredL2Plan`; **derived and stored:** `Diamond.FacetCut[]` and the L2 force deployments                                                               |
| `CoreTransition`             | the `L1EcosystemContract`-indexed inventory of `(proxy, expectedOldImpl, implNew)` rows for the SHARED singletons (bridges, Bridgehub, MessageRoot, …)                                                                                                                  |
| `EcosystemUpgradeOperation`  | `{coreTransition, ctmInfrastructure, ctmTransition}` — three optional changes. `ctmInfrastructure` is the `CTMContract`-indexed CTM-domain inventory, incl. the CTM itself. Executors are bound on the coordinator; an operation carrying no change at all is rejected. |
| `RegistryBootstrapMigration` | one edge from a pre-registry CTM into this model — see [Bootstrap](#bootstrap)                                                                                                                                                                                          |

### Enum-indexed proxy inventories

Proxy upgrades are not carried as anonymous row lists. Each manifest carries a **complete row
array indexed by the canonical contract enum** — the SAME enum that identifies the contract for
deployment, one enum per domain (`ContractIdentifiers.sol`) — whose length must be exactly the
enum's member count (`L1_ECOSYSTEM_CONTRACT_COUNT` / `CTM_CONTRACT_COUNT`):

- `CoreTransitionManifest.proxyUpgrades` is indexed by `L1EcosystemContract`.
- `OperationManifest.ctmInfrastructure` and `BootstrapManifest.ctmProxyUpgrades` are indexed by
  `CTMContract`. Only the members behind a proxy under the CTM-domain `ProxyAdmin` can
  participate: ChainTypeManager, ValidatorTimelock, BytecodesSupplier, PermissionlessValidator,
  the ServerNotifier and the L1InteropFeeManager.

Slot `uint256(member)` IS that contract's row; a slot whose `implNew` is zero is the **"not
upgraded" statement**. The length check means every contract of the domain HAS a slot and none can
be smuggled in, and the enum — being the same one deployment uses — is the single naming scheme end
to end. `ProxyUpgradeRowLib.toRows` flattens the array into the `ProxyUpgradeRow[]` the executors
apply, dropping the inert slots, so the executors never recompile when the inventory grows.

**What the length check does not give you.** It guarantees the SLOTS exist, not that preparation
populated every intended change: an inert slot is the same bytes whether the upgrade deliberately
leaves the contract alone or whether nobody wrote its row builder. Nothing on-chain can tell those
apart — only the run that produced the deployments can. That is why preparation refuses an
implementation it deployed that no row installs and no version script named as deliberately
uninstalled (`_requireDeployedImplementationsInstalled` on both `DefaultCoreUpgrade` and
`DefaultCTMUpgrade`; `uninstalledCoreDeployments` / `uninstalledCTMDeployments` are the
declarations). A reviewer reading a manifest is reading recorded decisions, and still has to check
them against the release.

**A row has no admin of its own.** Every row is applied through the applying executor's bound
`ProxyAdmin`, which administers every proxy of its domain — the ServerNotifier included, after its
[one-time handover](upgrade-operations.md#servernotifier-a-one-time-handover-then-an-ordinary-ctm-domain-proxy).
A row under an admin the executor does not own reverts: a misbound executor is a configuration
error, not something to skip past. `applyRows` re-reads every row after the swaps and reverts
unless each proxy runs its `implNew`, so execution verifies what it applied in the same transaction.

### Reinitializers: a fixed call, no data

A row never carries calldata. Its `callInitializeUpgrade` BOOLEAN is the entire reinitialization
surface: when set, the apply performs `upgradeAndCall` with the FIXED, argument-less
`IProxyUpgradeInitializable.initializeUpgrade()` selector. Everything the reinitializer needs
lives in the new implementation's own audited code — constants, or immutables on L1, both settled
by the deployment governance reviewed. A manifest cannot route the init call to an arbitrary function or
smuggle arguments into it; a wrong reinitialization value is a missing line in an audited contract
diff, never a wrong byte in offchain-authored data.

### Supporting libraries

All twelve helpers below have only internal/private functions and compile into their callers.

| Library                                                                                                         | Role                                                                               |
| --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [TransitionDerivationLib](../l1-contracts/contracts/upgrades/registry/libraries/TransitionDerivationLib.sol)    | Facet cuts and L2 deployments from the source and target releases                  |
| [ReleaseFacetReader](../l1-contracts/contracts/upgrades/registry/libraries/ReleaseFacetReader.sol)              | Genesis installation from a release's self-described routing                       |
| [LiveRoutingReader](../l1-contracts/contracts/upgrades/registry/libraries/LiveRoutingReader.sol)                | Reads departing diamond routing; checks it against the source release              |
| [CTMUpgradeComposer](../l1-contracts/contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol)              | Committed cut and L2 protocol transaction from a transition or bootstrap migration |
| [L2InventoryLib](../l1-contracts/contracts/upgrades/registry/libraries/L2InventoryLib.sol)                      | Maps inventory members to fixed L2 addresses                                       |
| [L2PlanLib](../l1-contracts/contracts/upgrades/registry/libraries/L2PlanLib.sol)                                | Constructs the executable L2 plan and checks bytecode publication                  |
| [VersionEdgeLib](../l1-contracts/contracts/upgrades/registry/libraries/VersionEdgeLib.sol)                      | Checks version ordering and schedule constraints                                   |
| [ProxyUpgradeRowLib](../l1-contracts/contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol)              | Normalizes inventory rows and applies source-checked, verified proxy swaps         |
| [RegistryAuthorityLib](../l1-contracts/contracts/upgrades/registry/libraries/RegistryAuthorityLib.sol)          | Checks executor bindings, ownership and notifier handover                          |
| [ObjectAnchorLib](../l1-contracts/contracts/upgrades/registry/libraries/ObjectAnchorLib.sol)                    | Checks that an object or member has code; does not attest its provenance           |
| [L2CanonicalTransactionLib](../l1-contracts/contracts/state-transition/libraries/L2CanonicalTransactionLib.sol) | Shared construction of canonical L2 transactions                                   |
| [ZKChainSpecificForceDeploymentsLib](../l1-contracts/contracts/upgrades/ZKChainSpecificForceDeploymentsLib.sol) | Builds the per-chain base-token and context payload                                |

There is no intermediate genesis-manifest type between a build and its `ReleaseManifest`:
`DeployCTMUtils.deployCurrentRelease` (and `deployAdditionalReleaseFacets`) assembles the
`GenesisFacet[]` directly as it deploys each facet, and the release's implementation table and its
one shared `l2SystemProxyBytecodeInfo` shell come from `SystemContractsProcessing`.

## Contract map

Who holds what, who reads what. Solid = writes or drives; dashed = reads.

```mermaid
flowchart TB
    subgraph obj["Write-once objects — manifest fixed in the constructor"]
      REL["CTMRelease"]
      TRA["CTMTransition<br/>version edge, engine, chain schedule,<br/>L2 plan + DERIVED cuts"]
      CR["CoreTransition<br/>ecosystem inventory"]
      OP["EcosystemUpgradeOperation<br/>coreTransition + CTM infrastructure<br/>+ transition"]
      BOOT["RegistryBootstrapMigration<br/>pre-registry entry edge"]
      SEQ["RegistryBootstrapSequence<br/>the entry edge's governance bundle, derived"]
    end

    subgraph exe["Executors — immutable bindings"]
      EE["EcosystemUpgradeExecutor (coordinator)<br/>CORE_EXECUTOR · ctmExecutor"]
      CO["CoreUpgradeExecutor<br/>PROXY_ADMIN<br/>coordinator"]
      CE["CTMUpgradeExecutor<br/>CHAIN_TYPE_MANAGER · CTM_PROXY_ADMIN<br/>coordinator"]
    end

    CTM["ChainTypeManager<br/>currentRelease<br/>upgradeTransition[old]"]
    PA["ecosystem ProxyAdmin"]
    CPA["CTM-domain ProxyAdmin"]
    DI["DiamondInit — genesis"]
    ENG["DefaultUpgrade — upgradeFromTransition"]
    BOOTENG["BootstrapUpgrade — upgradeFromBootstrap"]

    EE -. "validate + manifest held to manifestHash()" .-> OP
    EE -- "applyOperation (core leg)" --> CO
    EE -- "applyOperation (CTM leg)" --> CE
    CO -. "validate + rows" .-> CR
    CO -- "upgrade / upgradeAndCall" --> PA
    CE -. "validate + both edges" .-> TRA
    CE -- "the operation's infrastructure rows" --> CPA
    CE -- "setNewVersionUpgradeFromTransition ·<br/>upgradeChainFromVersion" --> CTM
    BOOT -- "one-time: hands over CTM + CTM-domain ProxyAdmin" --> CE

    TRA -. "derive cuts + L2 deployments" .-> REL
    CTM -. "currentRelease · validate + version on install" .-> REL
    DI -. "routing, verifier" .-> REL
    ENG -. "cuts, schedule, target release, L2 plan" .-> TRA
    BOOTENG -. "schedule, genesis release, L2 plan" .-> BOOT
    SEQ -. "both domains' calls, ending in the completion check" .-> BOOT
    SEQ -. "the ecosystem leg" .-> CR
```

## Authority

```mermaid
flowchart LR
    PUH["Governance (owner of every executor)"]
    EE["EcosystemUpgradeExecutor<br/>(coordinator)"]
    CO["CoreUpgradeExecutor"]
    CE["CTMUpgradeExecutor"]
    PA["ecosystem ProxyAdmin"]
    CPA["CTM-domain ProxyAdmin"]
    CTM["ChainTypeManager"]

    PUH -->|"owns · execute · setCTMExecutor · forward"| EE
    PUH -->|"owns · setCoordinator · applyL1Upgrade · forward"| CO
    PUH -->|"owns · setCoordinator · forward"| CE
    EE -.->|"onlyCoordinator applyOperation"| CO
    EE -.->|"onlyCoordinator applyOperation"| CE
    CO -->|owns| PA
    CE -->|owns| CTM
    CE -->|owns| CPA
```

Three executors, one authority root. Governance owns all three; each domain executor holds one
piece of protocol authority and answers to exactly one coordinator, which it names explicitly
(`coordinator`, set by the owner). A shared owner is not authorization: `applyOperation` rejects
callers other than the configured coordinator.

A fresh ecosystem is born in this shape. `DeployL1CoreContracts` deploys the core executor and the
coordinator, binds them and hands the core executor the ecosystem `ProxyAdmin`; `DeployCTM` deploys
the CTM executor answering to that coordinator and hands it the CTM, the CTM-domain `ProxyAdmin`
(every CTM gets its own, even when it reuses the ecosystem's governance and ChainAdmin) and the
ServerNotifier; `RegisterCTM` binds it on the coordinator (`setCTMExecutor`). The scripts construct
the executors for the deployer, which makes these bindings and handovers, and nominate governance,
which accepts in `protocol-ops hub init` / `ctm init`. The end state is exactly what a completed
[bootstrap](#bootstrap) leaves: `RegistryAuthorityLib.requireRegistryAuthority`, the authority half
of `RegistryBootstrapMigration.validateApplied()`, accepts both.

| Executor                   | Bound to (immutable)                      | Entrypoints                                                                                                                            |
| -------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `EcosystemUpgradeExecutor` | `CORE_EXECUTOR`                           | `execute(operation)`, `setCTMExecutor`, `forward` (owner)                                                                              |
| `CoreUpgradeExecutor`      | the ecosystem `ProxyAdmin`                | `applyOperation` (coordinator); `applyL1Upgrade` (owner — bootstrap and recovery); `setCoordinator`, `forward` (owner)                 |
| `CTMUpgradeExecutor`       | one `ChainTypeManager` + its `ProxyAdmin` | `applyOperation` (coordinator); `validateTransitionApplied`; `upgradeChain`; `acceptCTMOwnership`; `setCoordinator`, `forward` (owner) |

The coordinator half of both domain executors — the binding and `applyOperation` — is one shared
surface (`IDomainUpgradeExecutor`; the binding is implemented once in `DomainUpgradeExecutorBase`).

The coordinator owns no proxy administration and applies nothing itself: it validates the operation,
holds its manifest to `manifestHash()` and hands each domain's `applyOperation` that manifest, core
leg first. What `execute` checks and in which order is the
[coordinator spec](../protocol-docs/ecosystem-upgrade-coordination.md).

`UpgradeExecutorBase` gives every executor ONE role. `owner` (`Ownable2Step`) drives the fixed
entrypoints, whose inputs are write-once objects, and the same owner can `forward` raw calls — the
escape hatch that keeps the authority the executor holds reachable, every call logged as
`CallForwarded`. It has no gate of its own: routine proposals and the `EmergencyUpgradeBoard` both
reach the executor through the `ProtocolUpgradeHandler`, so no on-chain distinction between them
exists, and what guards a raw call is the owner's governance process (the handler's timelock, the
Security Council's veto, the board's quorum).

### Authority matrix after bootstrap

Who can do what once the CTM domain is owned by `CTMUpgradeExecutor`. "Chain side" is the
`onlyAdmin` / `onlyAdminOrChainTypeManager` path on the chain's own Admin facet;
`onlyChainTypeManager` methods have no such path; governance reaches them, like every CTM owner
method outside an operation, through the executor's owner-gated, logged `forward`.

| CTM owner method                                                                                                                    | Through the executors                                                             | Chain side                              |
| ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------- |
| `setNewVersionUpgradeFromTransition` (installs the target release too)                                                              | the coordinator's `execute` → `applyOperation` (the operation's transition)       | —                                       |
| `upgradeChainFromVersion`                                                                                                           | `upgradeChain`                                                                    | —                                       |
| `L1ChainAssetHandler.pauseCTMMigration` / `unpauseCTMMigration` (as CTM owner; incident control)                                    | `forward`                                                                         | —                                       |
| `replaceUpgradeTransition` (repair a departed version's transition)                                                                 | `forward`                                                                         | —                                       |
| `setProtocolVersionDeadline`                                                                                                        | `forward`                                                                         | —                                       |
| `freezeChain`, `unfreezeChain`, `setValidator`, `setPriorityTxMaxGasLimit`, `deactivatePriorityMode`, `setValidatorTimelockPostV29` | `forward`                                                                         | — (`onlyChainTypeManager`)              |
| `revertBatches`                                                                                                                     | `forward`                                                                         | validator (`revertBatchesSharedBridge`) |
| `changeFeeParams`, `setTokenMultiplier`                                                                                             | `forward` only                                                                    | chain admin                             |
| `setPendingAdmin`, `setServerNotifier`                                                                                              | `forward` only                                                                    | CTM admin (`onlyOwnerOrAdmin`)          |
| `executeUpgrade` (arbitrary cut), legacy `setNewVersionUpgrade` / `setUpgradeDiamondCut`                                            | `forward` only — deliberately: the bypass the object-driven path exists to remove | —                                       |
| CTM / ProxyAdmin `transferOwnership` (executor succession)                                                                          | `forward` only                                                                    | —                                       |

The executors hold three more authorities, reached the same way outside an operation:
`CTMUpgradeExecutor.forward` for the CTM-domain `ProxyAdmin` and the ServerNotifier's owner methods
(`setUpgradePreconditionChecker`, `setChainTypeManager`), and `CoreUpgradeExecutor.forward` for the
ecosystem `ProxyAdmin` (the core executor's owner may also apply a whole `CoreTransition` directly
with `applyL1Upgrade`). The `L1ChainAssetHandler` stays with its own owner.

## Provenance and validation

**Governance approves the exact deployed objects, and verifying them off-chain is a mandatory step
before every vote.** `protocol-ops ecosystem verify-bootstrap` re-derives each object's address from
the reviewed creation code and the arguments it was constructed with — for a write-once object, the
manifest it serves — and treats "unverifiable" as an error. Nothing on-chain attests to an object's
construction or to what its members run: `validate()` only proves that every contract an object
names is deployed code.

Construction, not runtime code, is what has to be verified: creation code can write arbitrary
storage and then return whatever runtime bytecode it likes, so a contract running the audited
runtime code proves only that — never that the audited CONSTRUCTOR produced the state that code
reads. A `CTMTransition` derives its facet cuts and L2 plan at construction and every chain applies
those cuts by delegatecall; a counterfeit built from adversarial creation code could serve the
approved manifest, pass `validate()` and still route security-critical selectors wherever its author
chose. Objects therefore carry no codehash of themselves or of their members: a hash supplied
beside the address it describes can only agree with itself.

The verification answers three questions for every object a package names:

1. **Was it PRODUCED by the reviewed code's constructor, from its reviewed arguments?** Every
   object is deployed through the deterministic CREATE2 factory (`0x4e59…4956C`), so
   `address == keccak256(0xff ++ factory ++ salt ++ keccak256(creationCode ++ abi.encode(args)))[12:]`.
   For a write-once object the arguments are the manifest it serves: the verifier reads it off the
   object, re-encodes it, and recomputes that address from the reviewed creation code. For the
   executors — the coordinator and both domain executors — and the bootstrap sequence, the
   arguments are the ones each was constructed with (an executor's as its record states them,
   below): the governance owner, the core executor, the ecosystem `ProxyAdmin`, the CTM, its
   `ProxyAdmin` and coordinator.
   Never the object's own getters: a genuine executor built for an attacker's owner answers every
   getter like the reviewed one. What legitimately moves after construction —
   the current owner, a pending nomination, the coordinator — is checked live against the reviewed
   governance and bindings. A match proves the canonical constructor ran on those arguments, which
   covers the object's WHOLE state — immutables, storage and derived fields. The creation-code
   BYTES come from the local build (`l1-contracts/out`), held against the committed
   `evmBytecodeHash`, so a doctored build directory cannot pass. The salt is per prepare leg (the
   core prepare's `[contracts] create2_factory_salt`, each CTM prepare's `[create2_factory_salts]`
   entry); each prepare records the one it deployed under (`create2_factory_salt`), a reviewer may
   add more, and every object is tried under each. The executors outlive the run that deployed them, so that run — `ecosystem init`,
   `ctm init` or the bootstrap prepares — records each one's salt and ORIGINAL constructor
   arguments in its output (`[upgrade_executors]`); a later package is verified against that
   record (`--executor-record`), so an executor whose owner or coordinator has legitimately moved
   since still re-derives. The record is mandatory: an executor without one is unverified.
2. **Does it — and does every member it names — run the reviewed code?** The live code against the
   reviewed build's deployed bytecode of the contract its role admits, byte for byte outside the
   artifact's immutable slots, the build held against `AllContractsHashes.json`. For a write-once
   object that is beside question 1; the executors, whose bindings are immutables, rest on
   question 1 alone. For the MEMBERS — a release's facets, `DiamondInit`, genesis upgrade and
   verifier tree, each engine and composer, each row's `implNew`, and on L2 each bytecode info a
   release's table or a transition's plan names (against the reviewed `(blake2s, length,
keccak256)`) — it is the identity check: nothing records their constructor arguments, so it
   proves their code but not the values their constructors wrote into the masked slots. A release
   may carry over the verifier already in force where it departs from, which an earlier build
   produced. Every proxy row must also name the proxy of its slot, discovered on chain from the
   Bridgehub or the CTM. Code the build does not produce for the role is a finding.
3. **Do the governance calls execute those objects, and nothing else?** For a recurring upgrade
   every call is `coordinator.execute(operation)` or a declared external action. For the bootstrap
   edge the bundle carries the run the construction-verified `RegistryBootstrapSequence` derives,
   contiguous and in order, and every other call must be a declared external action to a target
   OUTSIDE the edge's authorities: a call to the CTM, a `ProxyAdmin`, an executor or an object
   beyond the derived run — a `transferOwnership` nomination appended after the
   legitimate calls, say — is an error whether the package declares it or not. On chain,
   `RegistryBootstrapMigration.validateApplied()` refuses a pending nomination on every
   `Ownable2Step` authority the edge lands on or drives, for the same reason.

The tool's full checklist, including what it deliberately does not check, is in
[`ai-review/docs/protocol-ops.md`](ai-review/docs/protocol-ops.md).

Its limits, stated so they are not mistaken for coverage: the salt is a package input, so an
attacker free to choose both a salt and a counterfeit deployment faces the standard ~2^80 CREATE2
address-collision bound rather than a 160-bit preimage; the derivation binds an object to its
MANIFEST, never to what the manifest's members RUN — a genuine object built from a manifest naming
an attacker's facet verifies perfectly, which is why question 2 holds every member to the reviewed
build; and question 2 proves a member's code, not the values in its immutable slots, so those stay
governance's to review. The first two boundaries are pinned by
`test/foundry/l1/upgrades/CounterfeitObject.t.sol`, which builds an actual counterfeit from real
initcode and asserts the derivation rejects it.

For this to hold, manifest data must live in **storage**, never in immutables: immutables are
patched into runtime code, which would make an object's runtime bytes depend on its manifest and
break question 2.

**Members are named by address.** Everything executable an object names — facets, `DiamondInit`,
the verifier, the genesis upgrade, the upgrade engine, the composer, each `implNew` — is
an ADDRESS; what it runs is held to the reviewed build off chain (question 2), never on chain.

**What the chain enforces**, on every path:

- `ObjectAnchorLib.requireCode` on every object and every member an object names. Not bookkeeping:
  a call to a codeless address SUCCEEDS silently, and a codeless delegatecall target turns a
  chain's upgrade into a no-op that reports success.
- `validate()` on each object, where it is committed or applied (`execute` on the coordinator, which
  validates the whole operation including both transitions it names, `applyL1Upgrade`,
  `applyOperation`, `migrate()`, transition construction for both release edges). Two paths deliberately skip it and say so in code: the per-chain
  `upgradeChain` and the engine's `upgradeFromTransition` execute only the transition the CTM
  already committed, whose members cannot have lost their code since.
- The source-checked edges: every proxy row departs from `expectedOldImpl`, a transition departs
  from the CTM's live `currentRelease` and its live `protocolVersion`, and the bootstrap refuses
  unless the live ecosystem is exactly the starting state its manifest names.
- Authority and bindings: the executors' bound CTM, ProxyAdmin, coordinator and owner, checked by
  value against the manifest before the domain is handed over.
- Execution: the manifest held to the operation's `manifestHash()`, each domain answering only to
  its coordinator.

**Post-state verification.** A second layer proves the upgrade LANDED, in the transaction that
applies it:

- `ProxyUpgradeRowLib.applyRows` re-reads every row after the swaps and reverts unless each proxy
  runs its `implNew` — for the core leg, the CTM leg and the bootstrap's `migrate()` alike.
- `CTMUpgradeExecutor.applyOperation` ends by requiring that the CTM commits exactly this
  transition for its departure and has reached its target; `validateTransitionApplied(transition)`
  serves the same check afterwards, and fails once the transition has been replaced.
- `RegistryBootstrapMigration.validateApplied()` — the bootstrap's completion check, the last call
  of the bootstrap bundle: the CTM domain and the ServerNotifier landed under the bound executor,
  and every executor is governed and bound as the manifest names. Its authority half
  (`RegistryAuthorityLib.requireRegistryAuthority`) is the shape a fresh deployment is born with
  (see [Authority](#authority)).

Whether a chain's diamond routes exactly its release's facets is not checked on chain: the chain's
loupe (`facets()`, `isFacetFreezable`) and each release facet's `selectors()` are public, and
monitoring compares them off chain.

## Chain-type manager state

The CTM stores one release pointer and derives genesis data from it:

- `currentRelease` — the release every new chain is created at. `storedBatchZero()` and
  `l1GenesisUpgrade()` are views over `ICTMRelease(currentRelease).genesisParams()`.
- `upgradeTransition[oldProtocolVersion]` — the transition committed for chains departing from that
  version, and the ONLY commitment for registry-driven edges: `upgradeCutForVersion` derives the cut
  from it on read (a chain is never handed cut bytes), and `protocolVersionDeadline` resolves the
  departing version's deadline from it. The transition's deadline is only the STARTING value:
  `setProtocolVersionDeadline` (owner, through the executor's `forward`) keeps moving it afterwards,
  and a stored value takes precedence. `replaceUpgradeTransition` repairs a departed version's
  transition without moving the CTM (see "Replacing a committed transition" in the
  [coordinator spec](../protocol-docs/ecosystem-upgrade-coordination.md#replacing-a-committed-transition)).
- `upgradeCutHash` — DEPRECATED. Written only by the legacy cut-taking commit path (which the
  bootstrap edge uses); transition commits leave it zero.

Nothing else about a chain's installed state is keyed by protocol version on the CTM: a
chain several versions behind resolves its verifier from the release its own transition names
(`transition.newRelease()`), so a lagging chain is never affected by where `currentRelease` has
moved since.

When a release is installed, the CTM validates its genesis params: a non-zero genesis upgrade and
batch hash, and `genesisBatchCommitment == 1`.

## Flow: creating a chain

1. `L1Bridgehub.createNewChain` records base token and settlement layer, then calls
   `CTM.createNewChain(chainId, admin)`.
2. The CTM builds a genesis cut with **empty** `facetCuts`,
   `initAddress = currentRelease.diamondInit()`, empty `initCalldata`, and deploys the `DiamondProxy`.
3. `DiamondInit.initialize(chainId, admin)` is delegatecalled from the proxy constructor, so
   `msg.sender` is the CTM. It reads `currentRelease`, installs that release's self-described routing via
   `ReleaseFacetReader`, and takes the verifier from the release.
4. The CTM runs `IAdmin.genesisUpgrade`, which delegatecalls the release's genesis engine.
   The engine takes no arguments: it reads the chain context out of the storage `DiamondInit` just
   wrote and the force deployments out of the release its CTM points at, and composes the L2 genesis
   transaction from those. That transaction is the release's initialization edge — the same
   envelope a registry-driven upgrade commits, differing only in the call the `L2ComplexUpgrader`
   performs (`upgrade` into the L2 genesis upgrade, rather than an upgrade's deployment plan), and
   carrying the same per-chain `ZKChainSpecificForceDeploymentsData` an upgrade composes for that
   chain. `IL1GenesisUpgrade.genesisUpgradeTx` serves that composition for inspection, the way
   `IDefaultUpgrade.l2UpgradeTx` does for a transition.

`chainId` and `admin` are the only per-chain inputs; everything else comes from the CTM and the
release it points at. When a chain migrates between settlement layers, `forwardedBridgeBurn`
forwards only `(admin, protocolVersion)`; the destination CTM rebuilds the genesis cut from its
**own** `currentRelease`.

## Flow: upgrading

```mermaid
sequenceDiagram
    participant G as Governance
    participant X as EcosystemUpgradeExecutor
    participant CO as CoreUpgradeExecutor
    participant E as CTMUpgradeExecutor
    participant C as ChainTypeManager
    participant D as Chain diamond

    G->>X: execute(operation)
    Note over X: operation.validate(), manifest held to manifestHash();<br/>applyOperation is onlyCoordinator
    X->>CO: applyOperation(manifest) — core leg first, rows verified
    X->>E: applyOperation(manifest)
    E->>C: infrastructure rows first (CTM-domain ProxyAdmin), verified, then the commit
    E->>C: setNewVersionUpgradeFromTransition(transition) — version, cut and newRelease together
    G->>E: upgradeChain(transition, chainId)
    E->>C: upgradeChainFromVersion(chainId, oldV)
    C->>D: upgradeChainFromVersion(oldV)
    D->>C: upgradeCutForVersion(oldV) — derived from upgradeTransition[oldV]
    Note over D: apply derived facetCuts verbatim,<br/>then version + target release's verifier + composed L2 tx
```

The one `execute(operation)` call is ALL a registry-driven upgrade emits; every other call is a
declared external action listed in the prepare output (see the runbook). An operation applies its
optional core change and then its CTM leg — infrastructure rows, then the transition it may carry —
atomically. One CTM may still manage many chains. The semantics of `execute` are the
[coordinator spec](../protocol-docs/ecosystem-upgrade-coordination.md).

**`upgradeChain(transition, chainId)`** is the per-chain crossing. The executor's owner may
upgrade any chain at any time; a chain's **own admin** may upgrade **that** chain at any time
(scoped per chain because `chainId` is an argument); anyone else only once the old-version
deadline has passed, at which point the upgrade is operationally mandatory and execution carries
no discretionary inputs. The named transition must be the one the CTM committed for the departing
version. Chain admins additionally retain their own direct path on the chain diamond.

**Where the cut is composed.** The cut is a pure function of the transition — an
`upgradeEngine.upgradeFromTransition(transition)` init over no facet cuts — constructed by
`CTMUpgradeComposer.buildUpgradeCutData(ICTMTransition)`. Prepare and the CTM use this same
transition-only function; the bootstrap edge composes its cut the same way from its own object,
`buildBootstrapUpgradeCutData(IRegistryBootstrapMigration)`, served as the migration's
`upgradeCut()`. The CTM hashes it at commit time (`setNewVersionUpgradeFromTransition`)
and re-derives it on read (`upgradeCutForVersion`). It never travels in calldata: not in governance calls, and not to
the chain — the chain's Admin facet takes only the departing version and reads the cut from its
CTM. The chain diamond still treats the cut it reads as opaque bytes and stays unaware of
transitions.

On the chain, `DefaultUpgrade.upgradeFromTransition` first requires the chain's live routing to be
exactly the departing release's (`LiveRoutingDiverged`): the derived cuts remove that release's
routing, not the live one, so a chain a CTM-owner `executeUpgrade` recovery left elsewhere would keep
the recovery's routing under the new release, or fail mid-cut. Such a recovery ends by restoring the
release's routing. It then applies `transition.facetCuts()` verbatim, then
runs the shared storage part (`BaseZkSyncUpgrade._upgrade`) with inputs read straight from the same
object: the version edge and schedule from the transition, the verifier of its TARGET release (never
the CTM's live `currentRelease()`), and the L2 protocol upgrade transaction composed from its L2
plan with the executing chain’s ID and Bridgehub. The delegate composer builds final
chain-specific calldata directly, in one pass; tooling reads that same transaction through
`ICTMTransition.l2UpgradeTx(bridgehub, chainId)`, which forwards to the per-release engine, and
`IRegistryBootstrapMigration.l2UpgradeTx(chainId)` for the bootstrap edge.
There is no intermediate proposal struct, selector resolution or re-diffing at execution time.

The transition's third derived read is for reviewers: `ICTMTransition.releaseDiff()` compares the two
pinned releases member by member — `diamondInit`, `verifier`, `genesisUpgrade`, the facet set, the L2
table, the shared L2 shell, the fixed force-deployments blob, the genesis batch — and returns a
`ReleaseDiff` of booleans. A verifier-only patch therefore reads as exactly one flag and an empty
`facetCuts()`: the whole edge from two calls, with no manifest diffing. Like the cuts it is derived
from the releases on every call and never stored.

## What the derivation guarantees

For any representable release pair, the L1-side guarantee is that **the facet routing and verifier
an existing chain ends up with are byte-for-byte what a fresh chain at `newRelease` gets**, given
the live-routing check above. The
upgrade path and the genesis path resolve to the same release, so they cannot drift. There
is no second mechanism for any part of installed chain state.

The **L2 force deployments are derived too**: only changed, nonempty target rows of the
`l2BytecodeInfos` table are deployed at their member’s fixed address (`L2InventoryLib`). The release
stores each implementation descriptor and one shared system-proxy shell; derivation joins them
into the executable descriptor. Unchanged rows are not reinstalled. A changed shell alone derives
nothing: `updateZKsyncOSContract` deploys a shell only at a system address with no code yet, so a
new shell reaches the members first populated after the edge, and new chains through the genesis
image, but never an existing member's proxy. The shell is rebuilt with every release and its bytes
change with its compiler metadata, so it is not frozen across edges: a change to the shell's logic
needs its own migration of existing proxies, which no transition derives. The chain cannot tell a
rebuild from such a change, so `verify-package` compares the departing and arriving releases'
shells with their compiler metadata stripped. It refuses a changed shell on an edge whose delegate
is absent, the stock `L2DefaultUpgrade` or code the reviewed commit does not build, and asks the
reviewer to confirm any other delegate migrates the existing proxies. A compiler bump that
changes the shell's code counts as a change. The bootstrap edge has no departing release and is
not checked. A row for a member with no fixed address — a proxy, a bridged-token template, the `L2DefaultUpgrade` delegate (deployed from the authored plan below) —
is refused at transition construction (`RegistryMemberHasNoFixedAddress`).

The reviewed input outside that table is `AuthoredL2Plan`: delegate bytecode info, extra bytecode
infos and a calldata composer. `L2PlanLib.build` constructs the delegate and extra
`Unsafe` deployments at bytecode-derived addresses, sets the delegate target, and collects and
deduplicates every installed bytecode’s observable hash into the factory dependencies. Those
addresses, deployment types and dependency hashes are not separately authored or cross-checked.
The CTM’s `BytecodesSupplier` must hold those dependencies published where the edge COMMITS
(`applyOperation` and `migrate()`). What is not proven is what the delegate does on L2: its
bytecode hash names an auditable artifact, not a behavior.

## Rules enforced at construction

**Release shape.** Nonempty facet array; every facet row has selectors; exactly one row per facet
address (`Diamond._addOneFunction` requires uniform freezability per facet); a selector appears in at
most one row. The selector rules read the facets' code, so `validate()` checks them, on every path
that installs a release: the bootstrap and `ChainTypeManager.initialize` install one without cutting
a diamond, so a collision would otherwise surface only when chains execute. The release names each L2 implementation twice — in `l2BytecodeInfos`, which
transitions read, and in `fixedForceDeploymentsData`, which genesis reads — so each bytecode-info
field of the latter must equal `abi.encode(row, l2SystemProxyBytecodeInfo)` for its member's table
row (empty for an empty row), and the genesis and upgrade paths cannot describe different L2 code.
`beaconDeployerInfo` is the exception: its member is not in the force-deployed table, so the blob
is its only copy.

**Version edge.** Read off the two releases, then `newProtocolVersion > oldProtocolVersion` — which
also refuses the same release on both edges; both majors zero; the minor delta is within
`MAX_ALLOWED_MINOR_VERSION_DELTA`. These mirror the rules chains apply at execution, so a
transition cannot construct successfully and then strand every chain.

**Patches.** A patch names a NEW release, like every edge. A release is the immutable snapshot of the intended
contracts, so replacing one of its L1 members — the verifier, a facet — is not by itself a change
of chain-visible L2 state, and should not force a minor bump. What a patch may not do is carry an
L2 upgrade: `BaseZkSyncUpgrade` refuses an L2 protocol upgrade transaction on a patch edge, and a
patch deliberately does NOT require an earlier L2 upgrade to be finalized first, so a pending one
must survive it untouched. The transition therefore validates what a patch CONTAINS rather than
which release it names: no L2 side (derived or authored).

**L2 description.** Every edge without an L2 side — every patch, and a minor edge that only moves
L1 members — must carry the departing release's L2 description over to the target release: the
implementation table and shared proxy shell, the force-deployment blob, the genesis upgrade (it
composes a new chain's L2 genesis transaction) and the genesis batch. Existing chains receive no L2
transaction on such an edge, so a new chain created at the target release must start from the same
L2 state they are in (`L1OnlyEdgeChangesL2State`). An edge that changes the L2 description must
carry an L2 side — at least an authored delegate that brings existing chains there — and so is a
minor edge. The prepare rebuilds the L2 bytecode and reuses the live genesis upgrade only when its
code is identical, so such an edge is built from a tree in which they compile to the departing
release's bytes: an edit to a source they share with L1 (an error added to `L1ContractErrors.sol`,
say) changes their metadata, and the edge then needs an L2 side, so a minor version. A patch that changes nothing but the version names a copy of the departing release one
patch version up, and derives nothing.

A verifier rotation is therefore: deploy the verifier, publish release B copying release A except
that member, publish the `0.35.0 -> 0.35.1` transition naming `A -> B` with no L2 side, execute it
as an ordinary operation. Mechanical permission is not a safety argument: a facet patch still needs the
usual compatibility review of storage layout, proof handling and L2 interaction.

**Schedule.** `oldProtocolVersionDeadline >= upgradeTimestamp`, so the old protocol is never disabled
before chains may upgrade. Both are the transition's, and both are chain-side — see
[the coordination document](../protocol-docs/ecosystem-upgrade-coordination.md#the-chain-schedule).

**L2 plan.** `L2PlanLib.build` checks the remaining input constraints: canonical bytecode-info
lengths, a delegate whenever deployments or a composer exist, and the execution limit on the
constructed factory-dependency count. Deployment addresses, types, delegate membership and
factory-dependency membership follow from construction rather than caller-supplied fields.

**Verifier.** Zero means "leave unchanged" on the upgrade path, which is how the genesis upgrade runs
after `DiamondInit` has already installed it; a release itself can never name a zero verifier. ZKsync
OS chains have no base-system bytecodes, so releases carry none, transitions derive no hash changes,
and the engines take no bytecode-hash inputs.

**Row sets.** Every participating row is a real, unique edge: all fields nonzero, one row per
proxy. A bootstrap manifest must carry at least one row.

**Operation.** At least one real change: a nonzero core transition, a nonempty CTM infrastructure row
set, or a nonzero transition — an all-inert inventory is not a change, so a container that upgrades
nothing is refused. The coordinator binds one CTM executor.
The [multi-CTM extension boundary](../protocol-docs/ecosystem-upgrade-coordination.md#future-multi-ctm-extension)
identifies the schema, coordinator and tooling changes needed to expand participation later.

## Bootstrap

A pre-registry CTM has no `currentRelease`, and transitions never accept a zero `fromRelease`. It
must therefore cross into the model once, through one-time migration code — never through an
accommodation inside the transition model. Fresh ecosystems pin their release at genesis and are
deployed with their executors already bound (see [Authority](#authority)); they need no bootstrap.

`RegistryBootstrapMigration` expresses that crossing as a single write-once object. Its manifest names
the CTM and its departing version, the CTM-domain `ProxyAdmin`, the source-checked implementation
swaps (the CTM's, the ServerNotifier's and the `ValidatorTimelock`'s), the genesis `currentRelease`, the version edge and deadline, the
bootstrap engine and authored L2 plan, the `CTMUpgradeExecutor` that receives the domain,
the `CoreUpgradeExecutor` the ecosystem `ProxyAdmin` lands under, the `coordinator` both answer to
and the `governance` every one of them must already be owned by. Its notifier row is mandatory:
the one-time ServerNotifier handover is a precondition of the edge (see the
[operations document](upgrade-operations.md#servernotifier-a-one-time-handover-then-an-ordinary-ctm-domain-proxy)).

Governance nominates the migration as CTM owner and transfers the CTM-domain `ProxyAdmin` to it;
`migrate()` accepts the CTM, performs the whole edge and hands both to the bound executor in the
same transaction (the CTM through `CTMUpgradeExecutor.acceptCTMOwnership()`, which is
permissionless-safe: it accepts only the bound CTM and only after a nomination). Authority is
never parked.

`validate()` runs on the execution path and requires that the migration holds both ownerships, that
the CTM sits at the departing version, that the ServerNotifier handover completed, that every proxy
row is at its `expectedOldImpl` (or already at `implNew`), that every contract the manifest names is
deployed code and every factory dependency is published, and that both domains' executors are
**bound to what they are about to receive**: the CTM executor's `CHAIN_TYPE_MANAGER`,
`CTM_PROXY_ADMIN` and `coordinator()`, the core executor's `coordinator()`, the coordinator's
`CORE_EXECUTOR` and `ctmExecutor()`, the ecosystem `ProxyAdmin` already handed to the core executor
earlier in the same bundle, and every executor's and the coordinator's `owner()` equal
to `governance` with no pending owner. Ownership and bindings are storage rather than settled by
the reviewed deployment, so they are checked by value: the edge is one-shot, and an executor whose
ownership moved after deployment would receive its domain on behalf of whoever owns it now.

Two properties that look like omissions but are not:

- `migrate()` is **permissionless**. The gate is the state, not the caller: nothing runs until
  governance has handed over both ownerships, which is the approval, and every value written
  afterwards comes from the approved manifest.
- The committed cut carries **no facet cuts and no authored calldata**. The facet delta cannot be
  derived at construction (the departing version predates releases), so the cut's init target is
  the bootstrap engine (`BootstrapUpgrade`), which removes each chain's live routing read from its
  own diamond storage and installs the facet set of the genesis release the migration names. The
  init names the migration and nothing else (`upgradeFromBootstrap(migration)`); at execution the
  engine reads the version edge, the schedule, the target release and the L2 plan from it and
  composes the L2 transaction with the same `CTMUpgradeComposer` transitions use. The engine
  itself is version-independent and holds no release: a chain that crosses the edge after the CTM
  has moved on still lands on the release its own committed migration names. Chains crossing
  the edge run pre-v35 facets and take these bytes by hand (`upgradeCut()`), through the legacy
  cut-taking chain entrypoint; `upgradeTransition` stays zero for the departing version.

`validateApplied()` is the completion check: executed, version reached and release installed, the
CTM domain and the notifier landed under the executor, every executor governed and bound as the
manifest names, no nomination outstanding. It does not re-read the rows: `migrate()` verified them
when it applied them.

The bootstrap edge runs before the coordinator is bound, so its calls are declared external actions
in ONE governance bundle rather than a coordinator call. The bundle accepts the notifier for the CTM
executor (while the ChainAdmin's nomination is unaccepted), binds the core executor to the
coordinator and the coordinator to the CTM executor, hands the ecosystem `ProxyAdmin` to the core
executor and applies the `CoreTransition` through it (`applyL1Upgrade`), hands the CTM and its
`ProxyAdmin` to the migration, runs `migrate()` — which refuses unless all of it holds — and ends
with `validateApplied()`, so a failing completion check reverts the whole edge.

### The sequence is an object too

Those calls are not authored by the prepare scripts. `RegistryBootstrapSequence` is deployed over
the two objects the edge already has — the migration and the `CoreTransition` — and DERIVES the whole
sequence: the manifest names the CTM, its `ProxyAdmin`, both domain executors and the coordinator,
and the core executor names the ecosystem `ProxyAdmin`. The only input the edge does not already
name is the registry, so the sequence pins it: the bundle applies exactly the address this object
was constructed over, and a reviewer reads it off the derived calls.

The prepare reads the calls off that object — label and authority included — and declares each one,
so governance reviews a sequence derived from the objects rather than one a script and the objects
have to agree on. It DESCRIBES, it never executes: ownership transfers run on the governance
caller's authority, and `Governance` issues ordinary calls, so routing them through a helper would
mean giving the contract that holds the ecosystem's authority a generic delegatecall.

Because the object derives both domains and only exists once the migration does, the CTM prepare
deploys it and declares the whole edge; the core prepare of this edge declares nothing, and the
merge — which orders the core prepare's calls ahead of the CTM's — therefore carries the object's
sequence unchanged and contiguous.

`UpgradeTest_Local.t.sol` and the anvil pipeline drive the whole edge through the real prepares,
and `RegistryBootstrapSequence.t.sol` pins the derived bundle.

## Deployment determinism

Objects take their manifest as a constructor argument, so the manifest is part of the initcode and a
CREATE2 address commits to it, and no deployed-but-uninitialized instance ever exists. Every
prepare deployment rides the CREATE2 factory, because the deployer Safe bundle replays factory
transactions only.

Prepares deploy each object from its build artifact (`BytecodeUtils.readBytecodeL1`), the same
bytes a reviewer's build of the reviewed commit produces — the remapping set recorded in CBOR
metadata is pinned, so it does not depend on the machine — and which `AllContractsHashes.json`
commits to. The construction check in `protocol-ops ecosystem verify-bootstrap` rests on that.

The anvil registry runner (`test/anvil-interop/run-recurring-upgrade-test.ts`) deploys its objects
from a committed manifest, `l1-contracts/scripts/registry-manifests/v35-local.json`, and fails on
any drift from it; the contracts that manifest names by a bytecode-derived value come from the
CBOR-metadata-free `registry-deterministic` profile. The manifest is a generated artifact
(`yarn regen:registry-manifest` in `l1-contracts/test/anvil-interop`).

**Gateway.** EraVM has no constructors, so these objects cannot be constructed there. A Gateway CTM
therefore cannot deploy its own `CTMRelease` in-flow and the registry model cannot bump it yet; the
Gateway deployer takes a pre-deployed release address instead (`GatewayCTMDeployerCTMBase`).

## Related

- [Ecosystem upgrade coordination](../protocol-docs/ecosystem-upgrade-coordination.md) — the
  coordinator spec.
- [Upgrade operations](upgrade-operations.md) — the ServerNotifier handover, coordinator
  succession, monitoring, recovery and the incident-only migration pauses.
- [Upgrade scripts runbook](../l1-contracts/deploy-scripts/upgrade/README.md) — prepare, compose,
  verify, replay, chain crossing.
- [Script retirement plan](upgrade-script-retirement.md) — what tooling still decides, and the
  batches that move it on-chain.
- [Governance self-migration](governance-self-migration.md) — how the authority root above
  upgrades itself.
