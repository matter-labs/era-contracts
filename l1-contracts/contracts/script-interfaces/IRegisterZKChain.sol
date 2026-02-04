// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable-next-line gas-struct-packing
struct RegisterZKChainConfig {
    address deployerAddress;
    address ownerAddress;
    uint256 chainChainId;
    bool validiumMode;
    uint256 bridgehubCreateNewChainSalt;
    address validatorSenderOperatorEth;
    address validatorSenderOperatorBlobsEth;
    // optional - if not set, then equal to 0
    address validatorSenderOperatorProve;
    // optional - if not set, then equal to 0
    address validatorSenderOperatorExecute;
    address baseToken;
    bytes32 baseTokenAssetId;
    uint128 baseTokenGasPriceMultiplierNominator;
    uint128 baseTokenGasPriceMultiplierDenominator;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    bool initializeLegacyBridge;
    address governance;
    address create2FactoryAddress;
    bytes32 create2Salt;
    bool allowEvmEmulator;
    // optional - if not set, then equal to 0
    address l1Erc20Bridge;
    address l1SharedBridgeProxy;
    bytes diamondCutData;
    bytes forceDeploymentsData;
}

/// @title IRegisterZKChain
/// @notice Interface for the RegisterZKChain deployment script
interface IRegisterZKChain {
    /// @notice Runs the ZK chain registration with production configuration
    /// @param _chainTypeManagerProxy Address of the chain type manager proxy (bridgehub is derived from this)
    /// @param _chainChainId Chain ID for the new ZK chain
    function run(address _chainTypeManagerProxy, uint256 _chainChainId) external;

    /// @notice Runs the ZK chain registration for testing purposes
    /// @param _chainTypeManagerProxy Address of the chain type manager proxy (bridgehub is derived from this)
    /// @param _chainChainId Chain ID for the new ZK chain
    function runForTest(address _chainTypeManagerProxy, uint256 _chainChainId) external;

    /// @notice Returns the registration configuration
    /// @return The RegisterZKChainConfig struct containing registration parameters
    function getConfig() external view returns (RegisterZKChainConfig memory);

    /// @notice Returns the owner address from configuration
    /// @return The owner address
    function getOwnerAddress() external view returns (address);
}
