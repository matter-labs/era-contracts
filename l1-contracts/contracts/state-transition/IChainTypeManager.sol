// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Diamond} from "./libraries/Diamond.sol";
import {L2CanonicalTransaction, TxStatus} from "../common/Messaging.sol";
import {FeeParams} from "./chain-deps/ZKChainStorage.sol";

/// @notice Struct that holds all data needed for initializing CTM Proxy.
/// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
/// @param owner The address who can manage non-critical updates in the contract
/// @param validatorTimelock The address that serves as consensus, i.e. can submit blocks to be processed
/// @param currentRelease The `CTMRelease` new chains read their genesis data from
/// @param protocolVersion The initial protocol version on the newly deployed chain
/// @param serverNotifier The address that serves as server notifier
// solhint-disable-next-line gas-struct-packing
struct ChainTypeManagerInitializeData {
    address owner;
    address validatorTimelock;
    /// @dev The canonical `CTMReleaseFactory`: every release this CTM ever pins (bootstrap
    ///      included) must be attested by it — release provenance is enforced by the CTM itself.
    address releaseFactory;
    address currentRelease;
    uint256 protocolVersion;
    address serverNotifier;
}

interface IChainTypeManager {
    /// @dev Emitted when a new ZKChain is added
    event NewZKChain(uint256 indexed _chainId, address indexed _zkChainContract);

    /// @dev emitted when an chain registers and a GenesisUpgrade happens
    event GenesisUpgrade(
        address indexed _zkChain,
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

    /// @notice ValidatorTimelockPostV29 changed
    event NewValidatorTimelockPostV29(
        address indexed oldValidatorTimelockPostV29,
        address indexed newvalidatorTimelockPostV29
    );

    /// @notice ServerNotifier changed
    event NewServerNotifier(address indexed oldServerNotifier, address indexed newServerNotifier);

    /// @notice The release used for new-chain genesis changed.
    event NewCurrentRelease(uint256 indexed protocolVersion, address indexed release);

    /// @notice The canonical release factory was set.
    event NewReleaseFactory(address indexed releaseFactory);

    /// @notice New UpgradeCutHash
    event NewUpgradeCutHash(uint256 indexed protocolVersion, bytes32 indexed upgradeCutHash);

    /// @notice New UpgradeCutData
    event NewUpgradeCutData(uint256 indexed protocolVersion, Diamond.DiamondCutData diamondCutData);

    /// @notice New ProtocolVersion
    event NewProtocolVersion(uint256 indexed oldProtocolVersion, uint256 indexed newProtocolVersion);

    /// @notice Updated ProtocolVersion deadline
    event UpdateProtocolVersionDeadline(uint256 indexed protocolVersion, uint256 deadline);

    function isZKsyncOS() external pure returns (bool);

    function BRIDGE_HUB() external view returns (address);

    function PERMISSIONLESS_VALIDATOR() external view returns (address);

    function setPendingAdmin(address _newPendingAdmin) external;

    function acceptAdmin() external;

    function getZKChain(uint256 _chainId) external view returns (address);

    function getHyperchain(uint256 _chainId) external view returns (address);

    function getZKChainLegacy(uint256 _chainId) external view returns (address);

    function storedBatchZero() external view returns (bytes32);

    function l1GenesisUpgrade() external view returns (address);

    function upgradeCutHash(uint256 _protocolVersion) external view returns (bytes32);

    function protocolVersion() external view returns (uint256);

    function protocolVersionDeadline(uint256 _protocolVersion) external view returns (uint256);

    function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool);
    function currentRelease() external view returns (address);

    function getProtocolVersion(uint256 _chainId) external view returns (uint256);

    function serverNotifierAddress() external view returns (address);

    function validatorTimelock() external view returns (address);

    function validatorTimelockPostV29() external view returns (address);

    function initialize(ChainTypeManagerInitializeData calldata _initializeData) external;

    function setLegacyValidatorTimelock(address _validatorTimelock) external;

    function setValidatorTimelockPostV29(address _validatorTimelockPostV29) external;

    function setCurrentRelease(address _release) external;

    /// @notice Sets the canonical release factory (migration path for CTMs whose storage
    ///         predates the field; fresh CTMs receive it in `initialize`).
    function setReleaseFactory(address _releaseFactory) external;

    /// @notice The canonical release factory whose attestation every pinned release must carry.
    function releaseFactory() external view returns (address);

    function getChainAdmin(uint256 _chainId) external view returns (address);

    /// @notice Deploys a new chain. The bridgehub passes only the minimal chain-specific data
    ///         (id + admin); everything else (base token asset id, genesis facet set, base system
    ///         hashes, genesis params, force deployments) is derived from the bridgehub and the
    ///         CTM's current release.
    function createNewChain(uint256 _chainId, address _admin) external returns (address);

    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _oldProtocolVersionDeadline,
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

    function deactivatePriorityMode(uint256 _chainId) external;

    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external;

    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32);

    function forwardedBridgeBurn(
        uint256 _chainId,
        bytes calldata _data
    ) external returns (bytes memory _bridgeMintData);

    function forwardedBridgeMint(uint256 _chainId, bytes calldata _data) external returns (address);

    function forwardedBridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus,
        bytes32 _assetInfo,
        address _depositSender,
        bytes calldata _ctmData
    ) external;
}
