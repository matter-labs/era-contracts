// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @dev Token metadata used for base token initialization during genesis/upgrade.
struct TokenMetadata {
    string name;
    string symbol;
    uint256 decimals;
}

/// @dev Token bridging data used for base token initialization during genesis/upgrade.
struct TokenBridgingData {
    bytes32 assetId;
    uint256 originChainId;
    address originToken;
}

// solhint-disable-next-line gas-struct-packing
struct ZKChainSpecificForceDeploymentsData {
    address l2LegacySharedBridge;
    /// @dev Deprecated: always address(0). Kept to avoid breaking the ABI encoding
    /// used by the server (core/lib/types/src/abi.rs).
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
    bytes beaconDeployerInfo;
    bytes baseTokenHolderBytecodeInfo;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
    address aliasedChainRegistrationSender;
    // The forced beacon address. It is needed only for internal testing.
    // MUST be equal to 0 in production.
    // It will be the job of the governance to ensure that this value is set correctly.
    address dangerousTestOnlyForcedBeacon;
    bytes32 zkTokenAssetId;
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
