## Introduction & prerequisites

This document assumes that the reader has general knowledge of how ZKsync Era works and how our ecosystem used to be like at the moment of shared bridge in general. 

For more info, one can reach out to the following documentation:

[https://github.com/code-423n4/2024-03-zksync/tree/main/docs/Smart contract Section](https://github.com/code-423n4/2024-03-zksync/tree/main/docs/Smart%20contract%20Section) 

Especially helpful are articles about the l1 ecosystem contracts: [https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart contract Section/L1 ecosystem contracts.md](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart%20contract%20Section/L1%20ecosystem%20contracts.md) as well as how we handle priority transactions: [https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart contract Section/Handling L1→L2 ops on zkSync.md](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart%20contract%20Section/Handling%20L1%E2%86%92L2%20ops%20on%20zkSync.md).

However, reading all of the documents is highly encouraged.

While the audit is built on top of the previous ones which had the following documentation: https://github.com/matter-labs/era-contracts/tree/sync-layer-stable/docs (CAB and gateway docs correspondingly), this document will structurize all the information about the gateway/CAB changes as well as provide the structure of contracts in general, so it should be relatively friendly even for the first time reader. We will also provide comparisons to the previous audit’s code to emphasize on what has changed since the previous review.


## Changes from the shared bridge design

This section contains some of the important changes that happened since the shared bridge release in June. This section may not be fully complete and additional information will be provided in the sections that cover specific topics. 

### Bridgehub now has chainId → address mapping

Before, Bridgehub contained a mapping from `chainId => stateTransitionManager`. The further resolution of the mapping should happen at the CTM level. 
For more intuitive management of the chains, a new mapping `chainId => hyperchainAddress` was added. This is considered more intuitive since “bridgehub is the owner of all the chains” mentality is more applicable with this new design.

The upside of the previous approach was potentially easier migration within the same CTM. However, in the end it was decided that the new approach is better.  

#### Migration

This new mapping will have to be filled up after upgrading the bridgehub. It is done by repeatedly calling the `setLegacyChainAddress` for each of the deployed chains. It is assumed that their number is relatively low. Also, this function is permissionless and so can be called by anyone after the upgrade is complete. This function will call the old CTM and ask for the implementation of the chainId. 

Until the migration is done, all transactions with the old chains will not be working, but it is a short period of time. 

### baseTokenAssetId is used as a base token for the chains

In order to facilitate future support of any type of asset a base token, including assets minted on L2, now chains will provide the `assetId` for their base token instead. The derivation & definition of the `assetId` is expanded in the CAB section of the doc.

#### Migration & compatibility

Today, there are some mappings of sort `chainId => baseTokenAddress`. These will no longer be filled for new chains. Instead, only assetId will be provided in a new `chainId => baseTokenAssetId` mapping. 

To initialize the new `baseTokenAssetId` mapping the following function should be called for each chain: `setLegacyBaseTokenAssetId`. It will encode each token as the assetId of an L1 token of the Native Token Vault. This method is permissionless.

For the old tooling that may rely on getters of sort `getBaseTokenAddress(chainId)` working, we provide a getter method, but its exact behavior depends on the asset handler of the `setLegacyBaseTokenAssetId`, i.e. it is even possible that the method will revert for an incompatible assetId.   

### Shared bridge is deployed everywhere at the same address

Before, for each new chain, we would have to initialize the mapping in the L1SharedBridge to remember the address of the l2 shared bridge on the corresponding L2 chain.

Now, however, the L2AssetRouter is set on the same constant on all chains. 

### StateTransitionManager was renamed to ChainTypeManager

CTM was renamed to CTM (ChainTypeManager). This was done to use more intuitive naming as the chains of the same “type” share the same CTM.  

### Hyperchains were renamed to ZK chains

For consistency with the naming inside the blogs, the term “hyperchain” has been changed to “ZK chain”.

## Changes in the structure of contracts

While fully reusing contracts on both L1 and L2 is not always possible, it was done to a very high degree as now all bridging-related contracts are located inside the `l1-contracts` folder.

## Priority tree

[Migrating Priority Queue to Merkle Tree](https://www.notion.so/Migrating-Priority-Queue-to-Merkle-Tree-e6e563867067470aa66d010f0294ea3e?pvs=21)

In the currently deployed system, L1→L2 transactions are added as a part of a priority queue, i.e. all of them are stored 1-by-1 on L1 in a queue-like structure.

Note, that the complexity of chain migrations in either of the directions depends on the size of the priority queue. However, the number of unprocessed priority transactions is potentially out of hands of both the operator of the chain and the chain admin as the users are free to add priority transactions in case there is no `transactionFilterer` contract, which is the case for any permissionless system, such as zkSync Era.

If someone tries to DDoS the priority queue, the chain can be blocked from migration. Even worse, for GW→L1 migrations, inability to finalize the migration can lead to a complete loss of chain.

To combat all the issues above, it was decided to move from the priority queue to a priority tree, i.e. only the incremental merkle tree is stored on L1, while at the end of the batch the operator will provide a merkle proof for the inclusion of the priority transactions that were present in the batch. It does not impact the bootloader, but rather only how the L1 checks that the priority transactions did indeed belong to the chain

# Custom DA layers

Custom DA layer support was added. 

### Major changes

In order to achieve CAB, we separated the liquidity managing logic from the Shared Bridge to `Asset Handlers`. The basic cases will be handled by `Native Token Vaults`, which are handling all of the standard `ERC20 tokens`, as well as `ETH`.

## L1<>L2 token bridging considerations

- We have the L2SharedBridgeLegacy on chains that are live before the upgrade. This contract will keep on working, and where it exists it will also be used to:
    - deploy bridged tokens. This is so that the l2TokenAddress keeps working on the L1, and so that we have a predictable address for these tokens.
    - send messages to L1. On the L1 finalizeWithdrawal does not specify the l2Sender. Legacy withdrawals will use the legacy bridge as their sender, while new withdrawals would use the L2_ASSET_ROUTER_ADDR. In the future we will add the sender to the L1 finalizeWithdrawal interface. Until the current method is depracated we use the l2SharedBridgeAddress even for new withdrawals on legacy chains. 
    This also means that on the L1 side we set the L2AR address when calling the function via the legacy interface even if it is a baseToken withdrawal. Later when we learn if it baseToken or not, we override the value.
- We have the finalizeWithdrawal function on L1 AR, which uses the finalizeDeposit in the background.
- L1→L2 deposits need to use the legacy encoding for SDK compatiblity.
    - This means the legacy finalizeDeposit with tokenAddress which calls the new finalizeDeposit with assetId.
    - On the other hand, new assets will use the new finalizeDeposit directly
- The originChainId will be tracked for each assetId in the NTVs. This will be the chain where the token is originally native to. This is needed to accurately track chainBalance (especially for l2 native tokens bridged to other chains via L1), and to verify the assetId is indeed an NTV asset id (i.e. has the L2_NATIVE_TOKEN_VAULT_ADDR as deployment tracker).


# Invariants/tricky places to look out for

This section is for auditors of the codebase. It includes some of the important invariants that the system relies on and which if broken could have bad consequences.

- Assuming that the accepting CTM is correct & efficient, the L1→GW part of the L1→GW→L3 transaction never fails. It is assumed that the provided max amount for gas is always enough for any transaction that can realistically come from L1.
- GW → L1 migration never fails. If it is possible to get into a state where the migration is not possible to finish, then the chain is basically lost. There are some exceptions where for now it is the expected behavior. (check out the “Migration invariants  & protocol upgradability” section)
- The general consistency of chains when migration between different settlement layers is done. Including the feasibility of emergency upgrades, etc. I.e. whether the whole system is thought-through.
- Preimage attacks in the L3→L1 tree, we apply special prefixes to ensure that the tree structure is fixed, i.e. all logs are 88 bytes long (this is for backwards compatibility reasons). For batch leafs and chain id leafs we use special prefixes.
- Data availability guarantees. Whether rollup users can always restore all their storage slots, etc. An example of a potential tricky issue can be found in “Security notes for Gateway-based rollups”

## Appendix: Upgrade strategy

The text about applies to [the following branch](https://github.com/matter-labs/era-contracts/pull/964)https://github.com/matter-labs/era-contracts/pull/964. So if you are auditing a different commit, there is little point in reading it.

