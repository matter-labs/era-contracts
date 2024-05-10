## StateTransitionManagerInitializeData

Struct that holds all data needed for initializing STM Proxy.

_We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct StateTransitionManagerInitializeData {
  address owner;
  address validatorTimelock;
  address genesisUpgrade;
  bytes32 genesisBatchHash;
  uint64 genesisIndexRepeatedStorageChanges;
  bytes32 genesisBatchCommitment;
  struct Diamond.DiamondCutData diamondCut;
  uint256 protocolVersion;
}
```
## IStateTransitionManager

### NewHyperchain

```solidity
event NewHyperchain(uint256 _chainId, address _hyperchainContract)
```

_Emitted when a new Hyperchain is added_

### SetChainIdUpgrade

```solidity
event SetChainIdUpgrade(address _hyperchain, struct L2CanonicalTransaction _l2Transaction, uint256 _protocolVersion)
```

_emitted when an chain registers and a SetChainIdUpgrade happens_

### NewPendingAdmin

```solidity
event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin)
```

pendingAdmin is changed

_Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address_

### NewAdmin

```solidity
event NewAdmin(address oldAdmin, address newAdmin)
```

Admin changed

### NewValidatorTimelock

```solidity
event NewValidatorTimelock(address oldValidatorTimelock, address newValidatorTimelock)
```

ValidatorTimelock changed

### NewInitialCutHash

```solidity
event NewInitialCutHash(bytes32 oldInitialCutHash, bytes32 newInitialCutHash)
```

InitialCutHash changed

### NewUpgradeCutHash

```solidity
event NewUpgradeCutHash(uint256 protocolVersion, bytes32 upgradeCutHash)
```

new UpgradeCutHash

### NewProtocolVersion

```solidity
event NewProtocolVersion(uint256 oldProtocolVersion, uint256 newProtocolVersion)
```

new ProtocolVersion

### BRIDGE_HUB

```solidity
function BRIDGE_HUB() external view returns (address)
```

### setPendingAdmin

```solidity
function setPendingAdmin(address _newPendingAdmin) external
```

### acceptAdmin

```solidity
function acceptAdmin() external
```

### getAllHyperchains

```solidity
function getAllHyperchains() external view returns (address[])
```

### getAllHyperchainChainIDs

```solidity
function getAllHyperchainChainIDs() external view returns (uint256[])
```

### getHyperchain

```solidity
function getHyperchain(uint256 _chainId) external view returns (address)
```

### storedBatchZero

```solidity
function storedBatchZero() external view returns (bytes32)
```

### initialCutHash

```solidity
function initialCutHash() external view returns (bytes32)
```

### genesisUpgrade

```solidity
function genesisUpgrade() external view returns (address)
```

### upgradeCutHash

```solidity
function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32)
```

### protocolVersion

```solidity
function protocolVersion() external view returns (uint256)
```

### protocolVersionDeadline

```solidity
function protocolVersionDeadline(uint256 _protocolVersion) external view returns (uint256)
```

### protocolVersionIsActive

```solidity
function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool)
```

### initialize

```solidity
function initialize(struct StateTransitionManagerInitializeData _initializeData) external
```

### setInitialCutHash

```solidity
function setInitialCutHash(struct Diamond.DiamondCutData _diamondCut) external
```

### setValidatorTimelock

```solidity
function setValidatorTimelock(address _validatorTimelock) external
```

### getChainAdmin

```solidity
function getChainAdmin(uint256 _chainId) external view returns (address)
```

### createNewChain

```solidity
function createNewChain(uint256 _chainId, address _baseToken, address _sharedBridge, address _admin, bytes _diamondCut) external
```

### registerAlreadyDeployedHyperchain

```solidity
function registerAlreadyDeployedHyperchain(uint256 _chainId, address _hyperchain) external
```

### setNewVersionUpgrade

```solidity
function setNewVersionUpgrade(struct Diamond.DiamondCutData _cutData, uint256 _oldProtocolVersion, uint256 _oldprotocolVersionDeadline, uint256 _newProtocolVersion) external
```

### setUpgradeDiamondCut

```solidity
function setUpgradeDiamondCut(struct Diamond.DiamondCutData _cutData, uint256 _oldProtocolVersion) external
```

### executeUpgrade

```solidity
function executeUpgrade(uint256 _chainId, struct Diamond.DiamondCutData _diamondCut) external
```

### setPriorityTxMaxGasLimit

```solidity
function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external
```

### freezeChain

```solidity
function freezeChain(uint256 _chainId) external
```

### unfreezeChain

```solidity
function unfreezeChain(uint256 _chainId) external
```

### setTokenMultiplier

```solidity
function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external
```

### changeFeeParams

```solidity
function changeFeeParams(uint256 _chainId, struct FeeParams _newFeeParams) external
```

### setValidator

```solidity
function setValidator(uint256 _chainId, address _validator, bool _active) external
```

### setPorterAvailability

```solidity
function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external
```

### upgradeChainFromVersion

```solidity
function upgradeChainFromVersion(uint256 _chainId, uint256 _oldProtocolVersion, struct Diamond.DiamondCutData _diamondCut) external
```

