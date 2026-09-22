# Protocol upgrade process

Protocol upgrades are coordinated by the chain type manager (CTM) and executed by each chain diamond.
An upgrade is a `DiamondCutData` value containing facet cuts plus an optional initializer delegate-call.
The initializer may update shared diamond storage and enqueue an L2 system-upgrade transaction.

## Publishing a version

CTM governance calls `setNewVersionUpgrade` with:

- the expected old protocol version and its deadline;
- the new semver protocol version;
- the verifier for the new version;
- the approved diamond cut and initialization calldata.

The CTM stores the upgrade cut hash/data and verifier under the new version. A verifier-only release can
use `createNewVerifierOnlyUpgrade`; it advances the protocol version without changing facets. Patch,
minor, and major components are packed by `SemVer.sol`, and version activity/deadlines are enforced by
the CTM rather than inferred from deployment time.

## Applying a version to a chain

1. The chain admin submits the exact CTM-approved cut through `upgradeChainFromVersion` or the CTM's
   execution entry point.
2. `AdminFacet` verifies the old version and cut, applies facet changes, and delegate-calls the upgrade
   initializer.
3. If the release changes L2 code or state, the initializer records the canonical system-upgrade
   transaction. It is consumed in the next compatible batch.
4. The diamond records the new protocol version. Chains that remain on an expired version cannot
   continue normal batch processing until upgraded.

Upgrade implementations derive from `BaseZkSyncUpgrade`; `DefaultUpgrade` covers the common verifier,
bootloader, system-contract, fee, and protocol-version changes. Releases with one-time migrations use a
version-specific implementation and staged governance calls.

## Safety properties

- A chain admin cannot install a cut the CTM did not publish.
- The old-version argument prevents applying an upgrade from an unexpected state.
- Upgrade deadlines keep chains sharing a CTM within the supported compatibility window.
- Batch processing may require outstanding batches to be executed before changing verifier or batch
  semantics.
- Emergency freeze/revert controls limit further settlement while governance prepares remediation;
  they do not make an invalid proof valid.

Release-specific state migrations and ZKsync OS force deployments are documented in
{protocol-docs/chain-lifecycle.md#upgrading-an-existing-ecosystem-onto-this-release}.
