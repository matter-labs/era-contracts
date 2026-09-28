# L1 transaction gas limit

From v34 / ZKsync OS 0.6.0, newly admitted L1 → L2 transactions have a protocol
gas ceiling of 2²⁴ (16,777,216). This bounds the work and gas-funded pubdata that
one priority operation can request. Gas pricing and the computational-native
ceiling do not change. The chain-configured L2 transaction gas limit is independent.

`PRIORITY_TX_MAX_GAS_LIMIT` in `l1-contracts/contracts/common/Config.sol` is the
ceiling and the default for new chains. The chain type manager may set a lower
`priorityTxMaxGasLimit`, including zero, but cannot exceed the ceiling.

Admission uses the smaller of the stored chain limit and the protocol ceiling.
The getter reports that effective limit. This also covers existing chains whose
storage still contains the former 72M default or a higher configured limit,
without migrating storage. A lower stored limit remains effective.

The shared transaction validator applies the ceiling to priority requests and
protocol upgrades. Genesis, service transactions, gateway relay wrappers, and
deployment/upgrade tooling request the same constant.
Previously queued transactions keep their original gas limits and remain
processable by ZKsync OS; the runtime does not retroactively reject them.
