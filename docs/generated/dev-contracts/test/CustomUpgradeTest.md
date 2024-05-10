## CustomUpgradeTest

### test

```solidity
function test() internal virtual
```

### Test

```solidity
event Test()
```

### _upgradeL1Contract

```solidity
function _upgradeL1Contract(bytes _customCallDataForUpgrade) internal
```

Placeholder function for custom logic for upgrading L1 contract.
Typically this function will never be used.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _customCallDataForUpgrade | bytes | Custom data for upgrade, which may be interpreted differently for each upgrade. |

### _postUpgrade

```solidity
function _postUpgrade(bytes _customCallDataForUpgrade) internal
```

placeholder function for custom logic for post-upgrade logic.
Typically this function will never be used.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _customCallDataForUpgrade | bytes | Custom data for an upgrade, which may be interpreted differently for each upgrade. |

### upgrade

```solidity
function upgrade(struct ProposedUpgrade _proposedUpgrade) public returns (bytes32)
```

The main function that will be called by the upgrade proxy.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _proposedUpgrade | struct ProposedUpgrade | The upgrade to be executed. |

