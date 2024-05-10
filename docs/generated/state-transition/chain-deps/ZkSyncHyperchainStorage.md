## UpgradeState

Indicates whether an upgrade is initiated and if yes what type

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
enum UpgradeState {
  None,
  Transparent,
  Shadow
}
```
## UpgradeStorage

_Logically separated part of the storage structure, which is responsible for everything related to proxy
upgrades and diamond cuts_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct UpgradeStorage {
  bytes32 proposedUpgradeHash;
  enum UpgradeState state;
  address securityCouncil;
  bool approvedBySecurityCouncil;
  uint40 proposedUpgradeTimestamp;
  uint40 currentProposalId;
}
```
## PubdataPricingMode

The struct that describes whether users will be charged for pubdata for L1->L2 transactions.

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
enum PubdataPricingMode {
  Rollup,
  Validium
}
```
## FeeParams

The fee params for L1->L2 transactions for the network.

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct FeeParams {
  enum PubdataPricingMode pubdataPricingMode;
  uint32 batchOverheadL1Gas;
  uint32 maxPubdataPerBatch;
  uint32 maxL2GasPerBatch;
  uint32 priorityTxMaxPubdata;
  uint64 minimalL2GasPrice;
}
```
## ZkSyncHyperchainStorage

_storing all storage variables for hyperchain diamond facets
NOTE: It is used in a proxy, so it is possible to add new variables to the end
but NOT to modify already existing variables or change their order.
NOTE: variables prefixed with '__DEPRECATED_' are deprecated and shouldn't be used.
Their presence is maintained for compatibility and to prevent storage collision._

```solidity
struct ZkSyncHyperchainStorage {
  uint256[7] __DEPRECATED_diamondCutStorage;
  address __DEPRECATED_governor;
  address __DEPRECATED_pendingGovernor;
  mapping(address => bool) validators;
  contract IVerifier verifier;
  uint256 totalBatchesExecuted;
  uint256 totalBatchesVerified;
  uint256 totalBatchesCommitted;
  mapping(uint256 => bytes32) storedBatchHashes;
  mapping(uint256 => bytes32) l2LogsRootHashes;
  struct PriorityQueue.Queue priorityQueue;
  address __DEPRECATED_allowList;
  struct VerifierParams __DEPRECATED_verifierParams;
  bytes32 l2BootloaderBytecodeHash;
  bytes32 l2DefaultAccountBytecodeHash;
  bool zkPorterIsAvailable;
  uint256 priorityTxMaxGasLimit;
  struct UpgradeStorage __DEPRECATED_upgrades;
  mapping(uint256 => mapping(uint256 => bool)) isEthWithdrawalFinalized;
  uint256 __DEPRECATED_lastWithdrawalLimitReset;
  uint256 __DEPRECATED_withdrawnAmountInWindow;
  mapping(address => uint256) __DEPRECATED_totalDepositedAmountPerUser;
  uint256 protocolVersion;
  bytes32 l2SystemContractsUpgradeTxHash;
  uint256 l2SystemContractsUpgradeBatchNumber;
  address admin;
  address pendingAdmin;
  struct FeeParams feeParams;
  address blobVersionedHashRetriever;
  uint256 chainId;
  address bridgehub;
  address stateTransitionManager;
  address baseToken;
  address baseTokenBridge;
  uint128 baseTokenGasPriceMultiplierNominator;
  uint128 baseTokenGasPriceMultiplierDenominator;
  address transactionFilterer;
}
```
