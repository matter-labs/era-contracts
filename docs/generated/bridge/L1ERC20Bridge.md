## L1ERC20Bridge

Smart contract that allows depositing ERC20 tokens from Ethereum to hyperchains

_It is a legacy bridge from zkSync Era, that was deprecated in favour of shared bridge.
It is needed for backward compatibility with already integrated projects._

### SHARED_BRIDGE

```solidity
contract IL1SharedBridge SHARED_BRIDGE
```

_The shared bridge that is now used for all bridging, replacing the legacy contract._

### isWithdrawalFinalized

```solidity
mapping(uint256 => mapping(uint256 => bool)) isWithdrawalFinalized
```

_A mapping L2 batch number => message number => flag.
Used to indicate that L2 -> L1 message was already processed for zkSync Era withdrawals._

### depositAmount

```solidity
mapping(address => mapping(address => mapping(bytes32 => uint256))) depositAmount
```

_A mapping account => L1 token address => L2 deposit transaction hash => amount.
Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail in zkSync Era._

### l2Bridge

```solidity
address l2Bridge
```

_The address that is used as a L2 bridge counterpart in zkSync Era._

### l2TokenBeacon

```solidity
address l2TokenBeacon
```

_The address that is used as a beacon for L2 tokens in zkSync Era._

### l2TokenProxyBytecodeHash

```solidity
bytes32 l2TokenProxyBytecodeHash
```

_Stores the hash of the L2 token proxy contract's bytecode on zkSync Era._

### constructor

```solidity
constructor(contract IL1SharedBridge _sharedBridge) public
```

_Contract is expected to be used as proxy implementation.
Initialize the implementation to prevent Parity hack._

### initialize

```solidity
function initialize() external
```

_Initializes the reentrancy guard. Expected to be used in the proxy._

### transferTokenToSharedBridge

```solidity
function transferTokenToSharedBridge(address _token) external
```

_transfer token to shared bridge as part of upgrade_

### l2TokenAddress

```solidity
function l2TokenAddress(address _l1Token) external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The L2 token address that would be minted for deposit of the given L1 token on zkSync Era. |

### deposit

```solidity
function deposit(address _l2Receiver, address _l1Token, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte) external payable returns (bytes32 l2TxHash)
```

Legacy deposit method with refunding the fee to the caller, use another `deposit` method instead.

_Initiates a deposit by locking funds on the contract and sending the request
of processing an L2 transaction where tokens would be minted.
If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2Receiver | address | The account address that should receive funds on L2 |
| _l1Token | address | The L1 token address which is deposited |
| _amount | uint256 | The total amount of tokens to be bridged |
| _l2TxGasLimit | uint256 | The L2 gas limit to be used in the corresponding L2 transaction |
| _l2TxGasPerPubdataByte | uint256 | The gasPerPubdataByteLimit to be used in the corresponding L2 transaction |

| Name | Type | Description |
| ---- | ---- | ----------- |
| l2TxHash | bytes32 | The L2 transaction hash of deposit finalization NOTE: the function doesn't use `nonreentrant` modifier, because the inner method does. |

### deposit

```solidity
function deposit(address _l2Receiver, address _l1Token, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte, address _refundRecipient) public payable returns (bytes32 l2TxHash)
```

Initiates a deposit by locking funds on the contract and sending the request

_Initiates a deposit by locking funds on the contract and sending the request
of processing an L2 transaction where tokens would be minted
If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
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
| _l2Receiver | address | The account address that should receive funds on L2 |
| _l1Token | address | The L1 token address which is deposited |
| _amount | uint256 | The total amount of tokens to be bridged |
| _l2TxGasLimit | uint256 | The L2 gas limit to be used in the corresponding L2 transaction |
| _l2TxGasPerPubdataByte | uint256 | The gasPerPubdataByteLimit to be used in the corresponding L2 transaction |
| _refundRecipient | address | The address on L2 that will receive the refund for the transaction. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| l2TxHash | bytes32 | The L2 transaction hash of deposit finalization |

### _depositFundsToSharedBridge

```solidity
function _depositFundsToSharedBridge(address _from, contract IERC20 _token, uint256 _amount) internal returns (uint256)
```

_Transfers tokens from the depositor address to the shared bridge address._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The difference between the contract balance before and after the transferring of funds. |

### claimFailedDeposit

```solidity
function claimFailedDeposit(address _depositSender, address _l1Token, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) external
```

_Withdraw funds from the initiated deposit, that failed when finalizing on L2._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _depositSender | address | The address of the deposit initiator |
| _l1Token | address | The address of the deposited L1 ERC20 token |
| _l2TxHash | bytes32 | The L2 transaction hash of the failed deposit finalization |
| _l2BatchNumber | uint256 | The L2 batch number where the deposit finalization was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in a batch, in which the log was sent |
| _merkleProof | bytes32[] | The Merkle proof of the processing L1 -> L2 transaction with deposit finalization |

### finalizeWithdrawal

```solidity
function finalizeWithdrawal(uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external
```

Finalize the withdrawal and release funds

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2BatchNumber | uint256 | The L2 batch number where the withdrawal was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in the batch, in which the log was sent |
| _message | bytes | The L2 withdraw data, stored in an L2 -> L1 message |
| _merkleProof | bytes32[] | The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization |

