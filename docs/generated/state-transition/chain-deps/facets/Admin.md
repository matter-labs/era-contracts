## AdminFacet

### getName

```solidity
string getName
```

| Name | Type | Description |
| ---- | ---- | ----------- |

### setPendingAdmin

```solidity
function setPendingAdmin(address _newPendingAdmin) external
```

Starts the transfer of admin rights. Only the current admin can propose a new pending one.
New admin can accept admin rights by calling `acceptAdmin` function.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newPendingAdmin | address | Address of the new admin |

### acceptAdmin

```solidity
function acceptAdmin() external
```

Accepts transfer of admin rights. Only pending admin can accept the role.

### setValidator

```solidity
function setValidator(address _validator, bool _active) external
```

Change validator status (active or not active)

| Name | Type | Description |
| ---- | ---- | ----------- |
| _validator | address | Validator address |
| _active | bool | Active flag |

### setPorterAvailability

```solidity
function setPorterAvailability(bool _zkPorterIsAvailable) external
```

Change zk porter availability

| Name | Type | Description |
| ---- | ---- | ----------- |
| _zkPorterIsAvailable | bool | The availability of zk porter shard |

### setPriorityTxMaxGasLimit

```solidity
function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external
```

Change the max L2 gas limit for L1 -> L2 transactions

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newPriorityTxMaxGasLimit | uint256 | The maximum number of L2 gas that a user can request for L1 -> L2 transactions |

### changeFeeParams

```solidity
function changeFeeParams(struct FeeParams _newFeeParams) external
```

Change the fee params for L1->L2 transactions

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newFeeParams | struct FeeParams | The new fee params |

### setTokenMultiplier

```solidity
function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external
```

Change the token multiplier for L1->L2 transactions

### setPubdataPricingMode

```solidity
function setPubdataPricingMode(enum PubdataPricingMode _pricingMode) external
```

Change the pubdata pricing mode before the first batch is processed

| Name | Type | Description |
| ---- | ---- | ----------- |
| _pricingMode | enum PubdataPricingMode | The new pubdata pricing mode |

### setTransactionFilterer

```solidity
function setTransactionFilterer(address _transactionFilterer) external
```

Set the transaction filterer

### upgradeChainFromVersion

```solidity
function upgradeChainFromVersion(uint256 _oldProtocolVersion, struct Diamond.DiamondCutData _diamondCut) external
```

Perform the upgrade from the current protocol version with the corresponding upgrade data

| Name | Type | Description |
| ---- | ---- | ----------- |
| _oldProtocolVersion | uint256 |  |
| _diamondCut | struct Diamond.DiamondCutData |  |

### executeUpgrade

```solidity
function executeUpgrade(struct Diamond.DiamondCutData _diamondCut) external
```

Executes a proposed governor upgrade

_Only the current admin can execute the upgrade_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _diamondCut | struct Diamond.DiamondCutData | The diamond cut parameters to be executed |

### freezeDiamond

```solidity
function freezeDiamond() external
```

Instantly pause the functionality of all freezable facets & their selectors

_Only the governance mechanism may freeze Diamond Proxy_

### unfreezeDiamond

```solidity
function unfreezeDiamond() external
```

Unpause the functionality of all freezable facets & their selectors

_Both the admin and the STM can unfreeze Diamond Proxy_

