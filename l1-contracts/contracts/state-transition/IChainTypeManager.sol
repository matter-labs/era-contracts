// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Diamond} from "./libraries/Diamond.sol";
import {ICTMTransition} from "../upgrades/registry/ICTMTransition.sol";
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
    /// @dev `EXTCODEHASH` of the audited `CTMRelease`: every release this CTM ever pins (bootstrap
    ///      included) must run exactly that code — provenance is enforced by the CTM itself.
    bytes32 releaseCodehash;
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
    event NewReleaseCodehash(bytes32 indexed releaseCodehash);

    /// @notice New UpgradeCutHash
    event NewUpgradeCutHash(uint256 indexed protocolVersion, bytes32 indexed upgradeCutHash);

    /// @notice The transition committed for chains departing from `oldProtocolVersion`.
    event NewUpgradeTransition(uint256 indexed oldProtocolVersion, address indexed transition);

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


