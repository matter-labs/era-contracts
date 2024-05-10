## Upgrade_v1_4_1

### PRIORITY_TX_BATCH_OVERHEAD_L1_GAS

```solidity
uint32 PRIORITY_TX_BATCH_OVERHEAD_L1_GAS
```

### PRIORITY_TX_PUBDATA_PER_BATCH

```solidity
uint32 PRIORITY_TX_PUBDATA_PER_BATCH
```

### PRIORITY_TX_MAX_GAS_PER_BATCH

```solidity
uint32 PRIORITY_TX_MAX_GAS_PER_BATCH
```

### PRIORITY_TX_MAX_PUBDATA

```solidity
uint32 PRIORITY_TX_MAX_PUBDATA
```

### PRIORITY_TX_MINIMAL_GAS_PRICE

```solidity
uint64 PRIORITY_TX_MINIMAL_GAS_PRICE
```

### NewFeeParams

```solidity
event NewFeeParams(struct FeeParams oldFeeParams, struct FeeParams newFeeParams)
```

This event is an exact copy of the "IAdmin.NewFeeParams" event. Since they have the same name and parameters,
these will be tracked by indexers in the same manner.

### upgrade

```solidity
function upgrade(struct ProposedUpgrade _proposedUpgrade) public returns (bytes32)
```

The main function that will be called by the upgrade proxy.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _proposedUpgrade | struct ProposedUpgrade | The upgrade to be executed. |

