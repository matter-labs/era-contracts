// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
    bytes32 baseTokenAssetId;
    address l2LegacySharedBridge;
    address predeployedL2WethAddress;
    address baseTokenL1Address;
    /// @dev Some info about the base token, it is
    /// needed to deploy weth token in case it is not present
    string baseTokenName;
    string baseTokenSymbol;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2GenesisUpgrade {
    event UpgradeComplete(uint256 _chainId);

    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable;
}
