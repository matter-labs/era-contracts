# Overview

zkSync Era is a permissionless general-purpose ZK rollup. Similar to many L1 blockchains and sidechains it enables
deployment and interaction with Turing-complete smart contracts.

- L2 smart contracts are executed on a zkEVM.
- zkEVM bytecode is different from the L1 EVM.
- There is a Solidity and Vyper compilers for L2 smart contracts.
- There is a standard way to pass messages between L1 and L2. That is a part of the protocol.
- There is no escape hatch mechanism yet, but there will be one.

All data that is needed to restore the L2 state are also pushed on-chain. There are two approaches, publishing inputs of
L2 transactions on-chain and publishing the state transition diff. zkSync follows the second option.

See the [documentation](https://era.zksync.io/docs/dev/fundamentals/rollups.html) to read more!

## Glossary

- **Governor** - a privileged address that controls the upgradability of the network and sets other privileged
  addresses.
- **Security council** - an address of the Gnosis multisig with the trusted owners that can decrease upgrade timelock.
- **Validator/Operator** - a privileged address that can commit/verify/execute L2 batches.
- **L2 batch (or just batch)** - An aggregation of multiple L2 blocks. Note, that while the API operates on L2 blocks,
  the prove system operates on batches, which represent a single proved VM execution, which typically contains multiple
  L2 blocks.
- **Facet** - implementation contract. The word comes from the EIP-2535.
- **Gas** - a unit that measures the amount of computational effort required to execute specific operations on the
  zkSync Era network.

### L1 Smart contracts

#### Diamond

Technically, this L1 smart contract acts as a connector between Ethereum (L1) and zkSync (L2). This contract checks the
validity proof and data availability, handles L2 <-> L1 communication, finalizes L2 state transition, and more.

There are also important contracts deployed on the L2 that can also execute logic called _system contracts_. Using L2
<-> L1 communication can affect both the L1 and the L2.

#### DiamondProxy

The main contract uses [EIP-2535](https://eips.ethereum.org/EIPS/eip-2535) diamond proxy pattern. It is an in-house
implementation that is inspired by the [mudgen reference implementation](https://github.com/mudgen/Diamond). It has no
external functions, only the fallback that delegates a call to one of the facets (target/implementation contract). So
even an upgrade system is a separate facet that can be replaced.

One of the differences from the reference implementation is access freezability. Each of the facets has an associated
parameter that indicates if it is possible to freeze access to the facet. Privileged actors can freeze the **diamond**
(not a specific facet!) and all facets with the marker `isFreezable` should be inaccessible until the admin or the state transition manager unfreezes the diamond. Note that it is a very dangerous thing since the diamond proxy can freeze the upgrade
system and then the diamond will be frozen forever.

#### DiamondInit

It is a one-function contract that implements the logic of initializing a diamond proxy. It is called only once on the
diamond constructor and is not saved in the diamond as a facet.

Implementation detail - function returns a magic value just like it is designed in
[EIP-1271](https://eips.ethereum.org/EIPS/eip-1271), but the magic value is 32 bytes in size.

#### GettersFacet

Separate facet, whose only function is providing `view` and `pure` methods. It also implements
[diamond loupe](https://eips.ethereum.org/EIPS/eip-2535#diamond-loupe) which makes managing facets easier. This contract
must never be frozen.

#### AdminFacet

Controls changing the privileged addresses such as admin and validators or one of the system parameters (L2
bootloader bytecode hash, verifier address, verifier parameters, etc), and it also manages the freezing/unfreezing and
execution of upgrades in the diamond proxy.

#### Governance

This contract manages operations (calls with preconditions) for governance tasks. The contract allows for operations to
be scheduled, executed, and canceled with appropriate permissions and delays. It is used for managing and coordinating
upgrades and changes in all zkSync Era governed contracts.

Each upgrade consists of two steps:

- Upgrade Proposal - The governor can schedule upgrades in two different manners:
  - Fully transparent data. All implementation contracts and migration contracts are known to the community. The governor must wait
    for the timelock to execute the upgrade.
  - Shadow upgrade. The governor only shows the commitment for the upgrade. The upgrade can be executed only with security council
    approval without timelock.
- Upgrade execution - perform the upgrade that was proposed.

#### MailboxFacet

The facet that handles L2 <-> L1 communication, an overview for which can be found in
[docs](https://era.zksync.io/docs/dev/developer-guides/bridging/l1-l2-interop.html).

The Mailbox performs three functions:

- L1 <-> L2 communication.
- Bridging native Ether to the L2.
- Censorship resistance mechanism (not yet implemented).

L1 -> L2 communication is implemented as requesting an L2 transaction on L1 and executing it on L2. This means a user
can call the function on the L1 contract to save the data about the transaction in some queue. Later on, a validator can
process it on L2 and mark them as processed on the L1 priority queue. Currently, it is used for sending information from
L1 to L2 or implementing multi-layer protocols.

_NOTE_: While user requests the transaction from L1, the initiated transaction on L2 will have such a `msg.sender`:

```solidity
  address sender = msg.sender;
  if (sender != tx.origin) {
      sender = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
  }
```

where

```solidity
uint160 constant offset = uint160(0x1111000000000000000000000000000000001111);

function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
  unchecked {
    l2Address = address(uint160(l1Address) + offset);
  }
}
```

For most of the rollups the address aliasing needs to prevent cross-chain exploits that would otherwise be possible if
we simply reused the same L1 addresses as the L2 sender. In zkSync Era address derivation rule is different from the
Ethereum, so cross-chain exploits are already impossible. However, zkSync Era may add full EVM support in the future, so
applying address aliasing leave room for future EVM compatibility.

The L1 -> L2 communication is also used for bridging ether. The user should include a `msg.value` when initiating a
transaction request on the L1 contract. Before executing a transaction on L2, the specified address will be credited
with the funds. To withdraw funds user should call `withdraw` function on the `L2EtherToken` system contracts. This will
burn the funds on L2, allowing the user to reclaim them through the `finalizeEthWithdrawal` function on the
`MailboxFacet`.

L2 -> L1 communication, in contrast to L1 -> L2 communication, is based only on transferring the information, and not on
the transaction execution on L1.

From the L2 side, there is a special zkEVM opcode that saves `l2ToL1Log` in the L2 batch. A validator will send all
`l2ToL1Logs` when sending an L2 batch to the L1 (see `ExecutorFacet`). Later on, users will be able to both read their
`l2ToL1logs` on L1 and _prove_ that they sent it.

From the L1 side, for each L2 batch, a Merkle root with such logs in leaves is calculated. Thus, a user can provide
Merkle proof for each `l2ToL1Logs`.

_NOTE_: For each executed L1 -> L2 transaction, the system program necessarily sends an L2 -> L1 log. To verify the
execution status user may use the `proveL1ToL2TransactionStatus`.

_NOTE_: The `l2ToL1Log` structure consists of fixed-size fields! Because of this, it is inconvenient to send a lot of
data from L2 and to prove that they were sent on L1 using only `l2ToL1log`. To send a variable-length message we use
this trick:

- One of the system contracts accepts an arbitrary length message and sends a fixed length message with parameters
  `senderAddress == this`, `isService == true`, `key == msg.sender`, `value == keccak256(message)`.
- The contract on L1 accepts all sent messages and if the message came from this system contract it requires that the
  preimage of `value` be provided.

#### L1 -> L2 Transaction filtering

There is a mechanism for applying custom filters to the L1 -> L2 communication. It is achieved by having an address of
the `TransactionFilterer` contract in the `ZkSyncHyperchainStorage`. If the filterer exists, it is being called in
the `Mailbox` facet with the tx details and has to return whether the transaction can be executed or not. The filterer
has to implement the `ITransactionFilterer` interface. The ones intended to use this feature, have to deploy the
contract that implements `ITransactionFilterer` and use `setTransactionFilterer` function of `AdminFacet` to set the
address of the transaction filterer. The same function called with `0` address will disable the filtering.

#### ExecutorFacet

A contract that accepts L2 batches, enforces data availability and checks the validity of zk-proofs.

The state transition is divided into three stages:

- `commitBatches` - check L2 batch timestamp, process the L2 logs, save data for a batch, and prepare data for zk-proof.
- `proveBatches` - validate zk-proof.
- `executeBatches` - finalize the state, marking L1 -> L2 communication processing, and saving Merkle tree with L2 logs.

Each L2 -> L1 system log will have a key that is part of the following:

```solidity
enum SystemLogKey {
  L2_TO_L1_LOGS_TREE_ROOT_KEY,
  TOTAL_L2_TO_L1_PUBDATA_KEY,
  STATE_DIFF_HASH_KEY,
  PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
  PREV_BATCH_HASH_KEY,
  CHAINED_PRIORITY_TXN_HASH_KEY,
  NUMBER_OF_LAYER_1_TXS_KEY,
  EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY
}
```

When a batch is committed, we process L2 -> L1 system logs. Here are the invariants that are expected there:

- In a given batch there will be either 7 or 8 system logs. The 8th log is only required for a protocol upgrade.
- There will be a single log for each key that is contained within `SystemLogKey`
- Three logs from the `L2_TO_L1_MESSENGER` with keys:
- `L2_TO_L1_LOGS_TREE_ROOT_KEY`
- `TOTAL_L2_TO_L1_PUBDATA_KEY`
- `STATE_DIFF_HASH_KEY`
- Two logs from `L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR` with keys:
  - `PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY`
  - `PREV_BATCH_HASH_KEY`
- Two or three logs from `L2_BOOTLOADER_ADDRESS` with keys:
  - `CHAINED_PRIORITY_TXN_HASH_KEY`
  - `NUMBER_OF_LAYER_1_TXS_KEY`
  - `EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY`
- None logs from other addresses (may be changed in the future).

#### Bridges

Bridges are completely separate contracts from the Diamond. They are a wrapper for L1 <-> L2 communication on contracts
on both L1 and L2. Upon locking assets on one layer, a request is sent to mint these bridged assets on the other layer.
Upon burning assets on one layer, a request is sent to unlock them on the other.

Unlike the native Ether bridging, all other assets can be bridged by the custom implementation relying on the trustless
L1 <-> L2 communication.

##### L1ERC20Bridge

The legacy implementation of the ERC20 token bridge. Works only with regular ERC20 tokens, i.e. not with
fee-on-transfer tokens or other custom logic for handling user balances. Only works for Era.

- `deposit` - lock funds inside the contract and send a request to mint bridged assets on L2.
- `claimFailedDeposit` - unlock funds if the deposit was initiated but then failed on L2.
- `finalizeWithdrawal` - unlock funds for the valid withdrawal request from L2.

##### L1SharedBridge

The "standard" implementation of the ERC20 and WETH token bridge. Works only with regular ERC20 tokens, i.e. not with
fee-on-transfer tokens or other custom logic for handling user balances.

- `deposit` - lock funds inside the contract and send a request to mint bridged assets on L2.
- `claimFailedDeposit` - unlock funds if the deposit was initiated but then failed on L2.
- `finalizeWithdrawal` - unlock funds for the valid withdrawal request from L2.

The bridge also handles WETH token deposits between the two domains. It is designed to streamline and
enhance the user experience for bridging WETH tokens by minimizing the number of transactions required and reducing
liquidity fragmentation thus improving efficiency and user experience.

This contract accepts WETH deposits on L1, unwraps them to ETH, and sends the ETH to the L2 WETH bridge contract, where
it is wrapped back into WETH and delivered to the L2 recipient.

Thus, the deposit is made in one transaction, and the user receives L2 WETH that can be unwrapped to ETH.

##### L2SharedBridge

The L2 counterpart of the L1 Shared bridge.

- `withdraw` - initiate a withdrawal by burning funds on the contract and sending a corresponding message to L1.
- `finalizeDeposit` - finalize the deposit and mint funds on L2.

For WETH withdrawals, the contract receives ETH from the L2 WETH bridge contract, wraps it into WETH, and sends the WETH to
the L1 recipient.

#### ValidatorTimelock

An intermediate smart contract between the validator EOA account and the zkSync smart contract. Its primary purpose is
to provide a trustless means of delaying batch execution without modifying the main zkSync contract. zkSync actively
monitors the chain activity and reacts to any suspicious activity by freezing the chain. This allows time for
investigation and mitigation before resuming normal operations.

It is a temporary solution to prevent any significant impact of the validator hot key leakage, while the network is in
the Alpha stage.

This contract consists of four main functions `commitBatches`, `proveBatches`, `executeBatches`, and `revertBatches`,
that can be called only by the validator.

When the validator calls `commitBatches`, the same calldata will be propagated to the zkSync contract (`DiamondProxy`
through `call` where it invokes the `ExecutorFacet` through `delegatecall`), and also a timestamp is assigned to these
batches to track the time these batches are committed by the validator to enforce a delay between committing and
execution of batches. Then, the validator can prove the already committed batches regardless of the mentioned timestamp,
and again the same calldata (related to the `proveBatches` function) will be propagated to the zkSync contract. After,
the `delay` is elapsed, the validator is allowed to call `executeBatches` to propagate the same calldata to zkSync
contract.

### L2 specifics

#### Deployment

The L2 deployment process is different from Ethereum.

In L1, the deployment always goes through two opcodes `create` and `create2`, each of which provides its address
derivation. The parameter of these opcodes is the so-called "init bytecode" - a bytecode that returns the bytecode to be
deployed. This works well in L1 but is suboptimal for L2.

In the case of L2, there are also two ways to deploy contracts - `create` and `create2`. However, the expected input
parameters for `create` and `create2` are different. It accepts the hash of the bytecode, rather than the full bytecode.
Therefore, users pay less for contract creation and don't need to send the full contract code by the network upon
deploys.

A good question could be, _how does the validator know the preimage of the bytecode hashes to execute the code?_ Here
comes the concept of factory dependencies! Factory dependencies are a list of bytecode hashes whose preimages were shown
on L1 (data is always available). Such bytecode hashes can be deployed, others - no. Note that they can be added to the
system by either L2 transaction or L1 -> L2 communication, where you can specify the full bytecode and the system will
mark it as known and allow you to deploy it.

Besides that, due to the bytecode differences for L1 and L2 contracts, address derivation is different. This applies to
both `create` and `create2` and means that contracts deployed on the L1 cannot have a collision with contracts deployed
on the L2. Please note that EOA address derivation is the same as on Ethereum.

Thus:

- L2 contracts are deployed by bytecode hash, not by full bytecode
- Factory dependencies - list of bytecode hashes that can be deployed on L2
- Address derivation for `create`/`create2` on L1 and L2 is different
