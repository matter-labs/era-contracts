# Chain type manager

A `ChainTypeManager` (CTM) is the factory and protocol-version authority for a compatible family of ZK
chains. Chains in one CTM intentionally share the verifier, genesis definition, facet set, and upgrade
rules needed for them to trust one another's settled state.

## Responsibilities

- Store the current `ChainCreationParams`: genesis upgrade, genesis batch values, initial diamond cut,
  and force-deployment data.
- Deploy and initialize a chain diamond when called by Bridgehub, then record the chain ID -> diamond
  association.
- Publish semver protocol versions, verifier addresses, diamond cuts, and upgrade deadlines.
- Execute an approved upgrade for a chain and freeze chains that miss required upgrade conditions.
- Forward the limited administrative operations exposed by the chain diamond, such as validator, fee,
  and porter configuration.

The CTM owner/admin is a protocol-level trust boundary. A chain admin cannot install arbitrary facets
or choose an unapproved verifier; it can only exercise the per-chain powers exposed through the CTM and
`AdminFacet`.

## Protocol versions

`setNewVersionUpgrade` advances from an expected old version, records the old-version deadline, stores
the new verifier and upgrade cut, and makes the new version available to its chains. A verifier-only
upgrade uses the same version/deadline model without changing facets. A chain that has not upgraded by
the relevant deadline cannot continue normal batch processing until it reaches an active version.

Upgrade creation and operational sequencing are described in [upgrade process](./upgrade_process.md)
and [creating upgrades](./creating_upgrades.md). Current chain creation and in-place upgrade state are
documented in {protocol-docs/chain-lifecycle.md}.
