// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Diamond} from "./libraries/Diamond.sol";

/// @notice Struct that holds all data needed for initializing zkSync Diamond Proxy.
/// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
/// @param _governor address who can manage critical updates in the contract
/// @param _admin address who can manage non-critical updates in the contract
/// @param _genesisBatchHash Batch hash of the genesis (initial) batch
/// @param _genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis batch
/// @param _genesisBatchCommitment The zk-proof commitment for the genesis batch
struct StateTransitionManagerInitializeData {
    address governor;
    address genesisUpgrade;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    Diamond.DiamondCutData diamondCut;
    uint256 protocolVersion;
}

interface IStateTransitionManager{
    // when a new Chain is added
    event StateTransitionNewChain(uint256 indexed _chainId, address indexed _stateTransitionContract);

    function bridgehub() external view returns (address);

    function totalChains() external view returns (uint256);

    function stateTransition(uint256 _chainId) external view returns (address);

    function storedBatchZero() external view returns (bytes32);

    function initialCutHash() external view returns (bytes32);

    function genesisUpgrade() external view returns (address);

    function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);

    function protocolVersion() external view returns (uint256);

    function initialize(StateTransitionManagerInitializeData calldata _initalizeData) external;

        /// @notice
    function newChain(
        uint256 _chainId,
        address _baseToken,
        address _baseTokenBridge,
        address _governor,
        bytes calldata _diamondCut
    ) external;

    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external;

    function setUpgradeDiamondCut(Diamond.DiamondCutData calldata _cutData, uint256 _oldProtocolVersion) external;

    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;
}
