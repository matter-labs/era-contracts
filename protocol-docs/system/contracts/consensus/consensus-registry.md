# Consensus registry

`ConsensusRegistry` is an upgradeable L2 registry for the validator committee consumed by off-chain
consensus nodes. It stores validator owners, BLS12-381 public keys and proofs of possession, weights,
active/removed state, leader eligibility, and leader-selection parameters.

## Roles

- The contract owner adds and removes validators, changes weight/leader status, configures committee
  activation delay and leader selection, and commits a new committee snapshot.
- A validator owner may activate/deactivate its own validator and rotate its key and proof of
  possession. The contract owner may perform those operations as well.
- Consensus clients read the active or pending committee through the getter methods.

## Committee snapshots

Changes first affect `latest` validator state. `commitValidatorCommittee` increments the commit number
and schedules that state to become active after `committeeActivationDelay` L2 blocks. Until activation,
clients can query both the current and next committees. Snapshot and previous-snapshot fields allow the
contract to materialize the correct version lazily without copying every validator on each commit.

A commit requires at least one active, non-removed leader. Public-key hashes are unique, so two
registered validators cannot claim the same key.

The registry does not verify chain validity proofs and is not part of the L1 batch-settlement
authorization path. `ValidatorTimelock` and the chain diamond separately control who may submit and
finalize L1 batches.
