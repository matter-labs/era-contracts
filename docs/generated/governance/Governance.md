## Governance

This contract manages operations (calls with preconditions) for governance tasks.
The contract allows for operations to be scheduled, executed, and canceled with
appropriate permissions and delays. It is used for managing and coordinating upgrades
and changes in all zkSync hyperchain governed contracts.

Operations can be proposed as either fully transparent upgrades with on-chain data,
or "shadow" upgrades where upgrade data is not published on-chain before execution. Proposed operations
are subject to a delay before they can be executed, but they can be executed instantly
with the security council’s permission.

_Contract design is inspired by OpenZeppelin TimelockController and in-house Diamond Proxy upgrade mechanism._

### EXECUTED_PROPOSAL_TIMESTAMP

```solidity
uint256 EXECUTED_PROPOSAL_TIMESTAMP
```

A constant representing the timestamp for completed operations.

### securityCouncil

```solidity
address securityCouncil
```

The address of the security council.

_It is supposed to be multisig contract._

### timestamps

```solidity
mapping(bytes32 => uint256) timestamps
```

A mapping to store timestamps when each operation will be ready for execution.

_- 0 means the operation is not created.
- 1 (EXECUTED_PROPOSAL_TIMESTAMP) means the operation is already executed.
- any other value means timestamp in seconds when the operation will be ready for execution._

### minDelay

```solidity
uint256 minDelay
```

The minimum delay in seconds for operations to be ready for execution.

### constructor

```solidity
constructor(address _admin, address _securityCouncil, uint256 _minDelay) public
```

Initializes the contract with the admin address, security council address, and minimum delay.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _admin | address | The address to be assigned as the admin of the contract. |
| _securityCouncil | address | The address to be assigned as the security council of the contract. |
| _minDelay | uint256 | The initial minimum delay (in seconds) to be set for operations. |

### onlySelf

```solidity
modifier onlySelf()
```

Checks that the message sender is contract itself.

### onlySecurityCouncil

```solidity
modifier onlySecurityCouncil()
```

Checks that the message sender is an active security council.

### onlyOwnerOrSecurityCouncil

```solidity
modifier onlyOwnerOrSecurityCouncil()
```

Checks that the message sender is an active owner or an active security council.

### isOperation

```solidity
function isOperation(bytes32 _id) public view returns (bool)
```

_Returns whether an id corresponds to a registered operation. This
includes Waiting, Ready, and Done operations._

### isOperationPending

```solidity
function isOperationPending(bytes32 _id) public view returns (bool)
```

_Returns whether an operation is pending or not. Note that a "pending" operation may also be "ready"._

### isOperationReady

```solidity
function isOperationReady(bytes32 _id) public view returns (bool)
```

_Returns whether an operation is ready for execution. Note that a "ready" operation is also "pending"._

### isOperationDone

```solidity
function isOperationDone(bytes32 _id) public view returns (bool)
```

_Returns whether an operation is done or not._

### getOperationState

```solidity
function getOperationState(bytes32 _id) public view returns (enum IGovernance.OperationState)
```

_Returns operation state._

### scheduleTransparent

```solidity
function scheduleTransparent(struct IGovernance.Operation _operation, uint256 _delay) external
```

Propose a fully transparent upgrade, providing upgrade data on-chain.
The owner will be able to execute the proposal either:
- With a `delay` timelock on its own.
- With security council instantly.

_Only the current owner can propose an upgrade._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _operation | struct IGovernance.Operation | The operation parameters will be executed with the upgrade. |
| _delay | uint256 | The delay time (in seconds) after which the proposed upgrade can be executed by the owner. |

### scheduleShadow

```solidity
function scheduleShadow(bytes32 _id, uint256 _delay) external
```

Propose "shadow" upgrade, upgrade data is not publishing on-chain.
The owner will be able to execute the proposal either:
- With a `delay` timelock on its own.
- With security council instantly.

_Only the current owner can propose an upgrade._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _id | bytes32 | The operation hash (see `hashOperation` function) |
| _delay | uint256 | The delay time (in seconds) after which the proposed upgrade may be executed by the owner. |

### cancel

```solidity
function cancel(bytes32 _id) external
```

_Cancel the scheduled operation.
Only owner can call this function._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _id | bytes32 | Proposal id value (see `hashOperation`) |

### execute

```solidity
function execute(struct IGovernance.Operation _operation) external payable
```

Executes the scheduled operation after the delay passed.

_Both the owner and security council may execute delayed operations._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _operation | struct IGovernance.Operation | The operation parameters will be executed with the upgrade. |

### executeInstant

```solidity
function executeInstant(struct IGovernance.Operation _operation) external payable
```

Executes the scheduled operation with the security council instantly.

_Only the security council may execute an operation instantly._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _operation | struct IGovernance.Operation | The operation parameters will be executed with the upgrade. |

### hashOperation

```solidity
function hashOperation(struct IGovernance.Operation _operation) public pure returns (bytes32)
```

_Returns the identifier of an operation._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _operation | struct IGovernance.Operation | The operation object to compute the identifier for. |

### _schedule

```solidity
function _schedule(bytes32 _id, uint256 _delay) internal
```

_Schedule an operation that is to become valid after a given delay._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _id | bytes32 | The operation hash (see `hashOperation` function) |
| _delay | uint256 | The delay time (in seconds) after which the proposed upgrade can be executed by the owner. |

### _execute

```solidity
function _execute(struct IGovernance.Call[] _calls) internal
```

_Execute an operation's calls._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _calls | struct IGovernance.Call[] | The array of calls to be executed. |

### _checkPredecessorDone

```solidity
function _checkPredecessorDone(bytes32 _predecessorId) internal view
```

Verifies if the predecessor operation is completed.

_Doesn't check the operation to be complete if the input is zero._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _predecessorId | bytes32 | The hash of the operation that should be completed. |

### updateDelay

```solidity
function updateDelay(uint256 _newDelay) external
```

_Changes the minimum timelock duration for future operations._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newDelay | uint256 | The new minimum delay time (in seconds) for future operations. |

### updateSecurityCouncil

```solidity
function updateSecurityCouncil(address _newSecurityCouncil) external
```

_Updates the address of the security council._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newSecurityCouncil | address | The address of the new security council. |

### receive

```solidity
receive() external payable
```

_Contract might receive/hold ETH as part of the maintenance process._

