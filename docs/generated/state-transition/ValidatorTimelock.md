## ValidatorTimelock

Intermediate smart contract between the validator EOA account and the hyperchains state transition diamond smart contract.

_The primary purpose of this contract is to provide a trustless means of delaying batch execution without
modifying the main hyperchain diamond contract. As such, even if this contract is compromised, it will not impact the main
contract.
zkSync actively monitors the chain activity and reacts to any suspicious activity by freezing the chain.
This allows time for investigation and mitigation before resuming normal operations.
The contract overloads all of the 4 methods, that are used in state transition. When the batch is committed,
the timestamp is stored for it. Later, when the owner calls the batch execution, the contract checks that batch
was committed not earlier than X time ago._

### getName

```solidity
string getName
```

_Part of the IBase interface. Not used in this contract._

### NewExecutionDelay

```solidity
event NewExecutionDelay(uint256 _newExecutionDelay)
```

The delay between committing and executing batches is changed.

### ValidatorAdded

```solidity
event ValidatorAdded(uint256 _chainId, address _addedValidator)
```

A new validator has been added.

### ValidatorRemoved

```solidity
event ValidatorRemoved(uint256 _chainId, address _removedValidator)
```

A validator has been removed.

### AddressAlreadyValidator

```solidity
error AddressAlreadyValidator(uint256 _chainId)
```

Error for when an address is already a validator.

### ValidatorDoesNotExist

```solidity
error ValidatorDoesNotExist(uint256 _chainId)
```

Error for when an address is not a validator.

### stateTransitionManager

```solidity
contract IStateTransitionManager stateTransitionManager
```

_The stateTransitionManager smart contract._

### committedBatchTimestamp

```solidity
mapping(uint256 => struct LibMap.Uint32Map) committedBatchTimestamp
```

_The mapping of L2 chainId => batch number => timestamp when it was committed._

### validators

```solidity
mapping(uint256 => mapping(address => bool)) validators
```

_The address that can commit/revert/validate/execute batches._

### executionDelay

```solidity
uint32 executionDelay
```

_The delay between committing and executing batches._

### ERA_CHAIN_ID

```solidity
uint256 ERA_CHAIN_ID
```

_Era's chainID_

### constructor

```solidity
constructor(address _initialOwner, uint32 _executionDelay, uint256 _eraChainId) public
```

### onlyChainAdmin

```solidity
modifier onlyChainAdmin(uint256 _chainId)
```

Checks if the caller is the admin of the chain.

### onlyValidator

```solidity
modifier onlyValidator(uint256 _chainId)
```

Checks if the caller is a validator.

### setStateTransitionManager

```solidity
function setStateTransitionManager(contract IStateTransitionManager _stateTransitionManager) external
```

_Sets a new state transition manager._

### addValidator

```solidity
function addValidator(uint256 _chainId, address _newValidator) external
```

_Sets an address as a validator._

### removeValidator

```solidity
function removeValidator(uint256 _chainId, address _validator) external
```

_Removes an address as a validator._

### setExecutionDelay

```solidity
function setExecutionDelay(uint32 _executionDelay) external
```

_Set the delay between committing and executing batches._

### getCommittedBatchTimestamp

```solidity
function getCommittedBatchTimestamp(uint256 _chainId, uint256 _l2BatchNumber) external view returns (uint256)
```

_Returns the timestamp when `_l2BatchNumber` was committed._

### commitBatches

```solidity
function commitBatches(struct IExecutor.StoredBatchInfo, struct IExecutor.CommitBatchInfo[] _newBatchesData) external
```

_Records the timestamp for all provided committed batches and make
a call to the hyperchain diamond contract with the same calldata._

### commitBatchesSharedBridge

```solidity
function commitBatchesSharedBridge(uint256 _chainId, struct IExecutor.StoredBatchInfo, struct IExecutor.CommitBatchInfo[] _newBatchesData) external
```

_Records the timestamp for all provided committed batches and make
a call to the hyperchain diamond contract with the same calldata._

### _commitBatchesInner

```solidity
function _commitBatchesInner(uint256 _chainId, struct IExecutor.CommitBatchInfo[] _newBatchesData) internal
```

### revertBatches

```solidity
function revertBatches(uint256) external
```

_Make a call to the hyperchain diamond contract with the same calldata.
Note: If the batch is reverted, it needs to be committed first before the execution.
So it's safe to not override the committed batches._

### revertBatchesSharedBridge

```solidity
function revertBatchesSharedBridge(uint256 _chainId, uint256) external
```

_Make a call to the hyperchain diamond contract with the same calldata.
Note: If the batch is reverted, it needs to be committed first before the execution.
So it's safe to not override the committed batches._

### proveBatches

```solidity
function proveBatches(struct IExecutor.StoredBatchInfo, struct IExecutor.StoredBatchInfo[], struct IExecutor.ProofInput) external
```

_Make a call to the hyperchain diamond contract with the same calldata.
Note: We don't track the time when batches are proven, since all information about
the batch is known on the commit stage and the proved is not finalized (may be reverted)._

### proveBatchesSharedBridge

```solidity
function proveBatchesSharedBridge(uint256 _chainId, struct IExecutor.StoredBatchInfo, struct IExecutor.StoredBatchInfo[], struct IExecutor.ProofInput) external
```

_Make a call to the hyperchain diamond contract with the same calldata.
Note: We don't track the time when batches are proven, since all information about
the batch is known on the commit stage and the proved is not finalized (may be reverted)._

### executeBatches

```solidity
function executeBatches(struct IExecutor.StoredBatchInfo[] _newBatchesData) external
```

_Check that batches were committed at least X time ago and
make a call to the hyperchain diamond contract with the same calldata._

### executeBatchesSharedBridge

```solidity
function executeBatchesSharedBridge(uint256 _chainId, struct IExecutor.StoredBatchInfo[] _newBatchesData) external
```

_Check that batches were committed at least X time ago and
make a call to the hyperchain diamond contract with the same calldata._

### _executeBatchesInner

```solidity
function _executeBatchesInner(uint256 _chainId, struct IExecutor.StoredBatchInfo[] _newBatchesData) internal
```

### _propagateToZkSyncHyperchain

```solidity
function _propagateToZkSyncHyperchain(uint256 _chainId) internal
```

_Call the hyperchain diamond contract with the same calldata as this contract was called.
Note: it is called the hyperchain diamond contract, not delegatecalled!_

