# Gateway audit documentation

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

Before, Bridgehub contained a mapping from `chainId => stateTransitionManager`. The further resolution of the mapping should happen at the STM level. 
For more intuitive management of the chains, a new mapping `chainId => hyperchainAddress` was added. This is considered more intuitive since “bridgehub is the owner of all the chains” mentality is more applicable with this new design.

The upside of the previous approach was potentially easier migration within the same STM. However, in the end it was decided that the new approach is better.  

#### Migration

This new mapping will have to be filled up after upgrading the bridgehub. It is done by repeatedly calling the `setLegacyChainAddress` for each of the deployed chains. It is assumed that their number is relatively low. Also, this function is permissionless and so can be called by anyone after the upgrade is complete. This function will call the old STM and ask for the implementation of the chainId. 

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

STM was renamed to CTM (ChainTypeManager). This was done to use more intuitive naming as the chains of the same “type” share the same CTM.  

### Hyperchains were renamed to ZK chains

For consistency with the naming inside the blogs, the term “hyperchain” has been changed to “ZK chain”.

## Custom asset bridging

Custom asset bridging is a new bridging model that allows to:

1. Minimize the effort needed by custom tokens to be able to become part of the elastic chain ecosystem. Before, each custom token would have to build its own bridge, but now just custom asset deployment trackers / asset handler is needed.
2. Unify the interfaces between L1 and L2 contracts, paving the way for easy cross chain bridging. It will especially become valuable once interop is there.

#### New concepts

- AssetDeploymentTracker => contract that manages the deployment of asset handlers across chains. It is the contract that registers these asset handlers in the AssetRouters.
- AssetHandler => contract that manages liquidity (burns/mints, locks/unlocks) for specific token (or a set of them)
- assetId => identifier to track bridged assets across chains linked to specific asset handler.

### Normal flow

Assets Handlers are registered in the Routers based on their assetId. The assetId is used to identify the asset when bridging, it is sent with the cross-chain transaction data and Router routes the data to the appropriate Handler. If the asset handler is not registered in the L2 Router, then the L1->L2 bridging transaction will fail on the L2 (expect for NTV assets, see below).

`assetId = keccak256(chainId, asset deployment tracker = msg.sender, additionalData)`

Asset registration is handled by the AssetDeploymentTracker. It is expected that this contract is deployed on the L1. Registartion of the assetHandler on a ZKChain can be permissionless depending on the Asset (e.g. the AssetHandler can be deployed on the chain at a predefined address, this can message the L1 ADT, which can then register the asset in the Router). Registering the L1 Handler in the L1 Router can be done via a direct function call from the L1 Deployment Tracker. Registration in the L2 Router is done indirectly via the L1 Router.

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/610c7ce5-a63a-4662-b2f9-ce4a599a2d35/image.png)

The Native Token Vault is a special case of the Asset Handler, as we want it to support automatic bridging. This means it should be possible to bridge a L1 token to an L2 without deploying the Token contract beforehand and without registering it in the L2 Router. For NTV assets, L1->L2 transactions where the AssetHandler is not registered will not fail, but the message will be automatically be forwarded to the L2NTV. Here the contract checks that the asset is indeed deployed by the L1NTV, by checking that the assetId contains the correct ADT address (note, for NTV assets the ADT is the NTV and the used address is the L2NTV address). If the assetId is correct, the token contract is deployed.

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/a816cae3-1f00-44a8-9641-ff05745705ea/image.png)

## Changes in the structure of contracts

While fully reusing contracts on both L1 and L2 is not always possible, it was done to a very high degree as now all bridging-related contracts are located inside the `l1-contracts` folder.

### AssetRouters (L1/L2)

The main job of the asset router is to be the central point of coordination for bridging. All crosschain token bridging is done between asset routers only and once the message reaches asset router, it then routes it to the corresponding asset handler.

In order to make this easier, all L2 chains have the asset router located on the same address on every chain. It is `0x10003` and it is pre-deployed contract. More on how it is deployed can be seen in the “Built-in contracts and their initialization” section.

The endgame is to have L1 asset router have the same functionality as the L2 one. It is not yet the case, but some progress has been made: L2AssetRouter can now bridge L2-native assets to L1, from which it could be bridged to other chains in the ecosystem.

The specifics of the L2AssetRouter is the need to interact with the previously deployed L2SharedBridgeLegacy if it was already present. It has less “rights” than the L1AssetRouter: at the moment it is assumed that all asset deployment trackers are from L1, the only way to register an asset handler on L2 is to make an L1→L2 transaction.

> Note, that today registering new asset deployment trackers will be permissioned, but the plan is to make it permissionless in the future
> 

The specifics of the L1AssetRouter come from the need to be backwards compatible with the old L1SharedBridge. Yes, it will not share the same storage, but it will inherit the need to be backwards compatible with the current SDK. Also, L1AssetRouter needs to facilitate L1-only operations, such as recoverrying from failed deposits.

Also, L1AssetRouter is the only asset router that can participate in initiation of cross chain transactions via bridgehub. This will change in the future with the support of interop.

### L1Nullifier

While the endgoal is to unify L1 and L2 asset routers, in reality, it may not be that easy: while L2 asset routers get called by L1→L2 transactions, L1 ones don't and require manual finalization of transactions, which involves proof verification, etc. To move this logic outside of the L1AssetRouter, it was moved into a separate L1Nullifier contract. 

*This is the contract the current L1SharedBridge will be upgraded to, so it should have the backwards compatible storage.*

### NativeTokenVault (L1/L2)

NativeTokenVault is an asset handler that is available on all chains and is also predeployed. It is provides the functionality of the most basic bridging: locking funds on one chain and minting the bridged equivalent on the other one. On L2 chains NTV is predeployed at the `0x10004` address.

The two are almost identical in functionality, the main differences come from the differences of the deployment functionality in L1 and L2 envs, where the former uses standard CREATE2 and the latter uses low level calls to `CONTRACT_DEPLOYER`system contract. 

Also, the L1NTV has the following specifics:

- It operates the `chainBalance` mapping, ensuring that the chains do not go beyond their balances.
- It allows recovering from failed L1→L2 transfers.
- It needs to both be able to retrieve funds from the former L1SharedBridge (now this contract has L1Nullifier in its place), but also needs to support the old SDK that gives out allowance to the “l1 shared bridge” value returned from the API, i.e. in our case this is will the L1AssetRouter.

### L2SharedBridgeLegacy

L2AssetRouter has to be pre-deployed onto a specific address. The old L2SharedBridge will be upgraded to L2SharedBridgeLegacy contract. The main purpose of this contract is to ensure compatibility with the incoming deposits and re-route them to the shared bridge.

This contract is never deployed for new chains.

### Summary

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/8090047f-cb2d-4d8d-8677-91559e00e8e8/image.png)

# Gateway

Gateway is a proof aggregation layer, created to solve the following problems:

- Fast interop (interchain communication) would require quick proof generation and verification. The latter can be very expensive on L1. Gateway provides an L1-like interface for chains, while giving a stable price for compute.
- Generally proof aggregation can reduce costs for users, if there are multiple chains settling on top of the same layer. It can reduce the costs of running a Validium even further.

In this release, Gateway is basically a fork of Era, that will be deployed within the same CTM as other ZK Chains. This allows us to reuse most of the existing code for Gateway. 

> In some places in code you can meet words such as “settlement layer” or the abbreviation “sl”. “Settlement layer” is a general term that describes a chain that other chains can settle to. Right now, the list of settlement layers is whitelisted and only Gateway will be allowed to be a settlement layer.
> 

## High level gateway architecture

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/e990dbe7-1f05-41c2-b2a8-93781f7b6c25/image.png)

## Built-in contracts and their initialization

Each single ZK Chain has a set of the following contracts that, while not belong to kernel space, are built-in and provide important functionality:

- Bridgehub (the source code is identical to the L1 one). The role of bridgehub is to facilitate cross chain transactions. It contains a mapping from chainId to the address of the diamond proxy of the chain. It is really used only on the L1 and Gateway, i.e. layers that can serve as a settlement layer.
- L2AssetRouter. The new iteration of the SharedBridge.
- L2NativeTokenVault. The Native token vault on L2.
- MessageRoot (the source code is identical to the L1 one). Similar to bridgehub, it facilitates cross-chain communication, but is practically unused on all chains except for L1/GW.

To reuse as much code as possible from L1 and also to allow easier initialization, most of these contracts are not initialized as just part of the genesis storage root. Instead, the data for their initialization is part of the original diamondcut for the chain. In the same initial upgrade transaction when the chainId is initialized, these contracts are force-deployed and initialized also. An important part in it plays the new `L2Genesis` contract, which is pre-deployed in a user-space contract, but it is delegated to the `ComplexUpgrader` system contract (already exists as part of genesis and existed before this upgrade).

The following diagram shows how the chain genesis works:

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/2144800e-f834-4169-8ebb-88504841900a/image.png)

## Deeper dive into MessageRoot contract and how L3→L1 communication works

Before, when were just settling on L1, a chain’s message root was just the merkle tree of L2→L1 logs that were sent within this batch. However, this new model will have to be amended to be able to perform messages to  L1 coming from an L3 that settles on top of Gateway.

The description of how L3→L1 messages are aggregated in the MessageRoots and proved on L1 can be read here:

[Nested L3→L1 messages tree design for Gateway](https://www.notion.so/Nested-L3-L1-messages-tree-design-for-Gateway-59cd01c3b73449ab9136eea2d73010d3?pvs=21)

## L1→L3 messaging

As a recap, here is how messaging works for chains that settle on L1:

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/37ccab1e-24f5-4974-9ff9-60231e324345/image.png)

- The user calls the bridgehub, which routes the message to the chain.
- The operator eventually sees the transaction via an event on L1 and it will process it on L2.

With gateway, the situation will be a bit more complex:

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/d246c388-912e-409e-ad23-95e2a7afa1be/image.png)

Since now, the contracts responsible for batch processing were moved to Gateway, now all the priority transactions have to be relayed to that chain so that the validation could work.

- (Steps 1-3) The user calls Bridgehub. The base token needs to be deposited via L1AssetRouter (usually the NTV will be used).
- (Step 4-5). The Bridgehub calls the chain where the transaction is targeted to. The chain sees that its settlement layer is another chain and so it calls it and asks to relay this transaction to gateway
- (Steps 6-7). priority transaction from `SETTLEMENT_LAYER_RELAY_SENDER` to the Bridgehub is added to the Gateway chain’s priority queue. Once the Gateway operator sees the transaction from L1, it processed it. The transaction itself will eventually call the DiamondProxy of the initial called chain.
- (Step 8) At some point, the operator of the chain will see that the priority transaction has been included to the gateway and it will process it on the L3.
- Step 9 from the picture above is optional and in case the callee of the L1→L3 transaction is the L2AssetRouter (i.e. the purpose of the transaction was bridging funds), then the L2AssetRouter will call asset handler of the asset (in case of standard bridged tokens, it will be the NativeTokenVault). It will be responsible for minting the corresponding number of tokens to the user.

So under the hood there are 2 cross chain transactions happening:

1. One from L1 to GW
2. The second one from GW to the L3.

From another point with bridging we have methods that allow users to recover funds in case of a failed L1→L2 transaction. E.g. if the user tried to bridge USDC to a Zk Chain, but did not provide enough L2 gas, it can still recover the funds.

This functionality works by letting user prove that the bridging transaction failed and then the funds are released back to the original sender on L1. With the approach above where there are multiple cross chain transactions involved, it could become 2x hard to maintain: now both of these could fail.

To simplify things, for now, we provide the L1→GW with a large amount of gas (72kk, i.e. the maximal amount allowed to be passed on L2). We believe that it is not possible to create a relayed transaction that would fail, assuming that a non malicious recipient CTM is used on L2.

> Note, that the above means that we currently rely on the following two facts:

- The recipient CTM is honest and efficient.
- Creating a large transaction on L1 that would cause the L1→GW part to fail is not possible due to high L1 gas costs that would be required to create such a tx.

Both of the assumptions above will be removed in subsequent releases, but for now this is how things are.
> 

# Chain migration

## Ecosystem Setup

Chain migration reuses lots of logic from standard token migration. The easiest way to imagine is that ZKChains are NFTs that are being migrated from one chain to another. Just like in case of the NFT contract, an CTM is assumed to have an `assetId := keccak256(abi.encode(L1_CHAIN_ID, address(ctmDeployer), bytes32(uint256(uint160(_ctmAddress)))))`. I.e. these are all assets with ADT = ctmDeployer contract on L1.

CTMDeployer is a very lightweight contract used to facilitate chain migration. Its main purpose is to server as formal asset deployment tracker for CTMs. It serves two purposes:

- Assign bridgehub as the asset handler for the “asset” of the CTM on the supported settlement layer.

Currently, it can only be done by the owner of the  CTMDeployer, but in the future, this method can become either permissionless or callable by the CTM owner.
- Tell bridgehub which address on the L2 should serve as the L2 representation of the STM on L1. Currently, it can only be done by the owner of the  CTMDeployer, but in the future, this method can become callable by the CTM owner.

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/ec509988-b87c-4924-bd6c-316fd6d43d34/image.png)

## The process of migration L1→GW

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/bb6bae26-1f19-4169-86ae-987e882a7091/image.png)

## Chain migration GW → L1

Chain migration from from L1 to GW works similar to how NFT bridging from L1 to another chain would work. Migrating back will use the same mechanism as for withdrawals. 

Note, that for L2→L1 withdrawals via bridges we never provide a recovery mechanism. The same is the case with GW → L1 messaging, i.e. it is assumed that such migrations are always executable on L1. 

You can read more about how the safety is ensured in the “Migration invariants  & protocol upgradability” section.

![image.png](https://prod-files-secure.s3.us-west-2.amazonaws.com/703ee435-9e35-441a-b595-a8f42972ac1a/494d0386-8f30-4b12-a460-2831cfdcb35b/image.png)

## Chain migration GW_1 → GW_2

In this release we plan to only support a single whitelisted settlement layer, but if in the future more will be supported, as of now the plan is to migrate the chain firstly to L1 and then to GW.

## Chain migration invariants  & protocol upgradability

Note, that once a chain migrates to a new settlement layer, there are two deployments of contracts for the same ZKChain. What’s more, the L1 part will always be used. 

There is a need to ensure that the chains work smoothly during migration and there are not many issues during the protocol upgrade.

[Gateway protocol versioning and upgradability](https://www.notion.so/Gateway-protocol-versioning-and-upgradability-3865f7a92f1b49ecb70463633353d49e?pvs=21)

## Priority tree

[Migrating Priority Queue to Merkle Tree](https://www.notion.so/Migrating-Priority-Queue-to-Merkle-Tree-e6e563867067470aa66d010f0294ea3e?pvs=21)

In the currently deployed system, L1→L2 transactions are added as a part of a priority queue, i.e. all of them are stored 1-by-1 on L1 in a queue-like structure.

Note, that the complexity of chain migrations in either of the directions depends on the size of the priority queue. However, the number of unprocessed priority transactions is potentially out of hands of both the operator of the chain and the chain admin as the users are free to add priority transactions in case there is no `transactionFilterer` contract, which is the case for any permissionless system, such as zkSync Era.

If someone tries to DDoS the priority queue, the chain can be blocked from migration. Even worse, for GW→L1 migrations, inability to finalize the migration can lead to a complete loss of chain.

To combat all the issues above, it was decided to move from the priority queue to a priority tree, i.e. only the incremental merkle tree is stored on L1, while at the end of the batch the operator will provide a merkle proof for the inclusion of the priority transactions that were present in the batch. It does not impact the bootloader, but rather only how the L1 checks that the priority transactions did indeed belong to the chain

# Custom DA layers

[Custom DA support](https://www.notion.so/Custom-DA-support-716d8fc04b524a338f5badb7e611d384?pvs=21)

### Security notes for Gateway-based rollups

An important note is that when reading the state diffs from L1, the observer will read messages that come from the L2DAValidator. To be more precise, the contract used is `RelayedSLDAValidator` which reads the data and publishes it to L1 by calling the L1Messenger contract.

If anyone could call this contract, the observer from L1 could get wrong data for pubdata for this particular batch. To prevent this, it ensures that only the chain can call it.

# Governance and chain admin

## Ecosystem admins

Most of the ecosystem contracts (like Bridgehub) have two roles: *the owner* and *the admin*. The latter is responsible for more day-to-day tasks. I.e. the system should be generally okay-ish even if it behaves maliciously, i.e. no funds should be lost and the state should be recoverable by actions of the owner.

The intended deployed admin is the multisig of ML team. It is intended to be able to move quickly while providing sufficient security.

***Owner**,* on the other hand is a very powerful trusted role that is governed by the ZK token governance on L2. The complete design of the decentralized governance is out of scope of this document. However, owner is a critical role responsible for potentially dangerous unrecoverable operations, e.g. creating new protocol version.

## Chain admins

Also, each chain has its own admin. The structure of the chain admin can be decided by each chain and they have access to updating chain-specific parameters. There include:

- Upgrading the chain. Only the decentralized governance can whitelist *the content* of the upgrade, but the chain admin is the one that usually triggers an upgrade for the chain.
- Choosing the DA layer.
- Updating token price in ETH on the contract
- The full list can be observed by searching for `onlyAdmin` and `onlyAdminOrChainTypeManager` in the Admin.sol facet of the contract.

### `ChainAdmin.sol` contract

Some of the powers of the admin are dangerous not for the ecosystem, but for the chain itself. For example, if a rollup that claims to be permissionless wanted to stop the flow of L1→L2 transactions to zkSync Era, they could set up a transactionfilterer there. What’s even more dangerous is that the admin could quickly switch the chain to being a validium and publish unknown state. 

This is beyond our security model as Era’s users’ should never be in danger regardless of actions of the Era’s admin. In order to ensure that it is the case, the `ChainAdmin.sol` was created. It is the intended chain admin of the Era chain. In order to ensure that it is flexible enough for future other chains to use, it uses a modular architecture to ensure that other chains could fit it to their needs. By default, this contract is not even `Ownable`, and anyone can execute transactions out of the name of it. In order to add new features such as restricting calling dangerous methods and access control, *restrictions* should be added there.

Each restriction is a contract that implements the `IRestriction` interface. The following restrictions have been implemented so far:

- `AccessControlRestriction` that allows to specify which addresses can call which methods. In the case of Era, only the `DEFAULT_ADMIN_ROLE`will be able to call any methods. This default admin will be the ML multisig.

Other chains with non-ETH base token may need an account that would periodically call the L1 contract to update the ETH price there. They may create the `SET_TOKEN_MULTIPLIER_ROLE` role that is required to update the token price and give its rights to some hot private key.
- `PermanentRestriction` that ensures that:

a) This restriction could be lifted, i.e. the chain admin of the chain must forever have it. Even if the address of the `ChainAdmin` changes, it ensures that the new admin has this restriction turned on.
b) It specifies the calldata this which certain methods can be called. For instance, in case a chain wants to keep itself as the permanent rollup (e.g. this is the case for Era), it will ensure that the only DA validation method that can be used is rollup. The decentralized governance will be responsible for whitelisting the allowed calldata for certain functions.

The approach above does not only help in protecting Era, but also provides correct information for chains that are present in our ecosystem. For instance, if a chain claims to be a rollup, but allows changing the DA mode in any minute can not be considered secure for users. 

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
- 

# Invariants/tricky places to look out for

This section is for auditors of the codebase. It includes some of the important invariants that the system relies on and which if broken could have bad consequences.

- Assuming that the accepting STM is correct & efficient, the L1→GW part of the L1→GW→L3 transaction never fails. It is assumed that the provided max amount for gas is always enough for any transaction that can realistically come from L1.
- GW → L1 migration never fails. If it is possible to get into a state where the migration is not possible to finish, then the chain is basically lost. There are some exceptions where for now it is the expected behavior. (check out the “Migration invariants  & protocol upgradability” section)
- The general consistency of chains when migration between different settlement layers is done. Including the feasibility of emergency upgrades, etc. I.e. whether the whole system is thought-through.
- Preimage attacks in the L3→L1 tree, we apply special prefixes to ensure that the tree structure is fixed, i.e. all logs are 88 bytes long (this is for backwards compatibility reasons). For batch leafs and chain id leafs we use special prefixes.
- Data availability guarantees. Whether rollup users can always restore all their storage slots, etc. An example of a potential tricky issue can be found in “Security notes for Gateway-based rollups”

## Appendix: Upgrade strategy

The text about applies to [the following branch](https://github.com/matter-labs/era-contracts/pull/964)https://github.com/matter-labs/era-contracts/pull/964. So if you are auditing a different commit, there is little point in reading it.