## ProposedUpgrade

The struct that represents the upgrade proposal.

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct ProposedUpgrade {
  struct L2CanonicalTransaction l2ProtocolUpgradeTx;
  bytes[] factoryDeps;
  bytes32 bootloaderHash;
  bytes32 defaultAccountHash;
  address verifier;
  struct VerifierParams verifierParams;
  bytes l1ContractsUpgradeCalldata;
  bytes postUpgradeCalldata;
  uint256 upgradeTimestamp;
  uint256 newProtocolVersion;
}
```
## BaseZkSyncUpgrade

Interface to which all the upgrade implementations should adhere

### NewProtocolVersion

```solidity
event NewProtocolVersion(uint256 previousProtocolVersion, uint256 newProtocolVersion)
```

Changes the protocol version

### NewL2BootloaderBytecodeHash

```solidity
event NewL2BootloaderBytecodeHash(bytes32 previousBytecodeHash, bytes32 newBytecodeHash)
```

Сhanges to the bytecode that is used in L2 as a bootloader (start program)

### NewL2DefaultAccountBytecodeHash

```solidity
event NewL2DefaultAccountBytecodeHash(bytes32 previousBytecodeHash, bytes32 newBytecodeHash)
```

Сhanges to the bytecode that is used in L2 as a default account

### NewVerifier

```solidity
event NewVerifier(address oldVerifier, address newVerifier)
```

Verifier address changed

### NewVerifierParams

```solidity
event NewVerifierParams(struct VerifierParams oldVerifierParams, struct VerifierParams newVerifierParams)
```

Verifier parameters changed

### UpgradeComplete

```solidity
event UpgradeComplete(uint256 newProtocolVersion, bytes32 l2UpgradeTxHash, struct ProposedUpgrade upgrade)
```

Notifies about complete upgrade

### upgrade

```solidity
function upgrade(struct ProposedUpgrade _proposedUpgrade) public virtual returns (bytes32 txHash)
```

The main function that will be provided by the upgrade proxy

_This is a virtual function and should be overridden by custom upgrade implementations._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _proposedUpgrade | struct ProposedUpgrade | The upgrade to be executed. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| txHash | bytes32 | The hash of the L2 system contract upgrade transaction. |

### _upgradeVerifier

```solidity
function _upgradeVerifier(address _newVerifier, struct VerifierParams _verifierParams) internal
```

Updates the verifier and the verifier params

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newVerifier | address | The address of the new verifier. If 0, the verifier will not be updated. |
| _verifierParams | struct VerifierParams | The new verifier params. If all of the fields are 0, the params will not be updated. |

### _setBaseSystemContracts

```solidity
function _setBaseSystemContracts(bytes32 _bootloaderHash, bytes32 _defaultAccountHash) internal
```

Updates the bootloader hash and the hash of the default account

| Name | Type | Description |
| ---- | ---- | ----------- |
| _bootloaderHash | bytes32 | The hash of the new bootloader bytecode. If zero, it will not be updated. |
| _defaultAccountHash | bytes32 | The hash of the new default account bytecode. If zero, it will not be updated. |

### _setL2SystemContractUpgrade

```solidity
function _setL2SystemContractUpgrade(struct L2CanonicalTransaction _l2ProtocolUpgradeTx, bytes[] _factoryDeps, uint256 _newProtocolVersion) internal returns (bytes32)
```

Sets the hash of the L2 system contract upgrade transaction for the next batch to be committed

_If the transaction is noop (i.e. its type is 0) it does nothing and returns 0._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2ProtocolUpgradeTx | struct L2CanonicalTransaction | The L2 system contract upgrade transaction. |
| _factoryDeps | bytes[] |  |
| _newProtocolVersion | uint256 |  |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | System contracts upgrade transaction hash. Zero if no upgrade transaction is set. |

### _setNewProtocolVersion

```solidity
function _setNewProtocolVersion(uint256 _newProtocolVersion) internal virtual
```

Changes the protocol version

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newProtocolVersion | uint256 | The new protocol version |

### _upgradeL1Contract

```solidity
function _upgradeL1Contract(bytes _customCallDataForUpgrade) internal virtual
```

Placeholder function for custom logic for upgrading L1 contract.
Typically this function will never be used.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _customCallDataForUpgrade | bytes | Custom data for an upgrade, which may be interpreted differently for each upgrade. |

### _postUpgrade

```solidity
function _postUpgrade(bytes _customCallDataForUpgrade) internal virtual
```

placeholder function for custom logic for post-upgrade logic.
Typically this function will never be used.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _customCallDataForUpgrade | bytes | Custom data for an upgrade, which may be interpreted differently for each upgrade. |

