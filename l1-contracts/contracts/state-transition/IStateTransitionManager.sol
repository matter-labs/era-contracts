// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "./libraries/Diamond.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {FeeParams} from "./chain-deps/ZkSyncHyperchainStorage.sol";

/// @notice Struct that holds all data needed for initializing STM Proxy.
/// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
/// @param owner The address who can manage non-critical updates in the contract
/// @param validatorTimelock The address that serves as consensus, i.e. can submit blocks to be processed
/// @param chainCreationParams The struct that contains the fields that define how a new chain should be created
/// @param protocolVersion The initial protocol version on the newly deployed chain
struct StateTransitionManagerInitializeData {
    address owner;
    address validatorTimelock;
    ChainCreationParams chainCreationParams;
    uint256 protocolVersion;
}

/// @notice The struct that contains the fields that define how a new chain should be created
/// within this STM.
/// @param genesisUpgrade The address that is used in the diamond cut initialize address on chain creation
/// @param genesisBatchHash Batch hash of the genesis (initial) batch
/// @param genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for the genesis batch
/// @param genesisBatchCommitment The zk-proof commitment for the genesis batch
/// @param diamondCut The diamond cut for the first upgrade transaction on the newly deployed chain
struct ChainCreationParams {
    address genesisUpgrade;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    Diamond.DiamondCutData diamondCut;
}

interface IStateTransitionManager {
    /// @dev Emitted when a new Hyperchain is added
    event NewHyperchain(uint256 indexed _chainId, address indexed _hyperchainContract);

    /// @dev emitted when an chain registers and a SetChainIdUpgrade happens
    event SetChainIdUpgrade(
        address indexed _hyperchain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion
    );

    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice ValidatorTimelock changed
    event NewValidatorTimelock(address indexed oldValidatorTimelock, address indexed newValidatorTimelock);

    /// @notice chain creation parameters changed
    event NewChainCreationParams(
        address genesisUpgrade,
        bytes32 genesisBatchHash,
        uint64 genesisIndexRepeatedStorageChanges,
        bytes32 genesisBatchCommitment,
        bytes32 newInitialCutHash
    );

    /// @notice New UpgradeCutHash
    event NewUpgradeCutHash(uint256 indexed protocolVersion, bytes32 indexed upgradeCutHash);

    /// @notice New UpgradeCutData
    event NewUpgradeCutData(uint256 indexed protocolVersion, Diamond.DiamondCutData diamondCutData);

    /// @notice New ProtocolVersion
    event NewProtocolVersion(uint256 indexed oldProtocolVersion, uint256 indexed newProtocolVersion);

    function BRIDGE_HUB() external view returns (address);

    function setPendingAdmin(address _newPendingAdmin) external;

    function acceptAdmin() external;

    function getAllHyperchains() external view returns (address[] memory);

    function getAllHyperchainChainIDs() external view returns (uint256[] memory);

    function getHyperchain(uint256 _chainId) external view returns (address);

    function storedBatchZero() external view returns (bytes32);

    function initialCutHash() external view returns (bytes32);

    function genesisUpgrade() external view returns (address);

    function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);

    function protocolVersion() external view returns (uint256);

    function protocolVersionDeadline(uint256 _protocolVersion) external view returns (uint256);

    function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool);

    function initialize(StateTransitionManagerInitializeData calldata _initializeData) external;

    function setValidatorTimelock(address _validatorTimelock) external;

    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams) external;

    function getChainAdmin(uint256 _chainId) external view returns (address);

    function createNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _diamondCut
    ) external;

    function registerAlreadyDeployedHyperchain(uint256 _chainId, address _hyperchain) external;

    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _oldprotocolVersionDeadline,
        uint256 _newProtocolVersion
    ) external;

    function setUpgradeDiamondCut(Diamond.DiamondCutData calldata _cutData, uint256 _oldProtocolVersion) external;

    function executeUpgrade(uint256 _chainId, Diamond.DiamondCutData calldata _diamondCut) external;

    function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external;

    function freezeChain(uint256 _chainId) external;

    function unfreezeChain(uint256 _chainId) external;

    function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external;

    function changeFeeParams(uint256 _chainId, FeeParams calldata _newFeeParams) external;

    function setValidator(uint256 _chainId, address _validator, bool _active) external;

    function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external;

    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external;

    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32);
}
