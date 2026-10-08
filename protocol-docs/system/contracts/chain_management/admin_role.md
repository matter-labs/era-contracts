# Chain administration

Each chain has an admin recorded in its diamond. This role controls chain-local operational settings;
it does not choose arbitrary protocol code. Facet changes, verifier changes, and protocol versions must
come through the chain's CTM.

## Administrative powers

Depending on the chain type and active protocol version, the admin can:

- grant or revoke that chain's precommitter, committer, reverter, prover, executor, and upgrader
  roles in `ValidatorTimelock`; the timelock resolves its per-chain default administrator from
  `IZKChain.getAdmin()`;
- change priority-transaction fee parameters and the base-token price multiplier;
- configure a transaction filter for incoming L1 -> L2 requests;
- select a compatible L1 DA validator and commitment scheme;
- make the chain a permanent rollup;
- pause selected bridge or migration operations through their owning contracts.

These powers affect availability, censorship, and fee safety even though validity proofs continue to
protect state-transition correctness. The admin should therefore be a governed contract or robust
multisig, not a hot EOA. Narrow operational roles should be separated where practical.

## Permanent rollup

`makePermanentRollup` is irreversible. Once enabled, the chain can only use DA validator pairs approved
for rollup operation by protocol governance. This prevents a later chain admin from weakening the DA
guarantee to validium, but also permanently limits the chain to the approved rollup configurations.

## Restricted administration

The repository includes `ChainAdmin` plus modular restrictions. `AccessControlRestriction` assigns
selectors to roles. `PermanentRestriction` constrains selected calls and prevents a future admin from
removing the restriction. Restrictions are part of the chain's governance design and must be reviewed
against the exact protocol version and intended emergency procedures.

This is distinct from the legacy validator allowlist stored in the chain diamond: calls to
`AdminFacet.setValidator` are forwarded by the CTM and controlled by the CTM owner.
