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
    address validatorSenderOperatorProve;
    address validatorSenderOperatorExecute;
    address baseToken;
    bytes32 baseTokenAssetId;
    uint128 baseTokenGasPriceMultiplierNominator;
    uint128 baseTokenGasPriceMultiplierDenominator;
    address bridgehub;
    address sharedBridgeProxy;
    address nativeTokenVault;
    address chainTypeManagerProxy;
    address validatorTimelock;
    bytes diamondCutData;
    bytes forceDeployments;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    address l1Nullifier;
    address l1Erc20Bridge;
    bool initializeLegacyBridge;
    address governance;
    address create2FactoryAddress;
    bytes32 create2Salt;
    bool allowEvmEmulator;
}

/// @title IRegisterZKChain
/// @notice Interface for the RegisterZKChain deployment script
interface IRegisterZKChain {
    /// @notice Runs the ZK chain registration with production configuration
    /// @param _bridgehub Address of the bridgehub contract
    /// @param _chainTypeManagerProxy Address of the chain type manager proxy
    /// @param _chainChainId Chain ID for the new ZK chain
    function run(address _bridgehub, address _chainTypeManagerProxy, uint256 _chainChainId) external;

    /// @notice Runs the ZK chain registration for testing purposes
    /// @param _bridgehub Address of the bridgehub contract
    /// @param _chainTypeManagerProxy Address of the chain type manager proxy
    /// @param _chainChainId Chain ID for the new ZK chain
    function runForTest(address _bridgehub, address _chainTypeManagerProxy, uint256 _chainChainId) external;

    /// @notice Returns the registration configuration
    /// @return The RegisterZKChainConfig struct containing registration parameters
    function getConfig() external view returns (RegisterZKChainConfig memory);

    /// @notice Returns the owner address from configuration
    /// @return The owner address
    function getOwnerAddress() external view returns (address);
}
