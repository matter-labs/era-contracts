## IGovernance

### OperationState

_This enumeration includes the following states:_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
enum OperationState {
  Unset,
  Waiting,
  Ready,
  Done
}
```

### Call

_Represents a call to be made during an operation._

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct Call {
  address target;
  uint256 value;
  bytes data;
}
```

### Operation

_Defines the structure of an operation that Governance executes._

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct Operation {
  struct IGovernance.Call[] calls;
  bytes32 predecessor;
  bytes32 salt;
}
```

### isOperation

```solidity
function isOperation(bytes32 _id) external view returns (bool)
```

### isOperationPending

```solidity
function isOperationPending(bytes32 _id) external view returns (bool)
```

### isOperationReady

```solidity
function isOperationReady(bytes32 _id) external view returns (bool)
```

### isOperationDone

```solidity
function isOperationDone(bytes32 _id) external view returns (bool)
```

### getOperationState

```solidity
function getOperationState(bytes32 _id) external view returns (enum IGovernance.OperationState)
```

### scheduleTransparent

```solidity
function scheduleTransparent(struct IGovernance.Operation _operation, uint256 _delay) external
```

### scheduleShadow

```solidity
function scheduleShadow(bytes32 _id, uint256 _delay) external
```

### cancel

```solidity
function cancel(bytes32 _id) external
```

### execute

```solidity
function execute(struct IGovernance.Operation _operation) external payable
```

### executeInstant

```solidity
function executeInstant(struct IGovernance.Operation _operation) external payable
```

### hashOperation

```solidity
function hashOperation(struct IGovernance.Operation _operation) external pure returns (bytes32)
```

### updateDelay

```solidity
function updateDelay(uint256 _newDelay) external
```

### updateSecurityCouncil

```solidity
function updateSecurityCouncil(address _newSecurityCouncil) external
```

### TransparentOperationScheduled

```solidity
event TransparentOperationScheduled(bytes32 _id, uint256 delay, struct IGovernance.Operation _operation)
```

Emitted when transparent operation is scheduled.

### ShadowOperationScheduled

```solidity
event ShadowOperationScheduled(bytes32 _id, uint256 delay)
```

Emitted when shadow operation is scheduled.

### OperationExecuted

```solidity
event OperationExecuted(bytes32 _id)
```

Emitted when the operation is executed with delay or instantly.

### ChangeSecurityCouncil

```solidity
event ChangeSecurityCouncil(address _securityCouncilBefore, address _securityCouncilAfter)
```

Emitted when the security council address is changed.

### ChangeMinDelay

```solidity
event ChangeMinDelay(uint256 _delayBefore, uint256 _delayAfter)
```

Emitted when the minimum delay for future operations is modified.

### OperationCancelled

```solidity
event OperationCancelled(bytes32 _id)
```

Emitted when the operation with specified id is cancelled.

