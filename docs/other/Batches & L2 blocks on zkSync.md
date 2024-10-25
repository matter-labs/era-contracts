FIXME: read and fix any issues


# Batches & L2 blocks on zkSync

## Glossary

- Batch - a set of transactions that the bootloader processes (`commitBatches`, `proveBatches`, and `executeBatches` work with it). A batch consists of multiple transactions.
- L2 blocks - non-intersecting sub-sets of consecutively executed transactions in a batch. This is the kind of block you see in the API. This is the one that is used for `block.number`/`block.timestamp`/etc. Note that it wasn't this way before the virtual blocks [migration](#migration--virtual-blocks-logic).
- Virtual block — a block, the data of which was being returned in the contract execution environment during the migration. They are called “virtual”, since they have no trace in our API, i.e. it is not possible to query information about them in any way. This is now mostly irrelevant, since the migration is alredy finished.

## Motivation

Before the recent upgrade, `block.number`, `block.timestamp`, as well as `blockhash` in Solidity, returned information about *batches*, i.e. large blocks that are proven on L1 and which consist of many smaller L2 blocks. At the same time, API returns `block.number` and `block.timestamp` as for L2 blocks.

L2 blocks were created for fast soft confirmation in wallets and block explorer. For example, MetaMask shows transactions as confirmed only after the block in which transaction execution was mined. So if the user needs to wait for the batch confirmation it would take at least a few minutes (for soft confirmation) and hours for full confirmation which is very bad UX. But API could return soft confirmation much earlier through L2 blocks.

There was a huge outcry in the community for us to return the information for L2 blocks in `block.number`, `block.timestamp`, as well as `blockhash`, because of discrepancy of runtime execution and returned data by API.

However, there were over 15mln L2 blocks, while less than 200k batches, meaning that if we simply “switched” from returning L1 batches’ info to L2 block’s info, some contracts (especially those that use `block.number` for measuring time intervals instead of `block.timestamp`) would break. For that, we decided to have an accelerated migration process, i.e. the `block.number` will grow faster and faster, until it becomes roughly 8x times the L2 block production speed, allowing it to gradually reach the L2 block number, after which the information on the L2 `block.number` will be returned. The blocks the info of which will be returned during this process are called “virtual blocks”. Their information will never be available in any of our APIs, which should not be a major breaking change, since our API already mostly works with L2 blocks, while L1 batches’s information is returned in the runtime.

## Adapting for Solidity

In order to get the returned value for `block.number`, `block.timestamp`, `blockhash` our compiler used the following functions:

- `getBlockNumber`
- `getBlockTimestamp`
- `getBlockHashEVM`

During the migration process, these returned the values of the virtual blocks. Currently, since the migration is complete, they return values for L2 blocks.

## Migration status

At the time of this writing, the migration has been complete on both testnet and mainnet, i.e. there we already have only the L2 block information returned. Mainnet migration ended in early November 2023.

# Blocks’ processing and consistency checks

Our `SystemContext` contract allows to get information about batches and L2 blocks. Some of the information is hard to calculate onchain. For instace, time. The timing information (for both batches and L2 blocks) are provided by the operator. In order to check that the operator provided some realistic values, certain checks are done on L1. Generally though, we try to check as much as we can on L2.

## Initializing L1 batch

At the start of the batch, the operator [provides](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/bootloader/bootloader.yul#L3867) the timestamp of the batch, its number and the hash of the previous batch.. The root hash of the Merkle tree serves as the root hash of the batch.

The SystemContext can immediately check whether the provided number is the correct batch number. It also immediately sends the previous batch hash to L1, where it will be checked during the commit operation. Also, some general consistency checks are performed. This logic can be found [here](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/contracts/SystemContext.sol#L466).

## L2 blocks processing and consistency checks

### `setL2Block`

Before each transaction, we call `setL2Block` [method](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/bootloader/bootloader.yul#L2825). There we will provide some data about the L2 block that the transaction belongs to:

- `_l2BlockNumber` The number of the new L2 block.
- `_l2BlockTimestamp` The timestamp of the new L2 block.
- `_expectedPrevL2BlockHash` The expected hash of the previous L2 block.
- `_isFirstInBatch` Whether this method is called for the first time in the batch.
- `_maxVirtualBlocksToCreate` The maximum number of virtual block to create with this L2 block.

If two transactions belong to the same L2 block, only the first one may have non-zero `_maxVirtualBlocksToCreate`. The rest of the data must be same.

The `setL2Block` [performs](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/contracts/SystemContext.sol#L341) a lot of similar consistency checks to the ones for the L1 batch.

### L2 blockhash calculation and storage

Unlike L1 batch’s hash, the L2 blocks’ hashes can be checked on L2.

The hash of an L2 block is `keccak256(abi.encode(_blockNumber, _blockTimestamp, _prevL2BlockHash, _blockTxsRollingHash))`. Where `_blockTxsRollingHash` is defined in the following way:

`_blockTxsRollingHash = 0` for an empty block.

`_blockTxsRollingHash = keccak(0, tx1_hash)` for a block with one tx.

`_blockTxsRollingHash = keccak(keccak(0, tx1_hash), tx2_hash)` for a block with two txs, etc.

To add a transaction hash to the current miniblock we use the `appendTransactionToCurrentL2Block` [function](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/contracts/SystemContext.sol#L402).

Since zkSync is a state-diff based rollup, there is no way to deduce the hashes of the L2 blocks based on the transactions’ in the batch (because there is no access to the transaction’s hashes). At the same time, in order to execute `blockhash` method, the VM requires the knowledge of some of the previous L2 block hashes. In order to save up on pubdata (by making sure that the same storage slots are reused, i.e. we only have repeated writes) we [store](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/contracts/SystemContext.sol#L70) only the last 257 block hashes. You can read more on what are the repeated writes and how the pubdata is processed [here](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart%20contract%20Section/Handling%20L1%E2%86%92L2%20ops%20on%20zkSync.md).

We store only the last 257 blocks, since the EVM requires only 256 previous ones and we use 257 as a safe margin.

### Legacy blockhash

When initializing L2 blocks that do not have their hashes stored on L2 (basically these are blocks before the migration upgrade), we use the following formula for their hash:

`keccak256(abi.encodePacked(uint32(_blockNumber)))`

### Timing invariants

While the timestamp of each L2 block is provided by the operator, there are some timing invariants that the system preserves:

- For each L2 block its timestamp should be > the timestamp of the previous L2 block
- For each L2 block its timestamp should be ≥ timestamp of the batch it belongs to
- Each batch must start with a new L2 block (i.e. an L2 block can not span across batches).
- The timestamp of a batch must be ≥ the timestamp of the latest L2 block which belonged to the previous batch.
- The timestamp of the last miniblock in batch can not go too far into the future. This is enforced by publishing an L2→L1 log, with the timestamp which is then checked on L1.

## Fictive L2 block & finalizing the batch

At the end of the batch, the bootloader calls the `setL2Block` [one more time](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/bootloader/bootloader.yul#L4047) to allow the operator to create a new empty block. This is done purely for some of the technical reasons inside the node, where each batch ends with an empty L2 block.

We do not enforce that the last block is empty explicitly as it complicates the development process and testing, but in practice, it is, and either way, it should be secure.

Also, at the end of the batch we send the timestamps of the batch as well as the timestamp of the last miniblock in order to check on L1 that both of these are realistic. Checking any other L2 block’s timestamp is not required since all of them are enforced to be between those two.

## Migration & virtual blocks’ logic

As already explained above, for a smoother upgrade for the ecosystem, there was a migration performed during which instead of returning either batch information or L2 block information, we returned the virtual block information until they had caught up with the L2 block’s number.

### Production of the virtual blocks

- In each batch, there should be at least one virtual block created.
- Whenever a new L2 block is created, the operator can select how many virtual blocks it wants to create. This can be any number, however, if the number of the virtual block exceeds the L2 block number, the migration is considered complete and we switch to the mode where the L2 block information will be returned.

## Additional note on blockhashes

Note, that if we used some complex formula for virtual blocks’ hashes (like we do for L2 blocks), we would have to put all of these into storage for the data availability. Even if we used the same storage trick that we used for the L2 blocks, where we store only the last 257’s block’s hashes under the current load/migration plans it would be expected that we have roughly ~250 virtual blocks per batch, practically meaning that we will publish all of these anyway. This would be too expensive. That is why we have to use a simple formula of `keccak(uint256(number))` for now. Note, that they do not collide with the legacy miniblock hash, since legacy miniblock hashes are calculated as `keccak(uint32(number))`.

Also, we need to keep the consistency of previous blockhashes, i.e. if `blockhash(X)` returns a non-zero value, it should be consistent among the future blocks. For instance, let’s say that the hash of batch `1000` is `1`, i.e. `blockhash(1000) = 1`. Then, when we migrate to virtual blocks, we need to ensure that `blockhash(1000)` will return either 0 (if and only if the block is more than 256 blocks old) or `1`. Because of that for `blockhash` we will have the following complex [logic](https://github.com/code-423n4/2024-03-zksync/blob/e8527cab32c9fe2e1be70e414d7c73a20d357550/code/system-contracts/contracts/SystemContext.sol#L132):

- For blocks that were created before the virtual block upgrade, use the batch hashes
- For blocks that were created during the virtual block upgrade, use `keccak(uint256(number))`.
- For blocks that were created after the virtual blocks have caught up with the L2 blocks, use L2 block hashes.
