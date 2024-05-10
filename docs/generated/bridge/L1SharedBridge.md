## L1SharedBridge

_Bridges assets between L1 and hyperchains, supporting both ETH and ERC20 tokens.
Designed for use with a proxy for upgradability._

### L1_WETH_TOKEN

```solidity
address L1_WETH_TOKEN
```

_The address of the WETH token on L1._

### BRIDGE_HUB

```solidity
contract IBridgehub BRIDGE_HUB
```

_Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication._

### ERA_CHAIN_ID

```solidity
uint256 ERA_CHAIN_ID
```

_Era's chainID_

### ERA_DIAMOND_PROXY

```solidity
address ERA_DIAMOND_PROXY
```

_The address of zkSync Era diamond proxy contract._

### eraPostDiamondUpgradeFirstBatch

```solidity
uint256 eraPostDiamondUpgradeFirstBatch
```

_Stores the first batch number on the zkSync Era Diamond Proxy that was settled after Diamond proxy upgrade.
This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
than this value are considered to have been finalized prior to the upgrade and handled separately._

### eraPostLegacyBridgeUpgradeFirstBatch

```solidity
uint256 eraPostLegacyBridgeUpgradeFirstBatch
```

_Stores the first batch number on the zkSync Era Diamond Proxy that was settled after L1ERC20 Bridge upgrade.
This variable is used to differentiate between pre-upgrade and post-upgrade ERC20 withdrawals. Withdrawals from batches older
than this value are considered to have been finalized prior to the upgrade and handled separately._

### eraLegacyBridgeLastDepositBatch

```solidity
uint256 eraLegacyBridgeLastDepositBatch
```

_Stores the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge
This variable (together with eraLegacyBridgeLastDepositTxNumber) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older batches
than this value are considered to have been processed prior to the upgrade and handled separately.
We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously._

### eraLegacyBridgeLastDepositTxNumber

```solidity
uint256 eraLegacyBridgeLastDepositTxNumber
```

_The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge
This variable (together with eraLegacyBridgeLastDepositBatch) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older txs
than this value are considered to have been processed prior to the upgrade and handled separately.
We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously._

### legacyBridge

```solidity
contract IL1ERC20Bridge legacyBridge
```

_Legacy bridge smart contract that used to hold ERC20 tokens._

### l2BridgeAddress

```solidity
mapping(uint256 => address) l2BridgeAddress
```

_A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet._

### depositHappened

```solidity
mapping(uint256 => mapping(bytes32 => bytes32)) depositHappened
```

_A mapping chainId => L2 deposit transaction hash => keccak256(abi.encode(account, tokenAddress, amount))
Tracks deposit transactions from L2 to enable users to claim their funds if a deposit fails._

### isWithdrawalFinalized

```solidity
mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) isWithdrawalFinalized
```

_Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized._

### hyperbridgingEnabled

```solidity
mapping(uint256 => bool) hyperbridgingEnabled
```

_Indicates whether the hyperbridging is enabled for a given chain._

### chainBalance

```solidity
mapping(uint256 => mapping(address => uint256)) chainBalance
```

_Maps token balances for each chain to prevent unauthorized spending across hyperchains.
This serves as a security measure until hyperbridging is implemented.
NOTE: this function may be removed in the future, don't rely on it!_

### onlyBridgehub

```solidity
modifier onlyBridgehub()
```

Checks that the message sender is the bridgehub.

### onlyBridgehubOrEra

```solidity
modifier onlyBridgehubOrEra(uint256 _chainId)
```

Checks that the message sender is the bridgehub or zkSync Era Diamond Proxy.

### onlyLegacyBridge

```solidity
modifier onlyLegacyBridge()
```

Checks that the message sender is the legacy bridge.

### onlySelf

```solidity
modifier onlySelf()
```

Checks that the message sender is the shared bridge itself.

### constructor

```solidity
constructor(address _l1WethAddress, contract IBridgehub _bridgehub, uint256 _eraChainId, address _eraDiamondProxy) public
```

_Contract is expected to be used as proxy implementation.
Initialize the implementation to prevent Parity hack._

### initialize

```solidity
function initialize(address _owner) external
```

_Initializes a contract bridge for later use. Expected to be used in the proxy_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _owner | address | Address which can change L2 token implementation and upgrade the bridge implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge. |

### setEraPostDiamondUpgradeFirstBatch

```solidity
function setEraPostDiamondUpgradeFirstBatch(uint256 _eraPostDiamondUpgradeFirstBatch) external
```

_This sets the first post diamond upgrade batch for era, used to check old eth withdrawals_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eraPostDiamondUpgradeFirstBatch | uint256 | The first batch number on the zkSync Era Diamond Proxy that was settled after diamond proxy upgrade. |

### setEraPostLegacyBridgeUpgradeFirstBatch

```solidity
function setEraPostLegacyBridgeUpgradeFirstBatch(uint256 _eraPostLegacyBridgeUpgradeFirstBatch) external
```

_This sets the first post upgrade batch for era, used to check old token withdrawals_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eraPostLegacyBridgeUpgradeFirstBatch | uint256 | The first batch number on the zkSync Era Diamond Proxy that was settled after legacy bridge upgrade. |

### setEraLegacyBridgeLastDepositTime

```solidity
function setEraLegacyBridgeLastDepositTime(uint256 _eraLegacyBridgeLastDepositBatch, uint256 _eraLegacyBridgeLastDepositTxNumber) external
```

_This sets the first post upgrade batch for era, used to check old withdrawals_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _eraLegacyBridgeLastDepositBatch | uint256 | The the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge |
| _eraLegacyBridgeLastDepositTxNumber | uint256 | The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge |

### transferFundsFromLegacy

```solidity
function transferFundsFromLegacy(address _token, address _target, uint256 _targetChainId) external
```

_transfer tokens from legacy erc20 bridge or mailbox and set chainBalance as part of migration process_

### safeTransferFundsFromLegacy

```solidity
function safeTransferFundsFromLegacy(address _token, address _target, uint256 _targetChainId, uint256 _gasPerToken) external
```

_transfer tokens from legacy erc20 bridge or mailbox and set chainBalance as part of migration process.
Unlike `transferFundsFromLegacy` is provides a concrete limit on the gas used for the transfer and even if it will fail, it will not revert the whole transaction._

### receiveEth

```solidity
function receiveEth(uint256 _chainId) external payable
```

### initializeChainGovernance

```solidity
function initializeChainGovernance(uint256 _chainId, address _l2BridgeAddress) external
```

_Initializes the l2Bridge address by governance for a specific chain._

### bridgehubDepositBaseToken

```solidity
function bridgehubDepositBaseToken(uint256 _chainId, address _prevMsgSender, address _l1Token, uint256 _amount) external payable virtual
```

Allows bridgehub to acquire mintValue for L1->L2 transactions.

_If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2._

### _depositFunds

```solidity
function _depositFunds(address _from, contract IERC20 _token, uint256 _amount) internal returns (uint256)
```

_Transfers tokens from the depositor address to the smart contract address._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The difference between the contract balance before and after the transferring of funds. |

### bridgehubDeposit

```solidity
function bridgehubDeposit(uint256 _chainId, address _prevMsgSender, uint256 _l2Value, bytes _data) external payable returns (struct L2TransactionRequestTwoBridgesInner request)
```

Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.

### bridgehubConfirmL2Transaction

```solidity
function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external
```

Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.

### setL1Erc20Bridge

```solidity
function setL1Erc20Bridge(address _legacyBridge) external
```

_Sets the L1ERC20Bridge contract address. Should be called only once._

### _getDepositL2Calldata

```solidity
function _getDepositL2Calldata(address _l1Sender, address _l2Receiver, address _l1Token, uint256 _amount) internal view returns (bytes)
```

_Generate a calldata for calling the deposit finalization on the L2 bridge contract_

### _getERC20Getters

```solidity
function _getERC20Getters(address _token) internal view returns (bytes)
```

_Receives and parses (name, symbol, decimals) from the token contract_

### claimFailedDeposit

```solidity
function claimFailedDeposit(uint256 _chainId, address _depositSender, address _l1Token, uint256 _amount, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) external
```

_Withdraw funds from the initiated deposit, that failed when finalizing on L2_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 |  |
| _depositSender | address | The address of the deposit initiator |
| _l1Token | address | The address of the deposited L1 ERC20 token |
| _amount | uint256 | The amount of the deposit that failed. |
| _l2TxHash | bytes32 | The L2 transaction hash of the failed deposit finalization |
| _l2BatchNumber | uint256 | The L2 batch number where the deposit finalization was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in a batch, in which the log was sent |
| _merkleProof | bytes32[] | The Merkle proof of the processing L1 -> L2 transaction with deposit finalization |

### _claimFailedDeposit

```solidity
function _claimFailedDeposit(bool _checkedInLegacyBridge, uint256 _chainId, address _depositSender, address _l1Token, uint256 _amount, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) internal
```

_Processes claims of failed deposit, whether they originated from the legacy bridge or the current system._

### _isEraLegacyEthWithdrawal

```solidity
function _isEraLegacyEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool)
```

_Determines if an eth withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 | The chain ID of the transaction to check. |
| _l2BatchNumber | uint256 | The L2 batch number for the withdrawal. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether withdrawal was initiated on zkSync Era before diamond proxy upgrade. |

### _isEraLegacyTokenWithdrawal

```solidity
function _isEraLegacyTokenWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool)
```

_Determines if a token withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 | The chain ID of the transaction to check. |
| _l2BatchNumber | uint256 | The L2 batch number for the withdrawal. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether withdrawal was initiated on zkSync Era before Legacy Bridge upgrade. |

### _isEraLegacyDeposit

```solidity
function _isEraLegacyDeposit(uint256 _chainId, uint256 _l2BatchNumber, uint256 _l2TxNumberInBatch) internal view returns (bool)
```

_Determines if a deposit was initiated on zkSync Era before the upgrade to the Shared Bridge._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 | The chain ID of the transaction to check. |
| _l2BatchNumber | uint256 | The L2 batch number for the deposit where it was processed. |
| _l2TxNumberInBatch | uint256 | The L2 transaction number in the batch, in which the deposit was processed. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether deposit was initiated on zkSync Era before Shared Bridge upgrade. |

### finalizeWithdrawal

```solidity
function finalizeWithdrawal(uint256 _chainId, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external
```

Finalize the withdrawal and release funds

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 | The chain ID of the transaction to check |
| _l2BatchNumber | uint256 | The L2 batch number where the withdrawal was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in the batch, in which the log was sent |
| _message | bytes | The L2 withdraw data, stored in an L2 -> L1 message |
| _merkleProof | bytes32[] | The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization |

### MessageParams

```solidity
struct MessageParams {
  uint256 l2BatchNumber;
  uint256 l2MessageIndex;
  uint16 l2TxNumberInBatch;
}
```

### _finalizeWithdrawal

```solidity
function _finalizeWithdrawal(uint256 _chainId, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) internal returns (address l1Receiver, address l1Token, uint256 amount)
```

_Internal function that handles the logic for finalizing withdrawals,
serving both the current bridge system and the legacy ERC20 bridge._

### _checkWithdrawal

```solidity
function _checkWithdrawal(uint256 _chainId, struct L1SharedBridge.MessageParams _messageParams, bytes _message, bytes32[] _merkleProof) internal view returns (address l1Receiver, address l1Token, uint256 amount)
```

_Verifies the validity of a withdrawal message from L2 and returns details of the withdrawal._

### _parseL2WithdrawalMessage

```solidity
function _parseL2WithdrawalMessage(uint256 _chainId, bytes _l2ToL1message) internal view returns (address l1Receiver, address l1Token, uint256 amount)
```

### depositLegacyErc20Bridge

```solidity
function depositLegacyErc20Bridge(address _prevMsgSender, address _l2Receiver, address _l1Token, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte, address _refundRecipient) external payable returns (bytes32 l2TxHash)
```

Initiates a deposit by locking funds on the contract and sending the request
of processing an L2 transaction where tokens would be minted.

_If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
out of control.
- If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
- If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
be sent to the `msg.sender` address.
- If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
sent to the aliased `msg.sender` address.
The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
are controllable through the Mailbox, since the Mailbox applies address aliasing to the from address for the
L2 tx if the L1 msg.sender is a contract. Without address aliasing for L1 contracts as refund recipients they
would not be able to make proper L2 tx requests through the Mailbox to use or withdraw the funds from L2, and
the funds would be lost._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _prevMsgSender | address |  |
| _l2Receiver | address | The account address that should receive funds on L2 |
| _l1Token | address | The L1 token address which is deposited |
| _amount | uint256 | The total amount of tokens to be bridged |
| _l2TxGasLimit | uint256 | The L2 gas limit to be used in the corresponding L2 transaction |
| _l2TxGasPerPubdataByte | uint256 | The gasPerPubdataByteLimit to be used in the corresponding L2 transaction |
| _refundRecipient | address | The address on L2 that will receive the refund for the transaction. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| l2TxHash | bytes32 | The L2 transaction hash of deposit finalization. |

### finalizeWithdrawalLegacyErc20Bridge

```solidity
function finalizeWithdrawalLegacyErc20Bridge(uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external returns (address l1Receiver, address l1Token, uint256 amount)
```

Finalizes the withdrawal for transactions initiated via the legacy ERC20 bridge.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2BatchNumber | uint256 | The L2 batch number where the withdrawal was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in the batch, in which the log was sent |
| _message | bytes | The L2 withdraw data, stored in an L2 -> L1 message |
| _merkleProof | bytes32[] | The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization |

| Name | Type | Description |
| ---- | ---- | ----------- |
| l1Receiver | address | The address on L1 that will receive the withdrawn funds |
| l1Token | address | The address of the L1 token being withdrawn |
| amount | uint256 | The amount of the token being withdrawn |

### claimFailedDepositLegacyErc20Bridge

```solidity
function claimFailedDepositLegacyErc20Bridge(address _depositSender, address _l1Token, uint256 _amount, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) external
```

Withdraw funds from the initiated deposit, that failed when finalizing on zkSync Era chain.
This function is specifically designed for maintaining backward-compatibility with legacy `claimFailedDeposit`
method in `L1ERC20Bridge`.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _depositSender | address | The address of the deposit initiator |
| _l1Token | address | The address of the deposited L1 ERC20 token |
| _amount | uint256 | The amount of the deposit that failed. |
| _l2TxHash | bytes32 | The L2 transaction hash of the failed deposit finalization |
| _l2BatchNumber | uint256 | The L2 batch number where the deposit finalization was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in a batch, in which the log was sent |
| _merkleProof | bytes32[] | The Merkle proof of the processing L1 -> L2 transaction with deposit finalization |

### pause

```solidity
function pause() external
```

Pauses all functions marked with the `whenNotPaused` modifier.

### unpause

```solidity
function unpause() external
```

Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.

