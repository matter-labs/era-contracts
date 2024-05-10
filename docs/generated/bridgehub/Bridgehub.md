## Bridgehub

### sharedBridge

```solidity
contract IL1SharedBridge sharedBridge
```

all the ether is held by the weth bridge

### stateTransitionManagerIsRegistered

```solidity
mapping(address => bool) stateTransitionManagerIsRegistered
```

we store registered stateTransitionManagers

### tokenIsRegistered

```solidity
mapping(address => bool) tokenIsRegistered
```

we store registered tokens (for arbitrary base token)

### stateTransitionManager

```solidity
mapping(uint256 => address) stateTransitionManager
```

chainID => StateTransitionManager contract address, storing StateTransitionManager

### baseToken

```solidity
mapping(uint256 => address) baseToken
```

chainID => baseToken contract address, storing baseToken

### admin

```solidity
address admin
```

_used to manage non critical updates_

### constructor

```solidity
constructor() public
```

to avoid parity hack

### initialize

```solidity
function initialize(address _owner) external
```

used to initialize the contract

### onlyOwnerOrAdmin

```solidity
modifier onlyOwnerOrAdmin()
```

### setPendingAdmin

```solidity
function setPendingAdmin(address _newPendingAdmin) external
```

Starts the transfer of admin rights. Only the current admin can propose a new pending one.
New admin can accept admin rights by calling `acceptAdmin` function.

_Please note, if the owner wants to enforce the admin change it must execute both `setPendingAdmin` and
`acceptAdmin` atomically. Otherwise `admin` can set different pending admin and so fail to accept the admin rights._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newPendingAdmin | address | Address of the new admin |

### acceptAdmin

```solidity
function acceptAdmin() external
```

Accepts transfer of admin rights. Only pending admin can accept the role.

### getHyperchain

```solidity
function getHyperchain(uint256 _chainId) public view returns (address)
```

return the state transition chain contract for a chainId

### addStateTransitionManager

```solidity
function addStateTransitionManager(address _stateTransitionManager) external
```

State Transition can be any contract with the appropriate interface/functionality

### removeStateTransitionManager

```solidity
function removeStateTransitionManager(address _stateTransitionManager) external
```

State Transition can be any contract with the appropriate interface/functionality
this stops new Chains from using the STF, old chains are not affected

### addToken

```solidity
function addToken(address _token) external
```

token can be any contract with the appropriate interface/functionality

### setSharedBridge

```solidity
function setSharedBridge(address _sharedBridge) external
```

To set shared bridge, only Owner. Not done in initialize, as
the order of deployment is Bridgehub, Shared bridge, and then we call this

### createNewChain

```solidity
function createNewChain(uint256 _chainId, address _stateTransitionManager, address _baseToken, uint256 _salt, address _admin, bytes _initData) external returns (uint256)
```

register new chain
for Eth the baseToken address is 1

### proveL2MessageInclusion

```solidity
function proveL2MessageInclusion(uint256 _chainId, uint256 _batchNumber, uint256 _index, struct L2Message _message, bytes32[] _proof) external view returns (bool)
```

forwards function call to Mailbox based on ChainId

### proveL2LogInclusion

```solidity
function proveL2LogInclusion(uint256 _chainId, uint256 _batchNumber, uint256 _index, struct L2Log _log, bytes32[] _proof) external view returns (bool)
```

forwards function call to Mailbox based on ChainId

### proveL1ToL2TransactionStatus

```solidity
function proveL1ToL2TransactionStatus(uint256 _chainId, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof, enum TxStatus _status) external view returns (bool)
```

forwards function call to Mailbox based on ChainId

### l2TransactionBaseCost

```solidity
function l2TransactionBaseCost(uint256 _chainId, uint256 _gasPrice, uint256 _l2GasLimit, uint256 _l2GasPerPubdataByteLimit) external view returns (uint256)
```

forwards function call to Mailbox based on ChainId

### requestL2TransactionDirect

```solidity
function requestL2TransactionDirect(struct L2TransactionRequestDirect _request) external payable returns (bytes32 canonicalTxHash)
```

the mailbox is called directly after the sharedBridge received the deposit
this assumes that either ether is the base token or
the msg.sender has approved mintValue allowance for the sharedBridge.
This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token

### requestL2TransactionTwoBridges

```solidity
function requestL2TransactionTwoBridges(struct L2TransactionRequestTwoBridgesOuter _request) external payable returns (bytes32 canonicalTxHash)
```

After depositing funds to the sharedBridge, the secondBridge is called
 to return the actual L2 message which is sent to the Mailbox.
 This assumes that either ether is the base token or
 the msg.sender has approved the sharedBridge with the mintValue,
 and also the necessary approvals are given for the second bridge.
The logic of this bridge is to allow easy depositing for bridges.
Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
the user to approve for each token only its respective bridge
This function is great for contract calls to L2, the secondBridge can be any contract.

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

