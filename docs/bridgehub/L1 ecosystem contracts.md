FIXME: read and fix any issues


# Intro & Prerequisites

Ethereum's future is rollup-centric. This means breaking with the current paradigm of isolated EVM chains to infrastructure that is focused on an ecosystem of interconnected zkEVMs/zkVMs, (which we name ZK chain). This ecosystem will be grounded on Ethereum, requiring the appropriate L1 smart contracts. Here we outline our ZK Stack approach for these contracts, their interfaces, the needed changes to the existing architecture, as well as future features to be implemented.

If you want to know more about ZK chains, check this [blog post](https://blog.matter-labs.io/introduction-to-hyperchains-fdb33414ead7), or go through [our docs](https://era.zksync.io/docs/reference/concepts/hyperscaling.html).

This document will assume the reader already knows how rollups (esp. zkSync Era) work.

## Long term goal

We want to create a system where:

- ZK chains should be launched permissionlessly within the ecosystem.
- Hyperbridges should enable unified liquidity for assets across the ecosystem.
- Multi-chain smart contracts need to be easy to develop, which means easy access to traditional bridges, and other supporting architecture.


### Images:

![Contracts](./L1%20smart%20contracts/gateway-architecture.png)

> This document will not cover how ZK Gateway works, you can check it out in a separate doc (TODO: link).

# Table of content

# ST & CTM

## State transition (Diamond Proxy)

A high-level recap on how zk rollups work:

- Offchain operators collect transactions, process those and submit a tuple of `(old_state, new_state, proof)` to the L1 contract.
- The L1 contract then verifies that the proof is correct. If the proof is indeed correct, the `new_state` gets saved on the L1 contract. This `new_state` may not only include the storage root, but also a tree for L2→L1 messages (which allow to conduct withdrawals of funds from the L2), etc.

In other words, we can imagine the L1 part of each rollup as a basically a “state transition function verifier”, the only role of which is to check whether the state transition proposed by the operator of the chain is correct. 

To not commit to a specific type or option of this “state transition function”, we’ll call each rollup a   *State Transition* or ST. Note, that STs can be Validiums. An ST does not even have to be an L2 chain, it can also be an L3, etc.

But for now, whenever you see any mentioning of ST, Diamond Proxy, just imagine a single instance of an L2 chain. e.g. zkSync Era is an ST. 

> You can also see the term "ZK chain". It is the same as ST and these terms are interchangeable. 

## Chain Type Manager (CTM)

> If someone is already familiar with the [previous version](https://github.com/code-423n4/2024-03-zksync) of zkSync architecture, this contract was previously known as "State Transition Manager (CTM)".

Currently bridging between different zk rollups requires the funds to pass through L1. This is slow & expensive.

The vision of seamless internet of value requires transfers of value to be *both* seamless and trustless. This means that for instance different STs need to share the same L1 liquidity, i.e. a transfer of funds should never touch L1 in the process. However, it requires some sort of trust between two chains. If a malicious (or broken) rollup becomes a part of the shared liquidity pool it can steal all the funds. 

However, can two instances of the same zk rollup trust each other? The answer is yes, because no new additions of rollups introduce new trust assumptions. Assuming there are no bugs in circuits, the system will work as intended.

How can two rollups know that they are two different instances of the same system? We can create a factory of such contracts (and so we would know that each new rollup created by this instance is correct one). But just creating correct contracts is not enough. Ethereum changes, new bugs may be found in the original system & so an instance that does not keep itself up-to-date with the upgrades may exploit some bug from the past and jeopardize the entire system. Just deploying is not enough. We need to constantly make sure that all STs are up to date and maintain whatever other invariants are needed for these STs to trust each other.  

Let’s define as *Chain Type Manager* (CTM) **as a contract that is responsible for the following:

- It serves as a factory to deploy STs (new ZK chains)
- It is responsible for ensuring that all the STs deployed by it are up-to-date.

Note, that this means that STs have a “weaker” governance. I.e. governance can only do very limited number of things, such as setting the validator. ST admin can not set its own upgrades and it can only “execute” the upgrade that has already been prepared by the CTM.

In the long term vision STs deployment will be permissionless, however CTM will always remain the main point of trust and will have to be explicitly whitelisted by the decentralized governance of the entire ecosystem before its ST can get the access to the shared liquidity.

## Configurability in the first release

For now, only one CTM will be supported — the one that deploys instances of zkSync Era, possibly using other DA layers. To read more about different DA layers, check out this document (FIXME link).

The exact process of deploying & registering a ST will be described in [sections below](#creating-new-chains-with-bridgehub). Overall, each ST in the first release will have the following parameters:

| ST parameter | Updatability | Comment |
| --- | --- | --- |
| chainId | Permanent | Permanent identifier of the ST. Due to wallet support reasons, for now chainId has to be small (48 bits). This is one of the reasons why for now we’ll deploy STs manually, to prevent STs from having the same chainId as some another popular chain.  In the future it will be trustlessly assigned as a random 32-byte value.|
| baseTokenAssetId | Permanent | Each ST can have their own custom base token (i.e. token used for paying the fees). It is set once during creation and can never be changed. Note, that we refer to and "asset id" here instead of an L1 address. To read more about what is assetId and how it works check out the document for custom asset bridging (FIXME: link) |
| chainTypeManager | Permanent | The CTM that deployed the ST. In principle, it could be possible to migrate between CTMs (assuming both CTMs support that). However, in practice it may be very hard and as of now such functionality is not supported. |
| admin | By admin of ST | The admin of the ST. It has some limited powers to govern the chain. To read more about which powers are available to a chain admin and which precautions should be taken, check out this document (FIXME: link to document about admin precauotions) |
| validatorTimelock | CTM | For now, we want all the chains to use the same 21h timelock period before their batches are finalized. Only CTM can update the address that can submit state transitions to the rollup (that is, the validatorTimelock).  |
| validatorTimelock.validator | By admin of ST | The admin of ST can choose who can submit new batches to the ValidatorTimelock.  |
|  priorityTx FeeParams | By admin of ST | The admin of a ZK chain can amend the priority transaction fee params. |
|  transactionFilterer | By admin of ST | A chain may put an additional filter to the incoming L1->L2 transactions. This may be needed by a permissioned chain (e.g. a Validium bank-lile corporate chain). |
|  DA validation / permanent rollup status | By admin of ST | A chain can decide which DA layer to use. You check out more about safe DA management here (FIXME: link to admin doc) |
| executing upgrades | By admin of ST | While exclusively CTM governance can set the content of the upgrade, STs will typically be able to choose suitable time for them to actually execute it. In the first release, STs will have to follow our upgrades. |
| settlement layer | By admin of ST | The admin of the chain can enact migrations to other settlement layers. |

> Note, that if we take a look at the access control for the corresponding functions inside the [AdminFacet](../../l1-contracts/contracts/state-transition/chain-deps/facets/Admin.sol), the may see that a lot of methods from above that are marked as "By admin of ST" could be in theory amended by the ChainTypeManager. However, this sort of action requires approval from decentralized governance. Also, in case of an urgent high risk situation, the decentralized governance might force upgrade the contract via CTM.

## Upgradability in the current release

In the first release, each chain will be an instance of zkSync Era and so the upgrade process of each individual ST will be similar to that of zkSync Era.

1. Firstly, the governance of the CTM will publish the server (including sequencer, prover, etc) that support the new version . This is done offchain. Enough time should be given to various zkStack devs to update their version.
2. The governance of the CTM will publish the upgrade onchain by atomatically executing the following three transactions:

- `setChainCreationParams` ⇒ to ensure that new chains will be created with the version 
- `setValidatorTimelock` (if needed) ⇒ to ensure that the new chains will use the new validator timelock right-away
- `setNewVersionUpgrade` ⇒ to save the upgrade information that each ST will need to follow to conduct the upgrade on their side.

3. After that, each ChainAdmin can upgrade to the new version in suitable time for them. 

> Note, that while the governance does try to give the maximal possible time for chains to upgrade, the governance will typically put restrictions (aka deadlines) on the time by which the chain has to be upgraded. If the deadline is passed, the chain can not commit new batches until the upgrade is executed.

### Emergency upgrade

In case of an emergency, the [security council](https://blog.zknation.io/introducing-zk-nation/) has the ability to freeze the ecosystem and conduct an emergency upgrade (FIXME: link to governance doc).

In case we are aware that some of the committed batches on an ST are dangerous to be executed, the CTM can call `revertBatches` on that ST. For faster reaction, the admin of the ChainTypeManager has the ability to do so without waiting for govenrnace approval that may take a lot of time. This action does not lead to funds being lost, so it is considered suitable for the partially trusted role of the admin of the ChainTypeManager.

### Issues & caveats

- If an ZK chain skips an upgrade (i.e. it has version X, it did not upgrade to `X + 1` and now the latest protocol version is `X + 2` there is no built-in way to upgrade). This team will require manual intervention from us to upgrade.
- The approach of calling `revertBatches` for malicious STs is not scalable (O(N) of the number of chains). The situation is very rare, so it is fine in the short term, but not in the long run.

# BridgeHub & Asset Routers

In the previous section we discussed how STs and CTMs work. However, these are just means to get the collection of chains that can trust each other, while providing robust customizability for each individual chain. 

In this section we’ll explore how exactly unified liquidity is achieved and how do STs get deployed. 

## Creating new chains with BridgeHub

The main contract of the whole hyperchain ecosystem is called *`BridgeHub`*. It contains:

- the registry from chainId to CTMs that is responsible for that chainId
- the base token for each chainId.
- the whitelist of CTMs
- the whitelist of tokens allowed to be `baseTokens` of chains.
- the whitelist of settlement layers
- etc

BridgeHub is responsible for creating new STs. It is also the main point of entry for L1→L2 transactions for all the STs. Users won't be able to interact with STs directly, all the actions must be done through the BridgeHub, which will ensure that the fees have been paid and will route the call to the corresponding ST. One of the reasons it was done this way was to have the unified interface for all STs that will ever be included in the hyperchain ecosystem.

To create a chain, the `BridgeHub.createNewChain` function needs to be called:

```solidity
/// @notice register new chain. New chains can be only registered on Bridgehub deployed on L1. Later they can be moved to any other layer.
/// @notice for Eth the baseToken address is 1
/// @param _chainId the chainId of the chain
/// @param _chainTypeManager the state transition manager address
/// @param _baseTokenAssetId the base token asset id of the chain
/// @param _salt the salt for the chainId, currently not used
/// @param _admin the admin of the chain
/// @param _initData the fixed initialization data for the chain
/// @param _factoryDeps the factory dependencies for the chain's deployment
function createNewChain(
    uint256 _chainId,
    address _chainTypeManager,
    bytes32 _baseTokenAssetId,
    // solhint-disable-next-line no-unused-vars
    uint256 _salt,
    address _admin,
    bytes calldata _initData,
    bytes[] calldata _factoryDeps
) external
```

BridgeHub will check that the CTM as well as the base token are whitelisted and route the call to the State 

![newChain (2).png](./L1%20smart%20contracts/newChain.png)

### Creation of a chain in the first release

In the future, ST creation will be permissionless. A securely random `chainId` will be generated for each chain to be registered. However, generating 32-byte chainId is not feasible with the current SDK expectations on EVM and so for now chainId is of type `uint48`. And so it has to be chosen by the admin of `BridgeHub`. Also, for the first release we would want to avoid chains being able to choose their own initialization parameter to prevent possible malicious input.

For this reason, there will be an entity called `admin` which is basically a hot key managed by us and it will be used to deploy new STs. 

So the flow for deploying their own ST for users will be the following:

1. Users tell us that they want to deploy a ST with certain governance, CTM (we’ll likely allow only one for now), and baseToken. 
2. Our server will generate a chainId not reserved by any other major chain and the `admin` will call the `BridgeHub.createNewChain` . This will call the `CTM.createNewChain` that will deploy the instance of the rollup as well as initialize the first transaction there — the system upgrade transaction needed to set the chainId on L2.

After that, the ST is ready to be used. Note, that the admin of the newly created chain (this will be the organization that will manage this chain from now on) will have to conduct certain configurations before the chain can be used securely (FIXME: link).

## Asset router as the main asset bridging entrypoint

The main entry for passing value between chains is the AssetRouter, it is responsible for facilitating bridging between multiple asset types. To read more in detail on how it works, please refer to custom asset bridging documentation (FIXME: show the link).

For the purpose of this document, it is enough to treat the Asset Router as a blackbox that is responsible for processing escrowing funds on the source chain and minting them on the destination chain.

> For those that are aware of the [previous zkSync architecture](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart%20contract%20Section/L1%20ecosystem%20contracts.md), its role is similar to L1SharedBridge that we had before. Note, however, that it is a different contract with much enhanced functionality. Also, note that the L1SharedBridge will NOT be upgraded to the L1AssetRouter. For more detials about migration, please check out the migration doc (FIXME: migration doc).

### Handling base tokens

On L2, *a base token* (not to be consfused with a *native token*, i.e. an ERC20 token with a main contract on the chain) is the one that is used for `msg.value` and it is managed at `L2BaseToken` system contract. We need its logic to be strictly defined in `L2BaseToken`, since the base asset is expected to behave the exactly the same as ether on EVM. For now this token contract does not support base minting and burning of the asset, nor further customization.

In other words, in the current release base assets can only be transfered through `msg.value`. They can also only be minted when they are backed 1-1 on L1.

### **L1→L2 communication**

L1→L2 communication allows users on L1 to create a request for a transaction to happen on L2. This is the primary censorship resistance mechanism. If you are interested, you can read more on L1→L2 communications [here](./Handling%20L1→L2%20ops%20on%20zkSync.md), but for now just understanding that L1→L2 communication allows to request transactions to happen on L2 is enough.

The L1→L2 communication is also the only way to mint a base asset at the moment. Fees to the operator as well as `msg.value` will be minted on `L2BaseToken` after the corresponding L1→L2 tx has been processed.

To request an L1→L2 transaction, the `BridgeHub.requestL2TransactionDirect` function needs to be invoked. The user should pass the struct with the following parameters:

```solidity
struct L2TransactionRequestDirect {
    uint256 chainId;
    uint256 mintValue;
    address l2Contract;
    uint256 l2Value;
    bytes l2Calldata;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    bytes[] factoryDeps;
    address refundRecipient;
}
```

Most of the params are self-explanatory & replicate the logic of zkSync Era. The only non-trivial fields are:

- `mintValue` is the total amount of the base tokens that should be minted on L2 as the result of this transaction. The requirement is that `request.mintValue >= request.l2Value + request.l2GasLimit * derivedL2GasPrice(...)`, where  `derivedL2GasPrice(...)` is the gas price to be used by this L1→L2 transaction. The exact price is defined by the ST.

Here is a quick guide on how this transaction is routed through the bridgehub. 

1. The bridgehub retrieves the `baseTokenAssetId`  of the chain with the corresponding `chainId` and calls `L1AssetRouter.bridgehubDepositBaseToken` method. The `L1AssetRouter` will then use standard token depositing mechanism to burn/escrow the respective amount of the `baseTokenAssetId`. You can read more about it in the custom asset bridging doc (FIXME: link to CAB doc).

This step ensures that the baseToken will be backed 1-1 on L1.

2. After that, it just routes the corresponding call to the ST with the corresponding `chainId` . It is now the responsibility of the ST to validate that the transaction is correct and can be accepted by it. This validation includes, but not limited to:

- The fact that the user paid enough funds for the transaction (basically `request.l2GasLimit * derivedL2GasPrice(...) + request.l2Value >= request.mintValue`.
- The fact the transaction is always executable (the `request.l2GasLimit`  is not high enough).
- etc. 
3. After the ST validates the tx, it includes it into its priority queue. Once the operator executes this transaction on L2, the `mintValue` of the baseToken will be minted on L2. The `derivedL2GasPrice(...) * gasUsed` will be given to the operator’s balance. The other funds can be routed either of the following way:

If the transaction is successful, the `request.l2Value`  will be minted on the `request.l2Contract` address (it can potentially transfer these funds within the transaction).   The rest are minted to the `request.refundRecipient`  address. In case the transaction is not successful, all of the base token will be minted to the `request.refundRecipient` address. These are the same rules as for the zkSync Era.

FIXME: the diagrams below are not relevant

***Diagram of the L1→L2 transaction flow on L1 when the baseToken is ETH:***

![requestL2TransactionDirect (ETH) (2).png](./L1%20smart%20contracts/requestL2TransactionDirect-ETH.png)

***Diagram of the L1→L2 transaction flow on L1 when the baseToken is an ERC20:***

![requestL2TransactionDirect (ERC20) (3).png](./L1%20smart%20contracts/requestL2TransactionDirect.png)

***Diagram of the L1→L2 transaction flow on L2 (it is the same regardless of the baseToken):***

![L1-_L2 tx processing on L2.png](./L1%20smart%20contracts/L1-L2%20tx%20processing%20on%20L2.png)

### Limitations of custom base tokens in the first release

zkSync Era uses ETH as a base token. Upon creation of an ST other chains may want to use their own custom base tokens. Note, that for the first release all the possible base tokens are whitelisted. The other limitation is that all the base tokens must be backed 1-1 on L1 as well as they are solely implemented with `L2BaseToken`  contract. In other words:

- No custom logic is allowed on L2 for base tokens
- Base tokens can not be minted on L2 without being backed by the corresponding L1 amount.

If someone wants to build a protocol that mints base tokens on L2, the option for now is to “mint” an infinite amount of those on L1, deposit on L2 and then give those out as a way to “mint”. We will update this in the future.

## General architecture and initialization of SharedBridge for a new ST

Once the chain is created, its L2AssetRouter will be automatically deployed upon genesis. You can read more about it in the Chain creation flow (FIXME: link).

## L1AssetRouter as the main bridging entry

`L1AssetRouter` is used as the main "glue" for value bridging across chains. Whenever a token that is not native needs to be bridged between two chains an L1<>L2 transaction out of the name of an AssetRouter needs to be performed. For more details, check out the custom asset bridging documentation (FIXME: link). But for this section it is enough to understand that we need to somehow make a transaction out of the name of `L1AssetRouter` to its L2 counterpart to deliver the message about certain amount of asset being bridged.

> In the next paragraphs we will often refer to `L1AssetRouter` as performing something. It is good enough for understanding of how bridgehub functionality works. Under the hood though, it mainly serves as common entry that calls various asset handlers that are chosen based on asset id. You can read more about it in the custom asset bridging documentation (FIXME: link). 

Let’s say that a ST has ETH as its base token. Let’s say that the depositor wants to bridge USDC to that chain. We can not use `BridgeHub.requestL2TransactionDirect`, because it only takes base token `mintValue` and then starts an L1→L2 transaction rightaway out of the name of the user and not the `L1AssetRouter`. 

We need some way to atomically deposit both ETH and USDC to the shared bridge + start a transaction from `L1AssetRouter`. For that we have a separate function on `Bridgehub`: `BridgeHub.requestL2TransactionTwoBridges`. The reason behind the name “two bridges” is a bit historical: the transaction supposed compose to do actions with two bridges: the bridge responsible for base tokens and the second bridge responsible for any other token.

Note, however, that only `L1AssetRouter` can be used to bridge base tokens. And the role of the second bridge can be played by any contract that supports the protocol desrcibed below.

When calling `BridgeHub.requestL2TransactionTwoBridges` the following struct needs to be provided:

```solidity
struct L2TransactionRequestTwoBridgesOuter {
    uint256 chainId;
    uint256 mintValue;
    uint256 l2Value;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
    address secondBridgeAddress;
    uint256 secondBridgeValue;
    bytes secondBridgeCalldata;
} 
```

The first few fields are the same as for the simple L1→L2 transaction case. However there are three new fields:

- `secondBridgeAddress` is the address of the bridge (or contract in general) which will need to perform the L1->L2 transaction. In this case it should be the same `L1AssetRouter`
- `secondBridgeValue`  is the `msg.value`  to be sent to the bridge which is responsible for the asset being deposited (in this case it is `L1AssetRouter` ). This can be used to deposit ETH to STs that have base token that is not ETH.
- `secondBridgeCalldata`  is the data to pass to the second contract. `L1AssetRouter` supports multiple formats of calldata, the list can be seen in the `bridgehubDeposit` function of the `L1AssetRouter`.

The function will do the following:

**L1**

1. It will deposit the `request.mintValue`  of the ST’s base token the same way as during a simple L1→L2 transaction. These funds will be used for funding the `l2Value`  and the fee to the operator.
2. It will call the `secondBridgeAddress` (`L1AssetRouter`) once again and this time it will deposit the funds to the `L1AssetRouter`, but this time it will be deposit not to pay the fees, but rather for the sake of bridging the desired token.

This call will return the parameters to call the l2 contract with (the address of the L2 bridge counterpart,  the calldata and factory deps to call it with).
3. After the BridgeHub will call the ST to add the corresponding L1→L2 transaction to the priority queue.
4. The BridgeHub will call the `SharedBridge` once again so that it can remember the hash of the corresponding deposit transaction. [This is needed in case the deposit fails](#claiming-failed-deposits).

**L2**

1. After some time, the corresponding L1→L2 is created.
2. The L2AssetRouter will receive the message and re-route it to the asset handler of the bridged token. To read more about how it works, check out the custom asset bridging documentation (FIXME: link). 

***Diagram of a depositing ETH onto a chain with USDC as the baseToken. Note that some contract calls (like `USDC.transerFrom` are omitted for the sake of consiceness):***

FIXME: the following diagram is outdated.

![requestL2TransactionTwoBridges (SharedBridge) (1).png](./L1%20smart%20contracts/requestL2TransactionTwoBridges-depositEthToUSDC.png)

## Generic usage of `BridgeHub.requestL2TransactionTwoBridges`

`L1AssetRouter` is the only bridge that can handle base tokens. However, the `BridgeHub.requestL2TransactionTwoBridges` could be used by `secondBridgeAddress` on L1. A notable example of how it is done is how our [CTMDeploymentTracker](../../l1-contracts/contracts/bridgehub/CTMDeploymentTracker.sol) uses it to register the correct CTM address on Gateway. You can read more about how Gateway works in its documentation (FIXME: link). 

Let’s do a quick recap on how it works:

When calling `BridgeHub.requestL2TransactionTwoBridges` the following struct needs to be provided:

```solidity
struct L2TransactionRequestTwoBridgesOuter {
    uint256 chainId;
    uint256 mintValue;
    uint256 l2Value;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
    address secondBridgeAddress;
    uint256 secondBridgeValue;
    bytes secondBridgeCalldata;
} 
```

- `secondBridgeAddress` is the address of the L1 contract that needs to perform the L1->L2 transaction.
- `secondBridgeValue` is the `msg.value`  to be sent to the `secondBridgeAddress`.
- `secondBridgeCalldata` is the data to pass to the `secondBridgeAddress`. This can be interpreted any way it wants.

1. Firstly, the Bridgehub will deposit the `request.mintValue`  the same way as during a simple L1→L2 transaction. These funds will be used for funding the `l2Value`  and the fee to the operator.
2. After that, the `secondBridgeAddress.bridgehubDeposit` with the following signature is called

```solidity
struct L2TransactionRequestTwoBridgesInner {
    // Should be equal to a constant `keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1`
    bytes32 magicValue;
    // The L2 contract to call
    address l2Contract;
    // The calldata to call it with
    bytes l2Calldata;
    // The factory deps to call it with
    bytes[] factoryDeps;
    // Just some 32-byte value that can be used for later processing
    // It is called `txDataHash` as it *should* be used as a way to facilitate
    // reclaiming failed deposits. 
    bytes32 txDataHash;
}

function bridgehubDeposit(
    uint256 _chainId,
    // The actual user that does the deposit
    address _prevMsgSender,
    // The msg.value of the L1->L2 transaction to be created
    uint256 _l2Value,
    // Custom bridge-specific data
    bytes calldata _data
) external payable returns (L2TransactionRequestTwoBridgesInner memory request);
```

Now the job of the contract will be to “validate” whether they are okay with the transaction to come. For instance, the `CTMDeploymentTracker` checks that the `_prevMsgSender` is the owner of `CTMDeploymentTracker` and has the necesasry rights to perform the transaction out of the name of it.

Ultimately, the correctly processed `bridgehubDeposit` function basically grants `BridgeHub` the right to create an L1→L2 transaction out of the name of the `secondBridgeAddress`. Since it is so powerful, the first returned value must be a magical constant that is equal to `keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1`. The fact that it was a somewhat non standard signature and a struct with the magical value is the major defense against “accidental” approvals to start a transaction out of the name of an account.

Aside from the magical constant, the method should also return the information an L1→L2 transaction will start its call with: the `l2Contract` , `l2Calldata`, `factoryDeps`. It also should return the `txDataHash` field. The meaning `txDataHash` will be needed in the next paragraphs. But generally it can be any 32-byte value the bridge wants.

1. After that, an L1→L2 transaction is invoked. Note, that the “trusted” `L1AssetRouter` has enforced that the baseToken was deposited correctly (again, the step (1) can *only* be handled by the `L1AssetRouter`), while the second bridge can provide any data to call its L2 counterpart with.
2. As a final step, following function is called:

```solidity
function bridgehubConfirmL2Transaction(
    // `chainId` of the ST
    uint256 _chainId,
    // the same value that was returned by `bridgehubDeposit`
    bytes32 _txDataHash,
    // the hash of the L1->L2 transaction
    bytes32 _txHash
) external;
```

This function is needed for whatever actions are needed to be done after the L1→L2 transaction has been invoked. 

On `L1AssetRouter` it is used to remember the hash of each deposit transaction, so that later on, the funds could be returned to user if the `L1->L2` transaction fails.  The `_txDataHash` is stored so that the whenever the users will want to reclaim funds from a failed deposit, they would provide the token and the amount as well as the sender to send the money to.  

## Claiming failed deposits

In case a deposit fails, the `L1AssetRouter` allows users to recover the deposited funds by providing a proof that the corresponding transaction indeed failed. The logic is the same as in the current Era implementation.

## Withdrawing funds from L2

Funds withdrawal is a similar way to how it is done currently on Era.

The user needs to call the `L2AssetRouter.withdraw` function on L2, while providing the token they want to withdraw. This function would then calls the corresponding L2 asset handler and ask him to burn the funds. We expand a bit more about it in the CAB documentation (FIXME: link).

Note, however, that it is not the way to withdraw base token. To withdraw base token, `L2BaseToken.withdraw` needs to be called.

After the batch with the withdrawal request has been executed, the user can finalize the withdrawal on L1 by calling `L1AssetRouter.finalizeWithdrawal`, where the user provides the proof of the corresponding withdrawal message.

# Additional limitations for the current release

In the current release creating new chains will not be permissionless. That is needed to ensure that no malicious input can be provided there. 

Also, since in the current release, there will be little benefits from shared liquidity, i.e. the there will be no direct ST<>ST transfers supported, as a measure of additional security we’ll also keep track of balances for each individual ST and will not allow it to withdraw more than it has deposited into the system.

# Other contracts

## Governance

The documentation about decentralized governance can be read here (FIXME: provide link).

## ValidatorTimelock

All the chains registered on the current CTM share the same timelock for batch execution. It is a security feature, you can read more about it [here](./L1%20smart%20contracts.md#validatortimelock). 
