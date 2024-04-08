// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Diamond} from "./libraries/Diamond.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @notice Struct that holds all data needed for initializing STM Proxy.
/// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
/// @param _owner address who can manage non-critical updates in the contract
/// @param _validatorTimelock address that serves as consensus, i.e. can submit blocks to be processed
/// @param _genesisBatchHash Batch hash of the genesis (initial) batch
/// @param _genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis batch
/// @param _genesisBatchCommitment The zk-proof commitment for the genesis batch
struct StateTransitionManagerInitializeData {
    address owner;
    address validatorTimelock;
    address genesisUpgrade;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    Diamond.DiamondCutData diamondCut;
    uint256 protocolVersion;
}

interface IStateTransitionManager {
    /// @dev Emitted when a new Chain is added
    event NewHyperchain(uint256 indexed _chainId, address indexed _stateTransitionContract);

    /// @dev emitted when an chain registers and a SetChainIdUpgrade happens
    event SetChainIdUpgrade(
        address indexed _stateTransitionChain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion
    );

    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    function bridgehub() external view returns (address);

    function setPendingAdmin(address _newPendingAdmin) external;

    function acceptAdmin() external;

    function stateTransition(uint256 _chainId) external view returns (address);

    function storedBatchZero() external view returns (bytes32);

    function initialCutHash() external view returns (bytes32);

    function genesisUpgrade() external view returns (address);

    function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);

    function protocolVersion() external view returns (uint256);

    function initialize(StateTransitionManagerInitializeData calldata _initalizeData) external;

    function setInitialCutHash(Diamond.DiamondCutData calldata _diamondCut) external;

    function setValidatorTimelock(address _validatorTimelock) external;

    function getChainAdmin(uint256 _chainId) external view returns (address);

    function createNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _diamondCut
    ) external;

    function registerAlreadyDeployedStateTransition(uint256 _chainId, address _stateTransitionContract) external;

    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external;

    function setUpgradeDiamondCut(Diamond.DiamondCutData calldata _cutData, uint256 _oldProtocolVersion) external;

    function freezeChain(uint256 _chainId) external;

    function unfreezeChain(uint256 _chainId) external;
}
