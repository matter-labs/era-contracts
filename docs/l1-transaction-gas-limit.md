# L1 transaction gas limit

From v34 / ZKsync OS 0.6.0, newly admitted L1 → L2 transactions have a protocol
gas ceiling of 2²⁴ (16,777,216). This bounds the work and gas-funded pubdata that
one priority operation can request. Gas pricing and the computational-native
ceiling do not change. The chain-configured L2 transaction gas limit is independent.

`PRIORITY_TX_MAX_GAS_LIMIT` in `l1-contracts/contracts/common/Config.sol` is the
ceiling and the default for new chains. The chain type manager may set a lower
`priorityTxMaxGasLimit`, including zero, but cannot exceed the ceiling.

The v34 per-chain upgrade (`V34UpgradeZKsyncOS`, the default ZKsync OS upgrade
used as the initializer of `CTMUpgrade_v34`'s cut) clamps the stored
limit to the protocol ceiling and emits `NewPriorityTxMaxGasLimit` if it
changes. This happens atomically with the facet upgrade and preserves lower
limits, including zero. New chains initialize with the ceiling, so from v34 on
no chain stores a limit above it: admission checks the stored limit, and the
getter returns it directly. The CTM default upgrade, used by later releases, does
not touch the limit.

Service transactions, gateway relay wrappers, and priority-request tooling use
the same ceiling. Genesis and protocol-upgrade transactions retain a separate
72,000,000 gas ceiling, `UPGRADE_TX_MAX_GAS_LIMIT`, independent of the chain's
priority admission limit. Their pubdata and minimum-gas checks still apply.
Previously queued transactions keep their original gas limits and remain
processable by ZKsync OS; the runtime does not retroactively reject them.
