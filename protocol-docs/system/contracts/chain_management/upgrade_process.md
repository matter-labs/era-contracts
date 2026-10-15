# Protocol upgrade process

Protocol upgrades are coordinated by the chain type manager (CTM) and executed by each chain diamond.
What the CTM publishes is a write-once `CTMTransition` between two `CTMRelease` objects, and the cut a
chain executes is derived from it: no facet cuts of its own, the transition's upgrade engine as the
initializer and `upgradeFromTransition(transition)` as its calldata. The engine applies the
transition's facet cuts, updates shared diamond storage and enqueues the L2 system-upgrade
transaction. The objects, and why the cut is derived rather than supplied, are described in
[Registry-driven protocol upgrades](../../../../docs/registry-driven-upgrades.md).

## Publishing a version

Governance publishes a version by executing an upgrade operation
(`EcosystemUpgradeExecutor.execute(operation)`); the CTM leg of that one call reaches the CTM through
its owner, the bound `CTMUpgradeExecutor`, as `setNewVersionUpgradeFromTransition(transition)`
([Ecosystem upgrade coordination](../../../ecosystem-upgrade-coordination.md#execution)). The
transition carries everything the CTM commits for the edge:

- the old protocol version and its deadline (none by default);
- the new semver protocol version and the upgrade timestamp;
- the target release, including the verifier for the new version;
- the facet cuts, derived from the two releases when the transition was constructed, and the L2 plan
  the chain's upgrade transaction is composed from.

The CTM checks that the transition departs from its current version and release, moves its
`protocolVersion`, records the transition under the old version (`upgradeTransition`) and installs
the target release as `currentRelease`, which new chains start from. It stores no cut:
`upgradeCutForVersion(oldVersion)` derives it from the recorded transition on every read. A
verifier-only release is a patch transition between releases that differ only in the verifier
("Patches" in
[Rules enforced at construction](../../../../docs/registry-driven-upgrades.md#rules-enforced-at-construction)).
Patch, minor, and major components are packed by `SemVer.sol`, and version activity/deadlines are
enforced by the CTM rather than inferred from deployment time. The cut-taking `setNewVersionUpgrade`
remains only for the v35 bootstrap edge, whose departing version has no release to derive a cut
from.

## Applying a version to a chain

1. The chain admin calls `upgradeChainFromVersion(chainAddress, oldVersion)` on the chain, or the
   crossing goes through the CTM with `CTMUpgradeExecutor.upgradeChain(transition, chainId)`, which
   the executor's owner may call at any time, the chain's admin for its own chain, and anyone else
   once the old version's deadline has passed. The caller supplies no cut.
2. `AdminFacet` checks the old version, reads the cut from its CTM (`upgradeCutForVersion`) and
   executes it: the engine applies the transition's facet cuts, then installs the target release's
   verifier and the new version.
3. If the release changes L2 code or state, the engine records the canonical system-upgrade
   transaction, composed from the transition's L2 plan for this chain. It is consumed in the next
   compatible batch.
4. The diamond records the new protocol version. Chains that remain on an expired version cannot
   continue normal batch processing until upgraded.

Upgrade engines derive from `BaseZkSyncUpgrade`; `DefaultUpgrade` covers the common verifier,
bootloader, system-contract, fee, and protocol-version changes and is the engine a transition pins
unless the release overrides it (the v35 bootstrap edge uses `BootstrapUpgrade`). Work a release
needs outside the chain diamonds is part of the same governance call: proxy rows of the operation,
or declared external actions.

## Safety properties

- A chain admin cannot install a cut the CTM did not publish.
- The old-version argument prevents applying an upgrade from an unexpected state.
- Upgrade deadlines keep chains sharing a CTM within the supported compatibility window.
- Batch processing may require outstanding batches to be executed before changing verifier or batch
  semantics.
- Emergency freeze/revert controls limit further settlement while governance prepares remediation;
  they do not make an invalid proof valid.

Release-specific state migrations and ZKsync OS force deployments are documented in
[Upgrading an existing ecosystem onto this release](../../../chain-lifecycle.md#upgrading-an-existing-ecosystem-onto-this-release).
The operational pipeline that prepares, verifies and rolls out a release across an ecosystem is
described in [Upgrading an ecosystem](../../../ecosystem-upgrade.md).
