FIXME: read and fix any issues


# Intro & Prerequisites

Ethereum's future is rollup-centric. This means breaking with the current paradigm of isolated EVM chains to infrastructure that is focused on an ecosystem of interconnected zkEVMs/zkVMs, (which we name Hyperchains). This ecosystem will be grounded on Ethereum, requiring the appropriate L1 smart contracts. Here we outline our ZK Stack approach for these contracts, their interfaces, the needed changes to the existing architecture, as well as future features to be implemented.

If you want to know more about Hyperchains, check this [blog post](https://blog.matter-labs.io/introduction-to-hyperchains-fdb33414ead7), or go through [our docs](https://era.zksync.io/docs/reference/concepts/hyperscaling.html).

This document will assume the reader already knows how rollups (esp. zkSync Era) work.

## Long term goal

We want to create a system where:

- Hyperchains should be launched permissionlessly within the ecosystem.
- Hyperbridges should enable unified liquidity for assets across the ecosystem.
- Multi-chain smart contracts need to be easy to develop, which means easy access to traditional bridges, and other supporting architecture.


### Images:

![Contracts](./L1%20smart%20contracts/Hyperchain-scheme.png)

# Table of content

# ST & STM

## State transition (Diamond Proxy)

A high-level recap on how zk rollups work:

- Offchain operators collect transactions, process those and submit a tuple of `(old_state, new_state, proof)` to the L1 contract.
- The L1 contract then verifies that the proof is correct. If the proof is indeed correct, the `new_state` gets saved on the L1 contract. This `new_state` may not only include the storage root, but also a tree for L2→L1 messages (which allow to conduct withdrawals of funds from the L2), etc.

In other words, we can imagine the L1 part of each rollup as a basically a “state transition function verifier”, the only role of which is to check whether the state transition proposed by the operator of the chain is correct. 

To not commit to a specific type or option of this “state transition function”, we’ll call each rollup a   *State Transition* or ST. Note, that STs can be Validiums. An ST does not even have to be an L2 chain, it can also be an L3, etc.

But for now, whenever you see any mentioning of ST, Diamond Proxy, just imagine a single instance of an L2 chain. e.g. zkSync Era is an ST. 

> **NOTE**: Currently deployed zkSync Era also holds ether deposited to the system. After this upgrade, all state transition contracts, including zkSync Era diamond proxy, will no longer directly manage any funds. Instead, this responsibility will transition to the shared bridge. For details on how this migration will be implemented, please refer to [migration doc](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Protocol%20Section/Migration%20process.md). This document described technical details of zkStack contracts that make it possible for multiple L2/L3 chains to share liquidity, and provide cost-effective communication among them. Before delving into the details of ecosystem contracts, please familiarize yourself with the concept of [Hyperchain](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Protocol%20Section/Overview.md#the-hyperchain) and read [L1 smart contracts page](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart%20contract%20Section/L1%20smart%20contracts.md) for a better understanding of single instance hyperchain.

## State transition manager (STM)

Currently bridging between different zk rollups requires the funds to pass through L1. This is slow & expensive.

The vision of seamless internet of value requires transfers of value to be *both* seamless and trustless. This means that for instance different STs need to share the same L1 liquidity, i.e. a transfer of funds should never touch L1 in the process. However, it requires some sort of trust between two chains. If a malicious (or broken) rollup becomes a part of the shared liquidity pool it can steal all the funds. 

However, can two instances of the same zk rollup trust each other? The answer is yes, because no new additions of rollups introduce new trust assumptions. Assuming there are no bugs in circuits, the system will work as intended.

How can two rollups know that they are two different instances of the same system? We can create a factory of such contracts (and so we would know that each new rollup created by this instance is correct one). But just creating correct contracts is not enough. Ethereum changes, new bugs may be found in the original system & so an instance that does not keep itself up-to-date with the upgrades may exploit some bug from the past and jeopardize the entire system. Just deploying is not enough. We need to constantly make sure that all STs are up to date and maintain whatever other invariants are needed for these STs to trust each other.  

Let’s define as *State Transition Manager* (STM) **as a contract that is responsible for the following:

- It serves as a factory to deploy STs
- It is responsible for ensuring that all the STs deployed by it are up-to-date.

Note, that this means that STs have a “weaker” governance. I.e. governance can only do very limited number of things, such as setting the validator. ST governor can not set its own upgrades and it can only “execute” the upgrade that has already been prepared by the STM.

In the long term vision STs deployment will be permissionless, however STM will always remain the main point of trust and will have to be explicitly whitelisted by the greater governance of the entire hyperchain before its ST can get the access to the shared liquidity.

## Configurability in the first release

For now, only one STM will be supported — the one that deploys instances of zkSync Era, possibly using other DA layers. The inner working of different DA layer support is not relevant for this documentation.

The exact process of deploying & registering an ST will be described in [sections below](#creating-new-chains-with-bridgehub). Overall, each ST in the first release will have the following parameters:

| ST parameter | Updatability | Comment |
| --- | --- | --- |
| chainId | Permanent | Permanent identifier of the ST. Due to wallet support reasons, for now chainId has to be small (48 bits). This is one of the reasons why for now we’ll deploy STs manually, to prevent STs from having the same chainId as some another popular chain.  In the future it will be trustlessly assigned as a random 32-byte value.|
| baseToken | Permanent | Each ST can have their own custom base token (i.e. token used for paying the fees). It is set once during creation and can never be changed. For now, each baseToken  has to be backed by the corresponding L1 tokens. The requirements for the baseToken  will be explored in the sections dedicated to SharedBridge. |
| stateTransitionManager | Permanent | The STM that deployed the ST. In principle, it could be possible to migrate between STMs (assuming both STMs support that). However, in practice it may be very hard and as of now such functionality is not supported. |
| admin | By admin of ST | The governor of the ST. It has some limited powers to govern the chain |
| validatorTimelock | STM | For now, we want all the chains to use the same 21h timelock period before their batches are finalized. Only STM can update the address that can submit state transitions to the rollup (that is, the validatorTimelock).  |
| validatorTimelock.validator | STM | The governance of ST can choose who can submit new batches to the ValidatorTimelock.  |
|  priorityTx Validation/ priorityTx FeeParams | STM | For now, for the additional security only STM can define the validation rules for L1→L2 transactions coming to the chain. |
| executing upgrades | By governance of ST or STM | While exclusively STM governance can set the content of the upgrade, STs will typically be able to choose suitable time for them to actually execute it. In the first release, STs will have to follow our upgrades.

However, in case of urgent high risk situation, STM might force upgrade the contract.

Note that for now, DA layers can not be chosen within our STM, but in the future the governance of the ST will be able to choose their own DA layer. It is also planned to allow different chains different L1→L2 tx validation methods. This might be helpful for some chains that want to put heavier restrictions on the L1→L2 transactions coming from L1. 

## Upgradability in the first release

In the first release, each chain will be an instance of zkSync Era and so the upgrade process of each individual ST will be similar to that of zkSync Era.

1. Firstly, the governance of the STM will publish the server (including sequencer, prover, etc) that support the new version . This is done offchain. Enough time should be given to various zkStack devs to update their version.
2. The governance of the STM will schedule the upgrade. This operation also notifies the operators of STs on when they should start processing new batches. The server is written in such a way that automatically at the scheduled timestamp of the upgrade the new version will be used in batches. If the timestamp is set in the past, the new version will be used immediately. 
3. After the timestamp has passed it is expected that zkStack instances will all start processing the new version on the server side. 

After that the governance atomically calls the following three functions:

- `setInitialCutHash` ⇒ to ensure that new chains will be created with the version 
- `setValidatorTimelock` (if needed) ⇒ to ensure that the new chains will use the new validator timelock right-away
- `setNewVersionUpgrade` ⇒ to save the upgrade information that each ST will need to follow to conduct the upgrade on their side.
4. After this step, the batches with the old protocol version can no longer be committed. They can be proved & executed however.

### Emergency upgrade

In case of an emergency of a critical bug, the step (1) can be skipped as well as the waiting period in step (2) can be reduced to 0.

In case we are aware that some of the committed batches on an ST are dangerous to be executed, the STM can call `revertBatches`  on that ST. 

### Issues & caveats

- If an ST skips an upgrade (i.e. it has version X, it did not upgrade to `X + 1` and now the latest protocol version is `X + 2` there is no built-in way to upgrade). This team will require manual intervention from us to upgrade.
- The upgrades of STs are not fully async as of now (i.e. either tight coordination or strict deadlines are required to ensure that every ST has time to commit their batches). This needs to be fixed in the future releases.
- The approach of calling `revertBatches` for malicious STs is not scalable (O(N) of the number of chains). The situation is very rare, so it is fine in the short term, but not in the long run.

# BridgeHub & Shared Bridge

In the previous section we discussed how STs and STMs work. However, these are just means to get the collection of chains that can trust each other, while providing robust customizability for each individual chain. 

In this section we’ll explore how exactly unified liquidity is achieved and how do STs get deployed. 

## Creating new chains with BridgeHub

The main contract of the whole hyperchain ecosystem is called *`BridgeHub`*. It contains:

- the registry from chainId to STMs that is responsible for that chainId
- the base token for each chainId.
- the whitelist of STMs
- the whitelist of tokens allowed to be `baseTokens` of chains.

In the long run, any `baseToken`  could be used (obviously at the peril of the ST that decides to use it). It will also be possible to add multiple STMs.

BridgeHub is responsible for creating new STs. It is also the main point of entry for L1→L2 transactions for all the STs. Users won't be able to interact with STs directly, all the actions must be done through the BridgeHub, which will ensure that the fees have been paid and will route the call to the corresponding ST. One of the reasons it was done this way was to have the unified interface for all STs that will ever be included in the hyperchain ecosystem.

To create a chain, the `BridgeHub.createNewChain` function needs to be called:

```solidity
function createNewChain(
    // The expected chainId of the new ST
    uint256 _chainId,
    // The state transition manager that will deploy & manage it
    address _stateTransitionManager,
    // The baseToken to be used by the ST
    address _baseToken,
    // Salt, for now it is not used. It will be used in the future for
    // random chainId generation 
    uint256, //_salt
    // The initial governor of the ST
    address _l2Governor,
    // The initData. This data is strictly defined by STM and is needed to initialize
    // the ST with the latest protocol version. The correctness of it will be verified by STM.
    bytes calldata _initData
)
```

BridgeHub will check that the STM as well as the base token are whitelisted and route the call to the State 

![newChain (2).png](./L1%20smart%20contracts/newChain.png)

### Creation of a chain in the first release

In the future, ST creation will be permissionless. A securely random `chainId` will be generated for each chain to be registered. However, generating 32-byte chainId is not feasible with the current SDK expectations on EVM and so for now chainId is of type `uint48`. And so it has to be chosen by the governance of `BridgeHub`. Also, for the first release we would want to avoid chains being able to choose their own initialization parameter to prevent possible malicious input.

For this reason, there will be an entity called `admin` which is basically a hot key managed by us and it will be used to deploy new STs. 

So the flow for deploying their own ST for users will be the following:

1. Users tell us (e.g. via a Google Form) that they want to deploy an ST with certain governance, STM (we’ll likely allow only one for now), and baseToken. 
2. Our server will generate a chainId not reserved by any other major chain and the `admin` will call the `BridgeHub.createNewChain` . This will call the `STM.createNewChain` that will deploy the instance of the rollup as well as initialize the first transaction there — the system upgrade transaction needed to set the chainId on L2.

After that, the ST is ready to be used.

## SharedBridge as store of base tokens

For liquidity to be unified there needs to be a contract that actually maintains all of it. This contract is `SharedBridge`. Users are free to deploy their own bridges to interact with the hyperchain ecosystem, but SharedBridge is special, because it maintains the balance of all the `baseToken`s, including all of ETH supply. In the future we might allow multiple base token bridges, or we will make the current shared bridge more customisable.

### Handling base tokens

On L2, *a base token* (not to be consfused with a *native token*, i.e. an ERC20 token with a main contract on the chain) is the one that is used for `msg.value` and it is managed at `L2BaseToken` system contract. We need its logic to be strictly defined in `L2BaseToken`, since the base asset is expected to behave the exactly the same as ether on EVM. For now this token contract does not support base minting and burning of the asset, nor further customization.

In other words, in the current release base assets can only be transfered through `msg.value`. They can also only be minted when they are backed 1-1 on L1.

### **L1→L2 communication**

L1→L2 communication allows users on L1 to create a request for a transaction to happen on L2. This is the primary censorship resistance mechanism. If you are interested, you can read more on L1→L2 communications [here](https://github.com/code-423n4/2024-03-zksync/blob/main/docs/Smart%20contract%20Section/Handling%20L1→L2%20ops%20on%20zkSync.md), but for now just understanding that L1→L2 communication allows to request transactions to happen on L2 is enough.

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

Most of the params are self-explanatory & replicate the logic of zkSync Era. The only new fields are:

- `mintValue` is the total amount of the base tokens that should be minted on L2 as the result of this transaction. The requirement is that `request.mintValue >= request.l2Value + request.l2GasLimit * derivedL2GasPrice(...)`, where  `derivedL2GasPrice(...)` is the gas price to be used by this L1→L2 transaction. The exact price is defined by the ST.

Here is a quick guide on how this transaction is routed through the bridgehub. 

1. The bridgehub retrieves the `baseToken`  of the chain with the corresponding `chainId` and deposits `mintValue` tokens to the SharedBridge. In case the baseToken is ETH, it must be provided with the `msg.value` of the L1 transaction. If the base token is an ERC20, the corresponding allowance should be provided beforehand to the SharedBridge.

This step ensures that the baseToken will be backed 1-1 on L1.

2. After that, it just routes the corresponding call to the ST with the corresponding `chainId` . It is now the responsibility of the ST to validate that the transaction is correct and can be accepted by it. This validation includes, but not limited to:

- The fact that the user paid enough funds for the transaction (basically `request.l2GasLimit * derivedL2GasPrice(...) + request.l2Value >= request.mintValue`.
- The fact the transaction is always executable (the `request.l2GasLimit`  is not high enough).
- etc. 
3. After the ST validates the tx, it includes it into its priority queue. Once the operator executes this transaction on L2, the `mintValue` of the baseToken will be minted on L2. The `derivedL2GasPrice(...) * gasUsed` will be given to the operator’s balance. The other funds can be routed either of the following way:

If the transaction is successful, the `request.l2Value`  will be minted on the `request.l2Contract` address (it can potentially transfer these funds within the transaction).   The rest are minted to the `request.refundRecipient`  address. In case the transaction is not successful, all of the base token will be minted to the `request.refundRecipient` address. These are the same rules as for the zkSync Era.

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

Right after an ST is deployed, the `SharedBridge` will already be used for `baseToken` -related bridging. However, it can also support the `ERC20` bridging. But for that it needs additional components. 

The `SharedBridge` consists of two parts:

- `L1SharedBridge` that stores all the funds on L1.
- `L2SharedBridge` that mints & manages the corresponding tokens on L2. Also, whenever a withdrawal needs to happen, the user calls this asset

`L1SharedBridge` contains a mapping from a chainId to the address of the `L2SharedBridge`. Whenever a deposit to certain chain happens `L1SharedBridge` looks up the address of the `L2SharedBridge` and asks to do an L1→L2 transaction there.

Note, that it is actually *vital* that the corresponding L2 counterpart is already predeployed before the bridge serves its first non-`basetoken` deposit. If this is not the case, the deposits will “fail” in the sense that no tokens on L2 will be minted, while the status of the transaction will be “success” (since an empty address was called) meaning that there is no way for users to reclaim those funds.

The flow is expected to be the following:

- Once an ST is created, it will be the job of its first validator (it can be done any user with access to that ST) to deploy such a bridge.
- Before `SharedBridge` can start depositing non-base tokens to that bridge, someone must provide a proof that indeed such a contract has been deployed on a certain specific address. After that the corresponding `L2SharedBridge` location for such `chainId` will be stored.

The details of how such a proof should look like are out of the scope of this document, but it is relatively easy to do.

### Initialization in the first release

In the first release however, instead of providing such a proof permissionessly on L1, the ST owner will have to send a message to us, we will double-check that the deployed bytecode is correct and initialized properly. Once it is done, our governance will call the `initializeChainGovernance` function on the `SharedBridge` to make a chain as initialized.

## Shared bridge as standard ERC20 bridge

`SharedBridge` does not only serve as store for base tokens. It is also de-facto hyperchain implementation of the zkSync Era’s ERC20 token [default bridge](https://docs.zksync.io/build/developer-reference/bridging-asset.html), i.e. the bridge that allows users to bridge ERC20 assets to L2. The bridged assets will have “standard” ERC20 token implementation, i.e. fee-on-transfer, rebase or other sort of custom token functionality will not be supported for bridged assets.

For better understanding of this section it is recommended to understand (at least roughly) how bridging on zkSync Era works. More documentation on it can be found [here](https://docs.zksync.io/build/developer-reference/bridging-asset.html).

Let’s say that an ST has ETH as its base token. Let’s say that the depositor wants to bridge USDC to that chain. We can not use `BridgeHub.requestL2TransactionDirect`, because it only takes base token `mintValue` and then starts an L1→L2 transaction rightaway out of the name of the user and not the `L1SharedBridge`. We need some way to atomically deposit both ETH and USDC to the shared bridge + start a transaction from `L1SharedBridge`. For that we have a separate function on `Bridgehub`: `BridgeHub.requestL2TransactionTwoBridges`. The reason behind the name “two bridges” will be explored a bit later, but for now let’s only take the case for trying to deposit a non-base token via `SharedBridge`.

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

- `secondBridgeAddress` is the address of the bridge which is responsible for the asset being deposited. In this case it should be the same `SharedBridge`
- `secondBridgeValue`  is the `msg.value`  to be sent to the bridge which is responsible for the asset being deposited (in this case it is `SharedBridge` ). This can be used to deposit ETH to STs that have base token that is not ETH.
- `secondBridgeCalldata`  is the data to pass to the bridge. `SharedBridge`  requires it to be `abi.encode(address _l1Token, uint256 _depositAmount, address _l2Receiver)` , where this is the data about which L1 token to deposit to L2, the amount to deposit, and where should it go.

The function will do the following:

**L1**

1. It will deposit the `request.mintValue`  of the ST’s base token the same way as during a simple L1→L2 transaction. These funds will be used for funding the `l2Value`  and the fee to the operator.
2. It will call the `secondBridgeAddress` (`SharedBridge`) once again and this time it will deposit the funds to the `SharedBridge`, but this time it will be deposit not to pay the fees, but rather `_depositAmount` of `_l1Token` will be deposited.

This call will return the parameters to call the l2 contract with (the address of the L2 bridge counterpart,  the calldata and factory deps to call it with).
3. After the BridgeHub will call the ST to add the corresponding L1→L2 transaction to the priority queue.
4. The BridgeHub will call the `SharedBridge` once again so that it can remember the hash of the corresponding deposit transaction. [This is needed in case the deposit fails](#claiming-failed-deposits).

**L2**

1. After some time, the corresponding L1→L2 is created.
2. The L2 bridge counterpart will deploy the standard L2 token implementation for this specific asset if it has not been deployed previously. 
3. The L2 bridge counterpart will mint the funds.

***Diagram of a depositing ETH onto a chain with USDC as the baseToken. Note that some contract calls (like `USDC.transerFrom` are omitted for the sake of consiceness):***

![requestL2TransactionTwoBridges (SharedBridge) (1).png](./L1%20smart%20contracts/requestL2TransactionTwoBridges-depositEthToUSDC.png)

## Generic usage of `BridgeHub.requestL2TransactionTwoBridges`

`SharedBridge` is the only bridge that can handle base tokens. However, anyone is allowed to create any sort of bridge that handle non-base assets. For bridging tokens via such bridges, the same `BridgeHub.requestL2TransactionTwoBridges` has to be used. 

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

- `secondBridgeAddress` is the address of the bridge that is responsible for the asset being deposited.
- `secondBridgeValue`  is the `msg.value`  to be sent to the bridge which is responsible for the asset being deposited.
- `secondBridgeCalldata`  is the data to pass to the bridge. This can be interpreted any way it wants.

1. Firstly, It will deposit the `request.mintValue`  the same way as during a simple L1→L2 transaction. These funds will be used for funding the `l2Value`  and the fee to the operator.
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

Now the job of the contract will be to “validate” whether they are okay with the transaction to come. For instance, if it is some sort of “WETH” bridge, it would check that `msg.value` is enough to cover for the minted L2 WETH. Another potential functionality of this part is to deposit the corresponding L1 assets to the contracts. Both of the things above are done by the `SharedBridge`. 

However, a custom bridge can be whatever it wants. Ultimately, the correctly processed `bridgehubDeposit` function basically grants `BridgeHub` the right to create an L1→L2 transaction out of the name of the `secondBridgeAddress`. Since it is so powerful, the first returned value must be a magical constant that is equal to `keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1`. The fact that it was a somewhat non standard signature and a struct with the magical value is the major defense against “accidental” approvals to start a transaction out of the name of an account.

Aside from the magical constant, the method should also return the information an L1→L2 transaction will start its call with: the `l2Contract` , `l2Calldata`, `factoryDeps`. It also should return the `txDataHash` field. The meaning `txDataHash` will be needed in the next paragraphs. But generally it can be any 32-byte value the bridge wants.

1. After that, an L1→L2 transaction is invoked. Note, that the “trusted” `SharedBridge` has enforced that the baseToken was deposited correctly (again, the step (1) can *only* be handled by the `SharedBridge`), while the second bridge can provide any data to call its L2 counterpart with.
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

On `SharedBridge` it is used to remember the hash of each deposit transaction, so that later on, the funds could be returned to user if the `L1->L2` transaction fails.  The `_txDataHash` is stored so that the whenever the users will want to reclaim funds from a failed deposit, they would provide the token and the amount as well as the sender to send the money to.  

> The call diagram for an L1 generic deposit via `requestL2TransactionTwoBridges` & a custom bridge looks the same as with the `SharedBridge`. Ultimately the L2 behavior depends on the implementation of the custom bridge, i.e. which `l2Contract` and `l2Calldata` it will return in `bridgehubDeposit`.
> 


## Claiming failed deposits

In case a deposit fails, the `SharedBridge` allows users to recover the deposited funds by providing a proof that the corresponding transaction indeed failed. The logic is the same as in the current Era implementation. 

## Withdrawing funds from L2

Funds withdrawal is done the same way as it is currently on Era. The only difference is that now wrapped tokens are supported as well.

The user needs to call the `L2SharedBridge.withdraw` function on L2, while providing the token they want to withdraw. This function works both for the wrapped base token and for any standardly bridged ERC20. Note, however, that it is not the way to withdraw base token. To withdraw base token, `L2BaseToken.withdraw` needs to be called.

After the batch with the withdrawal request has been executed, the user can finalize the withdrawal on L1 by calling `L1SharedBridge.finalizeWithdrawal`, where the user provides the proof of the corresponding withdrawal message.  

# Migration of zkSync Era

All of the above describes how the shared bridge & bridge hub will work in the end. However, how do we make sure that the users’ interfaces don't break?

## Migrating bridges

`L1ERC20Bridge` will be migrated to a new implementation that will route all calls to the `L1SharedBridge`. Also we’ll have to migrate all ERC20 balances to the new `L1SharedBridge`. At the time of this writing there are 246 tokens to migrate (we can assume 300 in case there are more to be added). 

`L2ERC20Bridge` already has the needed interfaces and so it will just be migrated to become `L2SharedBridge` directly.

Also, right now it is possible to derive on L1 the address of the corresponding bridged L2 token. This will not be possible as in theory different STs might have different code for deployed beacon proxy. This functionality will only be maintained for backwards compatibility in  `L1ERC20Bridge` that can only interact with Era.

## Migrating direct interaction with Era

zkSync ERA will become an ST, under a newly deployed STM. However, users already rely on the fact that it is possible to interact with Era directly and not through BridgeHub. We will keep that functionality exclusively for Era.

In practice, all our STs will have Era’ `requestL2Transaction` function, but it will be only allowed to be called if the ST is Era.

Also, during migration Era has to send all its ETH to `BridgeHub`.

# Additional limitations for the first release

In the first release creating new chains as well as `SharedBridge` initialization for new chains will not be permissionless. That is needed to ensure that no malicious input can be provided there. 

Also, since in the first release, there will be little benefits from shared liquidity, i.e. the there will be no direct ST<>ST transfers supported, as a measure of additional security we’ll also keep track of balances for each individual ST and will not allow it to withdraw more than it has deposited into the system.

# Other contracts

## Governance

This contract manages calls for all governed zkSync Era contracts on L1 and L2. Mostly, it is used for upgradability and changing critical system parameters. The contract has minimum delay settings for the call execution. 

Each upgrade consists of two steps:

- Scheduling - The owner can schedule upgrades in two different manners:
    - Fully transparent data. All the targets, calldata, and upgrade conditions are known to the community before upgrade execution.
    - Shadow upgrade. The owner only shows the commitment to the upgrade. This upgrade type is mostly useful for fixing critical issues in the production environment.
- Upgrade execution - the Owner or Security council can perform the upgrade with previously scheduled parameters.
    - Upgrade with delay. Scheduled operations should elapse the delay period. Both the owner and Security Council can execute this type of upgrade.
    - Instant upgrade. Scheduled operations can be executed at any moment. Only the Security Council can perform this type of upgrade.

Only Owner can cancel the upgrade before its execution. 

The diagram below outlines the complete journey from the initiation of an operation to its execution.

![governance.png](L1%20smart%20contracts/Governance-scheme.jpg)

### Upgrade mechanism

Currently, there are three types of upgrades for zkSync Era. Normal upgrades (used for new features) are initiated by the Governor (a multisig) and are public for a certain timeframe before they can be applied. Shadow upgrades are similar to normal upgrades, but the data is not known at the moment the upgrade is proposed, but only when executed (they can be executed with the delay, or instantly if approved by the security council). Instant upgrades (used for security issues), on the other hand happen quickly and need to be approved by the Security Council in addition to the Governor. For hyperchains the difference is that upgrades now happen on multiple chains. This is only a problem for shadow upgrades - in this case, the chains have to tightly coordinate to make all the upgrades happen in a short time frame, as the content of the upgrade becomes public once the first chain is upgraded.
The actual upgrade process is as follows: 

1. Prepare Upgrade for all chains:
    - The new facets and upgrade contracts have to be deployed,
    - The upgrade’ calldata (diamondCut, initCalldata with ProposedUpgrade) is hashed on L1 and the hash is saved.
2. Upgrade specific chain
    - The upgrade has to be called on the specific chain. The upgrade calldata is passed in as calldata and verified. The protocol version is updated.
    - Ideally, the upgrade will be very similar for all chains. If it is not, a smart contract can calculate the differences. If this is also not possible, we have to set the `diamondCut` for each chain by hand.
3. Freeze not upgraded chains
    - After a certain time the chains that are not upgraded are frozen.


## ValidatorTimelock

An intermediate smart contract between the validator EOA account and the diamon proxy state transition smart contracts.
Its primary purpose is
to provide a trustless means of delaying batch execution without modifying the main state transition contract. zkSync actively
monitors the chain activity and reacts to any suspicious activity by freezing the chain. This allows time for
investigation and mitigation before resuming normal operations.

It is a temporary solution to prevent any significant impact of the validator hot key leakage, while the network is in
the Alpha stage.

This contract consists of four main functions `commitBatchesSharedBridge`, `proveBatchesSharedBridge`, `executeBatchesSharedBridge`, and `revertBatchesSharedBridge`, which can be called only by the validator of the given chain.

When the validator calls `commitBatchesSharedBridge`, the same calldata will be propagated to the zkSync contract with the correct chainId (`DiamondProxy` through `call` where it invokes the `ExecutorFacet` through `delegatecall`), and also a timestamp is assigned to these batches to track
the time these batches are committed by the validator to enforce a delay between committing and execution of batches. Then, the
validator can prove the already committed batches regardless of the mentioned timestamp, and again the same calldata (related
to the `proveBatches` function) will be propagated to the zkSync contract. After the `delay` is elapsed, the validator
is allowed to call `executeBatches` to propagate the same calldata to zkSync contract. 

The owner of the ValidatorTimelock contract is the same as the owner of the Governance contract - Matter Labs multisig.
