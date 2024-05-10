## StateTransitionManager

### BRIDGE_HUB

```solidity
address BRIDGE_HUB
```

Address of the bridgehub

### MAX_NUMBER_OF_HYPERCHAINS

```solidity
uint256 MAX_NUMBER_OF_HYPERCHAINS
```

The total number of hyperchains can be created/connected to this STM.
This is the temporary security measure.

### hyperchainMap

```solidity
struct EnumerableMap.UintToAddressMap hyperchainMap
```

The map from chainId => hyperchain contract

### storedBatchZero

```solidity
bytes32 storedBatchZero
```

_The batch zero hash, calculated at initialization_

### initialCutHash

```solidity
bytes32 initialCutHash
```

_The stored cutData for diamond cut_

### genesisUpgrade

```solidity
address genesisUpgrade
```

_The genesisUpgrade contract address, used to setChainId_

### protocolVersion

```solidity
uint256 protocolVersion
```

_The current protocolVersion_

### protocolVersionDeadline

```solidity
mapping(uint256 => uint256) protocolVersionDeadline
```

_The timestamp when protocolVersion can be last used_

### validatorTimelock

```solidity
address validatorTimelock
```

_The validatorTimelock contract address, used to setChainId_

### upgradeCutHash

```solidity
mapping(uint256 => bytes32) upgradeCutHash
```

_The stored cutData for upgrade diamond cut. protocolVersion => cutHash_

### admin

```solidity
address admin
```

_The address used to manage non critical updates_

### constructor

```solidity
constructor(address _bridgehub, uint256 _maxNumberOfHyperchains) public
```

_Contract is expected to be used as proxy implementation.
Initialize the implementation to prevent Parity hack._

### onlyBridgehub

```solidity
modifier onlyBridgehub()
```

only the bridgehub can call

### onlyOwnerOrAdmin

```solidity
modifier onlyOwnerOrAdmin()
```

the admin can call, for non-critical updates

### getAllHyperchains

```solidity
function getAllHyperchains() public view returns (address[] chainAddresses)
```

Returns all the registered hyperchain addresses

### getAllHyperchainChainIDs

```solidity
function getAllHyperchainChainIDs() public view returns (uint256[])
```

Returns all the registered hyperchain chainIDs

### getHyperchain

```solidity
function getHyperchain(uint256 _chainId) public view returns (address chainAddress)
```

Returns the address of the hyperchain with the corresponding chainID

### getChainAdmin

```solidity
function getChainAdmin(uint256 _chainId) external view returns (address)
```

Returns the address of the hyperchain admin with the corresponding chainID

### initialize

```solidity
function initialize(struct StateTransitionManagerInitializeData _initializeData) external
```

_initialize_

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

### setValidatorTimelock

```solidity
function setValidatorTimelock(address _validatorTimelock) external
```

_set validatorTimelock. Cannot do it during initialization, as validatorTimelock is deployed after STM_

### setInitialCutHash

```solidity
function setInitialCutHash(struct Diamond.DiamondCutData _diamondCut) external
```

_set initial cutHash_

### setNewVersionUpgrade

```solidity
function setNewVersionUpgrade(struct Diamond.DiamondCutData _cutData, uint256 _oldProtocolVersion, uint256 _oldProtocolVersionDeadline, uint256 _newProtocolVersion) external
```

_set New Version with upgrade from old version_

### protocolVersionIsActive

```solidity
function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool)
```

_check that the protocolVersion is active_

### setProtocolVersionDeadline

```solidity
function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external
```

_set the protocol version timestamp_

### setUpgradeDiamondCut

```solidity
function setUpgradeDiamondCut(struct Diamond.DiamondCutData _cutData, uint256 _oldProtocolVersion) external
```

_set upgrade for some protocolVersion_

### freezeChain

```solidity
function freezeChain(uint256 _chainId) external
```

_freezes the specified chain_

### unfreezeChain

```solidity
function unfreezeChain(uint256 _chainId) external
```

_freezes the specified chain_

### revertBatches

```solidity
function revertBatches(uint256 _chainId, uint256 _newLastBatch) external
```

_reverts batches on the specified chain_

### upgradeChainFromVersion

```solidity
function upgradeChainFromVersion(uint256 _chainId, uint256 _oldProtocolVersion, struct Diamond.DiamondCutData _diamondCut) external
```

_execute predefined upgrade_

### executeUpgrade

```solidity
function executeUpgrade(uint256 _chainId, struct Diamond.DiamondCutData _diamondCut) external
```

_executes upgrade on chain_

### setPriorityTxMaxGasLimit

```solidity
function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external
```

_setPriorityTxMaxGasLimit for the specified chain_

### setTokenMultiplier

```solidity
function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external
```

_setTokenMultiplier for the specified chain_

### changeFeeParams

```solidity
function changeFeeParams(uint256 _chainId, struct FeeParams _newFeeParams) external
```

_changeFeeParams for the specified chain_

### setValidator

```solidity
function setValidator(uint256 _chainId, address _validator, bool _active) external
```

_setValidator for the specified chain_

### setPorterAvailability

```solidity
function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external
```

_setPorterAvailability for the specified chain_

### _setChainIdUpgrade

```solidity
function _setChainIdUpgrade(uint256 _chainId, address _chainContract) internal
```

_we have to set the chainId at genesis, as blockhashzero is the same for all chains with the same chainId_

### registerAlreadyDeployedHyperchain

```solidity
function registerAlreadyDeployedHyperchain(uint256 _chainId, address _hyperchain) external
```

_used to register already deployed hyperchain contracts_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 | the chain's id |
| _hyperchain | address | the chain's contract address |

### createNewChain

```solidity
function createNewChain(uint256 _chainId, address _baseToken, address _sharedBridge, address _admin, bytes _diamondCut) external
```

called by Bridgehub when a chain registers

| Name | Type | Description |
| ---- | ---- | ----------- |
| _chainId | uint256 | the chain's id |
| _baseToken | address | the base token address used to pay for gas fees |
| _sharedBridge | address | the shared bridge address, used as base token bridge |
| _admin | address | the chain's admin address |
| _diamondCut | bytes | the diamond cut data that initializes the chains Diamond Proxy |

### _registerNewHyperchain

```solidity
function _registerNewHyperchain(uint256 _chainId, address _hyperchain) internal
```

_This internal function is used to register a new hyperchain in the system._

