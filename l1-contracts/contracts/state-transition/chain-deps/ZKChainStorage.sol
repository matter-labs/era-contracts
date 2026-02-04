// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier, VerifierParams} from "../chain-interfaces/IVerifier.sol";
import {PriorityQueue} from "../../state-transition/libraries/PriorityQueue.sol";
import {PriorityTree} from "../../state-transition/libraries/PriorityTree.sol";
import {L2DACommitmentScheme, PubdataPricingMode} from "../../common/Config.sol";

/// @notice Indicates whether an upgrade is initiated and if yes what type
/// @param None Upgrade is NOT initiated
/// @param Transparent Fully transparent upgrade is initiated, upgrade data is publicly known
/// @param Shadow Shadow upgrade is initiated, upgrade data is hidden
enum UpgradeState {
    None,
    Transparent,
    Shadow
}

/// @dev Logically separated part of the storage structure, which is responsible for everything related to proxy
/// upgrades and diamond cuts
/// @param proposedUpgradeHash The hash of the current upgrade proposal, zero if there is no active proposal
/// @param state Indicates whether an upgrade is initiated and if yes what type
/// @param securityCouncil Address which has the permission to approve instant upgrades (expected to be a Gnosis
/// multisig)
/// @param approvedBySecurityCouncil Indicates whether the security council has approved the upgrade
/// @param proposedUpgradeTimestamp The timestamp when the upgrade was proposed, zero if there are no active proposals
/// @param currentProposalId The serial number of proposed upgrades, increments when proposing a new one
struct UpgradeStorage {
    bytes32 proposedUpgradeHash;
    UpgradeState state;
    address securityCouncil;
    bool approvedBySecurityCouncil;
    uint40 proposedUpgradeTimestamp;
    uint40 currentProposalId;
}

/// @notice The fee params for L1->L2 transactions for the network.
/// @param pubdataPricingMode How the users will charged for pubdata in L1->L2 transactions.
/// @param batchOverheadL1Gas The amount of L1 gas required to process the batch (except for the calldata).
/// @param maxPubdataPerBatch The maximal number of pubdata that can be emitted per batch.
/// @param priorityTxMaxPubdata The maximal amount of pubdata a priority transaction is allowed to publish.
/// It can be slightly less than maxPubdataPerBatch in order to have some margin for the bootloader execution.
/// @param minimalL2GasPrice The minimal L2 gas price to be used by L1->L2 transactions. It should represent
/// the price that a single unit of compute costs.
struct FeeParams {
    PubdataPricingMode pubdataPricingMode;
    uint32 batchOverheadL1Gas;
    uint32 maxPubdataPerBatch;
    uint32 maxL2GasPerBatch;
    uint32 priorityTxMaxPubdata;
    uint64 minimalL2GasPrice;
}

/// @notice Stores the current Priority Mode (escape hatch) configuration.
/// @dev Only when `canBeActivated` is true, it is possible to enter Priority Mode.
/// @dev When `activated` is true, batch settlement is restricted to `permissionlessValidator`.
/// @param permissionlessValidator The only address allowed to call commit/prove/execute when Priority Mode is enabled.
/// @param transactionFilterer The transaction filterer to be used when Priority Mode is activated.
/// Only ZK Governance can change it.
struct PriorityModeInformation {
    bool canBeActivated;
    bool activated;
    address permissionlessValidator;
    address transactionFilterer;
}

/// @dev storing all storage variables for ZK chain diamond facets
/// NOTE: It is used in a proxy, so it is possible to add new variables to the end
/// but NOT to modify already existing variables or change their order.
/// NOTE: variables prefixed with '__DEPRECATED_' are deprecated and shouldn't be used.
/// Their presence is maintained for compatibility and to prevent storage collision.
// solhint-disable-next-line gas-struct-packing
struct ZKChainStorage {
    /// @dev Storage of variables needed for deprecated diamond cut facet
    /// @dev STORAGE SLOT: 0-6
    uint256[7] __DEPRECATED_diamondCutStorage;
    /// @notice Address which will exercise critical changes to the Diamond Proxy (upgrades, freezing & unfreezing). Replaced by CTM
    /// @dev STORAGE SLOT: 7
    address __DEPRECATED_governor;
    /// @notice Address that the governor proposed as one that will replace it
    /// @dev STORAGE SLOT: 8
    address __DEPRECATED_pendingGovernor;
    /// @notice List of permitted validators
    /// @dev STORAGE SLOT: 9
    mapping(address validatorAddress => bool isValidator) validators;
    /// @dev Verifier contract. Used to verify aggregated proof for batches
    /// @dev STORAGE SLOT: 10
    IVerifier verifier;
    /// @notice Total number of executed batches i.e. batches[totalBatchesExecuted] points at the latest executed batch
    /// (batch 0 is genesis)
    /// @dev STORAGE SLOT: 11
    uint256 totalBatchesExecuted;
    /// @notice Total number of proved batches i.e. batches[totalBatchesProved] points at the latest proved batch
    /// @dev STORAGE SLOT: 12
    uint256 totalBatchesVerified;
    /// @notice Total number of committed batches i.e. batches[totalBatchesCommitted] points at the latest committed
    /// batch
    /// @dev STORAGE SLOT: 13
    uint256 totalBatchesCommitted;
    /// @dev Stored hashed StoredBatch for batch number
    /// @dev STORAGE SLOT: 14
    mapping(uint256 batchNumber => bytes32 batchHash) storedBatchHashes;
    /// @dev Stored root hashes of L2 -> L1 logs
    /// @dev STORAGE SLOT: 15
    mapping(uint256 batchNumber => bytes32 l2LogsRootHash) l2LogsRootHashes;
    /// @dev Container that stores transactions requested from L1
    /// @dev STORAGE SLOT: 16-18 (mapping + 2 uint256s)
    PriorityQueue.Queue __DEPRECATED_priorityQueue;
    /// @dev The smart contract that manages the list with permission to call contract functions
    /// @dev STORAGE SLOT: 19
    address __DEPRECATED_allowList;
    /// @dev STORAGE SLOT: 20-22 (3 bytes32 fields)
    VerifierParams __DEPRECATED_verifierParams;
    /// @notice Bytecode hash of bootloader program.
    /// @dev Used as an input to zkp-circuit.
    /// @dev STORAGE SLOT: 23
    bytes32 l2BootloaderBytecodeHash;
    /// @notice Bytecode hash of default account (bytecode for EOA).
    /// @dev Used as an input to zkp-circuit.
    /// @dev STORAGE SLOT: 24
    bytes32 l2DefaultAccountBytecodeHash;
    /// @dev Indicates that the porter may be touched on L2 transactions.
    /// @dev Used as an input to zkp-circuit.
    /// @dev STORAGE SLOT: 25
    bool zkPorterIsAvailable;
    /// @dev The maximum number of the L2 gas that a user can request for L1 -> L2 transactions
    /// @dev This is the maximum number of L2 gas that is available for the "body" of the transaction, i.e.
    /// without overhead for proving the batch.
    /// @dev STORAGE SLOT: 26
    uint256 priorityTxMaxGasLimit;
    /// @dev Storage of variables needed for upgrade facet
    /// @dev STORAGE SLOT: 27-28 (bytes32 + packed fields)
    UpgradeStorage __DEPRECATED_upgrades;
    /// @dev A mapping L2 batch number => message number => flag.
    /// @dev The L2 -> L1 log is sent for every withdrawal, so this mapping is serving as
    /// a flag to indicate that the message was already processed.
    /// @dev Used to indicate that eth withdrawal was already processed
    /// @dev STORAGE SLOT: 29
    mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)) isEthWithdrawalFinalized;
    /// @dev The most recent withdrawal time and amount reset
    /// @dev STORAGE SLOT: 30
    uint256 __DEPRECATED_lastWithdrawalLimitReset;
    /// @dev The accumulated withdrawn amount during the withdrawal limit window
    /// @dev STORAGE SLOT: 31
    uint256 __DEPRECATED_withdrawnAmountInWindow;
    /// @dev A mapping user address => the total deposited amount by the user
    /// @dev STORAGE SLOT: 32
    mapping(address => uint256) __DEPRECATED_totalDepositedAmountPerUser;
    /// @dev Stores the protocol version. Note, that the protocol version may not only encompass changes to the
    /// smart contracts, but also to the node behavior.
    /// @dev STORAGE SLOT: 33
    uint256 protocolVersion;
    /// @dev Hash of the system contract upgrade transaction. If 0, then no upgrade transaction needs to be done.
    /// @dev STORAGE SLOT: 34
    bytes32 l2SystemContractsUpgradeTxHash;
    /// @dev Batch number where the upgrade transaction has happened. If 0, then no upgrade transaction has happened
    /// yet.
    /// @dev STORAGE SLOT: 35
    uint256 l2SystemContractsUpgradeBatchNumber;
    /// @dev Address which will exercise non-critical changes to the Diamond Proxy (changing validator set & unfreezing)
    /// @dev STORAGE SLOT: 36
    address admin;
    /// @notice Address that the admin proposed as one that will replace admin role
    /// @dev STORAGE SLOT: 37
    address pendingAdmin;
    /// @dev Fee params used to derive gasPrice for the L1->L2 transactions. For L2 transactions,
    /// the bootloader gives enough freedom to the operator.
    /// @dev The value is only for the L1 deployment of the ZK Chain, since payment for all the priority transactions is
    /// charged at that level.
    /// @dev STORAGE SLOT: 38 (packed: uint8 + 4*uint32 + uint64)
    FeeParams feeParams;
    /// @dev Address of the blob versioned hash getter smart contract used for EIP-4844 versioned hashes.
    /// @dev STORAGE SLOT: 39
    address __DEPRECATED_blobVersionedHashRetriever;
    /// @dev The chainId of the chain
    /// @dev STORAGE SLOT: 40
    uint256 chainId;
    /// @dev The address of the bridgehub
    /// @dev STORAGE SLOT: 41
    address bridgehub;
    /// @dev The address of the ChainTypeManager
    /// @dev STORAGE SLOT: 42
    address chainTypeManager;
    /// @dev The address of the baseToken contract. Eth is address(1)
    /// @dev STORAGE SLOT: 43
    address __DEPRECATED_baseToken;
    /// @dev The address of the baseTokenbridge. Eth also uses the shared bridge
    /// @dev STORAGE SLOT: 44
    address __DEPRECATED_baseTokenBridge;
    /// @notice gasPriceMultiplier for each baseToken, so that each L1->L2 transaction pays for its transaction on the destination
    /// we multiply by the nominator, and divide by the denominator
    /// @dev STORAGE SLOT: 45 (packed: 2*uint128)
    uint128 baseTokenGasPriceMultiplierNominator;
    uint128 baseTokenGasPriceMultiplierDenominator;
    /// @dev The optional address of the contract that has to be used for transaction filtering/whitelisting
    /// @dev STORAGE SLOT: 46
    address transactionFilterer;
    /// @dev The address of the l1DAValidator contract.
    /// This contract is responsible for the verification of the correctness of the DA on L1.
    /// @dev STORAGE SLOT: 47
    address l1DAValidator;
    /// @dev The address of the contract on L2 that is responsible for the data availability verification.
    /// This contract sends `l2DAValidatorOutputHash` to L1 via L2->L1 system log and it will routed to the `l1DAValidator` contract.
    /// @dev STORAGE SLOT: 48
    address __DEPRECATED_l2DAValidator;
    /// @dev the Asset Id of the baseToken
    /// @dev STORAGE SLOT: 49
    bytes32 baseTokenAssetId;
    /// @dev If this ZKchain settles on this chain, then this is zero. Otherwise it is the address of the ZKchain that is a
    /// settlement layer for this ZKchain. (think about it as a 'forwarding' address for the chain that migrated away).
    /// @dev Note, that while we cannot trust the operator of the settlement layer, it is assumed that the settlement layer
    /// belongs to the same CTM and has a trusted implementation, i.e., its implementation consists of the expected facets: Mailbox, Executor, etc.
    /// @dev STORAGE SLOT: 50
    address settlementLayer;
    /// @dev Priority tree, the new data structure for priority queue
    /// @dev STORAGE SLOT: 51-56 (2*uint256 + mapping + 3 slots for Bytes32PushTree)
    PriorityTree.Tree priorityTree;
    /// @dev Whether the chain is a permanent rollup. Note, that it only enforces the DA validator pair, but
    /// it does not enforce any other parameters, e.g. `pubdataPricingMode`
    /// @dev STORAGE SLOT: 57
    bool isPermanentRollup;
    /// @notice Bytecode hash of evm emulator.
    /// @dev Used as an input to zkp-circuit.
    /// @dev STORAGE SLOT: 58
    bytes32 l2EvmEmulatorBytecodeHash;
    /// @notice The precommitment for the latest uncommitted batch (i.e. totalBatchesCommitted + 1).
    /// @dev Whenever the `totalBatchesCommitted` changes, this variable is reset to `DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH`
    /// (the value of the constant can be found in Config.sol).
    /// @dev STORAGE SLOT: 59
    bytes32 precommitmentForTheLatestBatch;
    /// @dev ZKsync OS flag, if `true` state transition is done with ZKsync OS, otherwise Era VM
    /// @dev STORAGE SLOT: 60
    bool zksyncOS;
    /// @dev The scheme of L2 DA commitment. Different L1 validators may use different schemes.
    /// @dev STORAGE SLOT: 61
    L2DACommitmentScheme l2DACommitmentScheme;
    /// @dev The address of the asset tracker
    /// @dev STORAGE SLOT: 62
    address assetTracker;
    /// @dev The address of the native token vault
    /// @dev STORAGE SLOT: 63
    address nativeTokenVault;
    /// @dev Timestamp when deposits were paused for chain migration to/from Gateway. 0 = not paused.
    /// @dev STORAGE SLOT: 64
    uint256 pausedDepositsTimestamp;
    /// @dev Information required in the Priority Mode packed in one storage slot.
    /// @dev STORAGE SLOT: 65-66
    PriorityModeInformation priorityModeInfo;
    /// @dev Timestamp when a priority tx request was made for the specified tx index from priorityTree.
    /// @dev STORAGE SLOT: 67
    mapping(uint256 => uint256) priorityOpsRequestTimestamp;
    /// @dev Timestamp of the last fee params update (changeFeeParams).
    /// @dev STORAGE SLOT: 68
    uint256 lastFeeParamsUpdateTimestamp;
    /// @dev Timestamp of the last base token gas price multiplier update (setTokenMultiplier).
    /// @dev STORAGE SLOT: 69
    uint256 lastTokenMultiplierUpdateTimestamp;
}
