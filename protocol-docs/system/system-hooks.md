# ZKsync OS system hooks

System hooks are native ZKsync OS handlers registered during bootloader initialization. They connect
fixed-address Solidity contracts and standard EVM interfaces to operations implemented by the OS:
publishing protocol output, changing native account state, installing bytecode metadata, or running a
precompile. A hook is not an independently deployed contract.

There are two protocol-facing forms:

- **Call hooks** intercept calls to a registered low address and return an EVM-compatible success or
  failure result.
- **Event hooks** observe events from a registered system-contract address and copy the decoded value
  into the OS I/O state used to build the block or batch output.

## Protocol call hooks

| Address  | Hook and authorized caller                                                                    | Effect                                                                                                                                                        |
| -------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x7001` | L1 messenger; only `L1MessengerZKOS` at `0x8008`                                              | Accepts the 20-byte sender followed by the message and records a variable-length L2 -> L1 message in the OS output.                                           |
| `0x7002` | Set bytecode on address; only `ContractDeployer` at `0x8006` or `ComplexUpgrader` at `0x800f` | Installs EVM bytecode metadata for an address during genesis or a protocol upgrade.                                                                           |
| `0x7003` | Optional proof-status hook, enabled by static chain configuration                             | Accepts a 32-byte statement versioned hash and returns whether it was verified earlier in the current transaction. It has no Solidity caller in this release. |
| `0x7004` | Interop commitment leaf; only `L2InteropCommitmentTree` at `0x10012`                          | Records each inserted 32-byte commitment-tree value as an L2 -> L1 log, keeping the tree reconstructible from published data.                                 |
| `0x7100` | Mint base token; only `L2BaseTokenZKOS` at `0x800a`                                           | Adds the ABI-encoded 32-byte amount to the caller's native-token balance during genesis or upgrade initialization.                                            |
| `0x8006` | Contract-deployer compatibility hook; only `ComplexUpgrader` at `0x800f`                      | Implements `setBytecodeDetailsEVM` directly for upgrade compatibility. New contract-side code uses the `0x7002` hook through `ZKOSContractDeployer`.          |

The Solidity-facing addresses are defined in
`l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol`. Their callers are implemented by
`L1MessengerZKOS`, `ZKOSContractDeployer`, `L2BaseTokenZKOS`, and
`L2InteropCommitmentTree`. The mint and bytecode hooks are privileged initialization or upgrade paths;
they are not general-purpose user minting or deployment APIs.

## Event hooks

| Emitting contract                   | Observed event                                        | Effect in ZKsync OS                                                                                                    |
| ----------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `SystemContext` at `0x800b`         | `SettlementLayerChainIdUpdated(uint256)`              | Updates the settlement-layer chain ID held by the OS I/O subsystem.                                                    |
| `L2InteropRootStorage` at `0x10008` | `InteropRootAdded(uint256,uint256,uint256,bytes32[])` | Decodes the chain ID, block or batch number, timestamp, and single root, then adds that interop root to the OS output. |

Event hooks ignore unrelated event signatures from the same contract. A matching event with malformed
topics or data is an internal protocol error rather than an event that can be partially accepted.

## EVM precompiles

ZKsync OS uses the same call-hook mechanism for its EVM precompiles. The installed set contains
`ecrecover`, SHA-256, RIPEMD-160, identity, modular exponentiation, BN254 addition/multiplication/pairing,
BLAKE2f, point evaluation, P-256 verification, and the BLS12-381 addition, MSM, pairing, and map-to-curve
operations. These live at their EVM precompile addresses rather than in the `0x7000` protocol-hook range.

## Dispatch and failure rules

- The bootloader registers precompiles first, then the ZKsync-specific call and event hooks. A build
  with system contracts disabled retains only the precompiles.
- Each privileged call hook checks its immediate caller. Hooks that must remain indistinguishable from
  an empty EVM account return empty success to an unauthorized caller instead of exposing privileged
  behavior.
- State-changing hooks reject static context, unexpected value, malformed calldata, and unsupported
  call modifiers. The Solidity caller treats a failed hook call as a failed protocol operation.
- Resource charging is split deliberately: the Solidity system contract burns the EVM-visible gas for
  operations such as emitting an L2 -> L1 log, while the hook charges the corresponding native resource
  work performed by ZKsync OS.

For the contract-level flows that consume hook output, see {protocol-docs/message-root.md},
{protocol-docs/atomicity/imt.md}, and {protocol-docs/chain-lifecycle.md}.
