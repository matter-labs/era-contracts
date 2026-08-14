# Governance Self-Migration

**Status:** design. The implementation belongs in
[zk-governance](https://github.com/zksync-association/zk-governance) and is its own audit scope;
nothing in era-contracts blocks on it.

The registry model's authority chain bottoms out at the governance layer: the domain executors'
`owner` is the `ProtocolUpgradeHandler` (PUH), and break-glass is separately governed. See
[Registry-driven protocol upgrades](./registry-driven-upgrades.md) for the layer above.

## The problem

That layer upgrades itself by **redeploy plus ownership migration**, not by proxy-implementation
swaps: a fresh PUH implementation and proxy (CREATE3), fresh immutable multisigs (Guardians,
SecurityCouncil, EmergencyUpgradeBoard), and then a proposal through the old PUH re-pointing
ownership of every owned contract at the new one.

Today that proposal is hand-authored calldata — the last remaining hand-authored upgrade surface in
the system.

## Why not a standing executor

A `GovernanceUpgradeExecutor` analogous to the CTM and ecosystem ones does not fit:

- the payload is an ownership-migration set, not proxy swaps, so a `ProxyAdmin`-bound executor does
  not describe it;
- the PUH already executes arbitrary calls, so a permanently-owned executor between the PUH and
  itself adds indirection without new authority separation.

## Shape

A **write-once `GovernanceMigration` object** — the same data discipline applied to succession:

- factory-deployed (`deployOrGet`, CREATE3-compatible), write-once, `validate()` reverting,
  `manifestHash` as the 32-byte commitment;
- pins the new PUH implementation and each new multisig with inline codehashes;
- carries **source-checked ownership edges** — `(target, expectedCurrentOwner -> newOwner)` plus the
  analogous proxy-admin edges — so a stale or replayed migration cannot re-point ownership backwards.
  This is the `expectedOldImpl` property of `EcosystemContractRow`, applied to authority instead of
  implementations;
- executed by one call in one PUH proposal (`migration.execute()`, gated `msg.sender == PUH`). The
  audit unit becomes the migration manifest. The EmergencyUpgradeBoard remains the break-glass
  analogue, unchanged.

## Coupling to era-contracts

The executor fleet's `owner` and `breakGlassGovernor` pointers (`CTMUpgradeExecutor`,
`EcosystemUpgradeExecutor`) are themselves edges such a migration must move, so the
source-checked-edge row shape should be shared through a small extracted library rather than
reimplemented on each side.
