# Chain type manager

A `ChainTypeManager` (CTM) is the factory and protocol-version authority for a compatible family of ZK
chains. Chains in one CTM intentionally share the verifier, genesis definition, facet set, and upgrade
rules needed for them to trust one another's settled state.

## Responsibilities

- Point at the current release (`currentRelease`), whose genesis upgrade, genesis batch values, facet
  set and force-deployment data new chains are created from.
- Deploy and initialize a chain diamond when called by Bridgehub, then record the chain ID -> diamond
  association.
- Commit semver protocol versions as transitions, from which the chains' upgrade cut, verifier and the
  old version's deadline are derived.
- Execute an approved upgrade for a chain. Once a protocol-version deadline expires, commits under
  that version fail; freezing and unfreezing remain separate CTM-owner operations.
- Forward the limited administrative operations exposed by the chain diamond, such as validator, fee,
  and porter configuration.

The CTM owner/admin is a protocol-level trust boundary. A chain admin cannot install arbitrary facets
or choose an unapproved verifier; it can only exercise the per-chain powers exposed through the CTM and
`AdminFacet`.

## Protocol versions

`setNewVersionUpgradeFromTransition(transition)`, called by the CTM's owner (the bound
`CTMUpgradeExecutor`, in its `applyCTMUpgrade`), advances from the transition's old
version and release, records the transition under the old version and installs the target release;
chains read their cut from it (`upgradeCutForVersion`) and the verifier from the target release. A
verifier-only upgrade is a patch transition between releases that differ only in the verifier. The
cut-taking `setNewVersionUpgrade` remains only for the v35 bootstrap edge. A chain that has not
upgraded by the relevant deadline cannot continue normal batch processing until it reaches an active
version. The model is described in
[Registry-driven protocol upgrades](../../../../docs/registry-driven-upgrades.md#chain-type-manager-state).

Upgrade creation and operational sequencing are described in [upgrade process](./upgrade_process.md)
and [creating upgrades](./creating_upgrades.md). Current chain creation and in-place upgrade state are
documented in {protocol-docs/chain-lifecycle.md}.
