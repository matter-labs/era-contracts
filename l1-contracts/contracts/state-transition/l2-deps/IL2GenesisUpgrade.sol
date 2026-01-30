// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenMetadata, TokenBridgingData} from "../../common/Messaging.sol";

/// @notice A struct that describes a forced deployment on an address
struct ForceDeployment {
    // The bytecode hash to put on an address
    bytes32 bytecodeHash;
    // The address on which to deploy the bytecodehash to
    address newAddress;
    // Whether to run the constructor on the force deployment
    bool callConstructor;
    // The value with which to initialize a contract
    uint256 value;
    // The constructor calldata
    bytes input;
}

// solhint-disable-next-line gas-struct-packing
struct ZKChainSpecificForceDeploymentsData {
    address l2LegacySharedBridge;
    address predeployedL2WethAddress;
    address baseTokenL1Address;
    /// @dev Some info about the base token, it is
    /// needed to deploy weth token in case it is not present
    TokenMetadata baseTokenMetadata;
    TokenBridgingData baseTokenBridgingData;
}

/// @notice The structure that describes force deployments that are the same for each chain.
/// @dev Note, that for simplicity, the same struct is used both for upgrading to the
/// Gateway version and for the Genesis. Some fields may not be used in either of those.
// solhint-disable-next-line gas-struct-packing
struct FixedForceDeploymentsData {
    uint256 l1ChainId;
    uint256 gatewayChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedL1Governance;
    uint256 maxNumberOfZKChains;
    bytes bridgehubBytecodeInfo;
    bytes l2AssetRouterBytecodeInfo;
    bytes l2NtvBytecodeInfo;
    bytes messageRootBytecodeInfo;
    bytes chainAssetHandlerBytecodeInfo;
    bytes interopCenterBytecodeInfo;
    bytes interopHandlerBytecodeInfo;
    bytes assetTrackerBytecodeInfo;
    bytes baseTokenHolderBytecodeInfo;
    bytes beaconDeployerInfo;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
    address aliasedChainRegistrationSender;
    // The forced beacon address. It is needed only for internal testing.
    // MUST be equal to 0 in production.
    // It will be the job of the governance to ensure that this value is set correctly.
    address dangerousTestOnlyForcedBeacon;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2GenesisUpgrade {
    event UpgradeComplete(uint256 _chainId);

    function genesisUpgrade(
        bool _isZKsyncOS,
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external;
}
