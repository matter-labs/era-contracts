// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Utils.sol";

/// @title L2ContractsBytecodesLib
/// @notice Library providing functions to read bytecodes of L2 contracts individually.
library L2ContractsBytecodesLib {
    /// @notice Reads the bytecode of the Bridgehub contract.
    /// @return The bytecode of the Bridgehub contract.
    function readBridgehubBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("Bridgehub.sol", "Bridgehub");
    }

    /// @notice Reads the bytecode of the L2NativeTokenVault contract.
    /// @return The bytecode of the L2NativeTokenVault contract.
    function readL2NativeTokenVaultBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2NativeTokenVault.sol", "L2NativeTokenVault");
    }

    /// @notice Reads the bytecode of the L2AssetRouter contract.
    /// @return The bytecode of the L2AssetRouter contract.
    function readL2AssetRouterBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2AssetRouter.sol", "L2AssetRouter");
    }

    /// @notice Reads the bytecode of the MessageRoot contract.
    /// @return The bytecode of the MessageRoot contract.
    function readMessageRootBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("MessageRoot.sol", "MessageRoot");
    }

    /// @notice Reads the bytecode of the UpgradeableBeacon contract.
    /// @return The bytecode of the UpgradeableBeacon contract.
    function readUpgradeableBeaconBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("UpgradeableBeacon.sol", "UpgradeableBeacon");
    }

    /// @notice Reads the bytecode of the BeaconProxy contract.
    /// @return The bytecode of the BeaconProxy contract.
    function readBeaconProxyBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("BeaconProxy.sol", "BeaconProxy");
    }

    /// @notice Reads the bytecode of the BridgedStandardERC20 contract.
    /// @return The bytecode of the BridgedStandardERC20 contract.
    function readStandardERC20Bytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("BridgedStandardERC20.sol", "BridgedStandardERC20");
    }

    /// @notice Reads the bytecode of the TransparentUpgradeableProxy contract.
    /// @return The bytecode of the TransparentUpgradeableProxy contract.
    function readTransparentUpgradeableProxyBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("TransparentUpgradeableProxy.sol", "TransparentUpgradeableProxy");
    }

    /// @notice Reads the bytecode of the TransparentUpgradeableProxy contract.
    /// @return The bytecode of the TransparentUpgradeableProxy contract.
    function readTransparentUpgradeableProxyBytecodeFromSystemContracts() internal view returns (bytes memory) {
        return
            Utils.readZKFoundryBytecodeSystemContracts(
                "TransparentUpgradeableProxy.sol",
                "TransparentUpgradeableProxy"
            );
    }

    /// @notice Reads the bytecode of the ForceDeployUpgrader contract.
    /// @return The bytecode of the ForceDeployUpgrader contract.
    function readForceDeployUpgraderBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("ForceDeployUpgrader.sol", "ForceDeployUpgrader");
    }

    /// @notice Reads the bytecode of the RollupL2DAValidator contract.
    /// @return The bytecode of the RollupL2DAValidator contract.
    function readRollupL2DAValidatorBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("RollupL2DAValidator.sol", "RollupL2DAValidator");
    }

    /// @notice Reads the bytecode of the ValidiumL2DAValidator contract for Avail.
    /// @return The bytecode of the ValidiumL2DAValidator contract.
    function readAvailL2DAValidatorBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("AvailL2DAValidator.sol", "AvailL2DAValidator");
    }

    /// @notice Reads the bytecode of the ValidiumL2DAValidator contract for NoDA validium.
    /// @return The bytecode of the ValidiumL2DAValidator contract.
    function readNoDAL2DAValidatorBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("ValidiumL2DAValidator.sol", "ValidiumL2DAValidator");
    }

    /// @notice Reads the bytecode of the ChainTypeManager contract.
    /// @return The bytecode of the ChainTypeManager contract.
    function readChainTypeManagerBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("ChainTypeManager.sol", "ChainTypeManager");
    }

    /// @notice Reads the bytecode of the AdminFacet contract.
    /// @return The bytecode of the AdminFacet contract.
    function readAdminFacetBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("Admin.sol", "AdminFacet");
    }

    /// @notice Reads the bytecode of the MailboxFacet contract.
    /// @return The bytecode of the MailboxFacet contract.
    function readMailboxFacetBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("Mailbox.sol", "MailboxFacet");
    }

    /// @notice Reads the bytecode of the ExecutorFacet contract.
    /// @return The bytecode of the ExecutorFacet contract.
    function readExecutorFacetBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("Executor.sol", "ExecutorFacet");
    }

    /// @notice Reads the bytecode of the GettersFacet contract.
    /// @return The bytecode of the GettersFacet contract.
    function readGettersFacetBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("Getters.sol", "GettersFacet");
    }

    /// @notice Reads the bytecode of the DualVerifier contract.
    /// @return The bytecode of the DualVerifier contract.
    function readVerifierBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("DualVerifier.sol", "DualVerifier");
    }

    /// @notice Reads the bytecode of the L2 Verifier contract.
    /// @return The bytecode of the Verifier contract.
    function readL2VerifierBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("DualVerifier.sol", "DualVerifier");
    }

    /// @notice Reads the bytecode of the L2 VerifierFflonk contract.
    /// @return The bytecode of the VerifierFflonk contract.
    function readL2VerifierFflonkBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("VerifierFflonk.sol", "VerifierFflonk");
    }

    /// @notice Reads the bytecode of the L2 VerifierPlonk contract.
    /// @return The bytecode of the VerifierPlonk contract.
    function readL2VerifierPlonkBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("VerifierPlonk.sol", "VerifierPlonk");
    }

    /// @notice Reads the bytecode of the ConsensusRegistry contract.
    /// @return The bytecode of the ConsensusRegistry contract.
    function readConsensusRegistryBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("ConsensusRegistry.sol", "ConsensusRegistry");
    }

    /// @notice Reads the bytecode of the TestnetVerifier contract.
    /// @return The bytecode of the TestnetVerifier contract.
    function readL2TestnetVerifierBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2TestnetVerifier.sol", "L2TestnetVerifier");
    }

    /// @notice Reads the bytecode of the ValidatorTimelock contract.
    /// @return The bytecode of the ValidatorTimelock contract.
    function readValidatorTimelockBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
    }

    /// @notice Reads the bytecode of the DiamondInit contract.
    /// @return The bytecode of the DiamondInit contract.
    function readDiamondInitBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("DiamondInit.sol", "DiamondInit");
    }

    /// @notice Reads the bytecode of the DiamondProxy contract.
    /// @return The bytecode of the DiamondProxy contract.
    function readDiamondProxyBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("DiamondProxy.sol", "DiamondProxy");
    }

    /// @notice Reads the bytecode of the L1GenesisUpgrade contract.
    /// @return The bytecode of the L1GenesisUpgrade contract.
    function readL1GenesisUpgradeBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L1GenesisUpgrade.sol", "L1GenesisUpgrade");
    }

    /// @notice Reads the bytecode of the DefaultUpgrade contract.
    /// @return The bytecode of the DefaultUpgrade contract.
    function readDefaultUpgradeBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("DefaultUpgrade.sol", "DefaultUpgrade");
    }

    /// @notice Reads the bytecode of the Multicall3 contract.
    /// @return The bytecode of the Multicall3 contract.
    function readMulticall3Bytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("Multicall3.sol", "Multicall3");
    }

    /// @notice Reads the bytecode of the RelayedSLDAValidator contract.
    /// @return The bytecode of the RelayedSLDAValidator contract.
    function readRelayedSLDAValidatorBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("RelayedSLDAValidator.sol", "RelayedSLDAValidator");
    }

    /// @notice Reads the bytecode of the L2SharedBridgeLegacy contract.
    /// @return The bytecode of the L2SharedBridgeLegacy contract.
    function readL2LegacySharedBridgeBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2SharedBridgeLegacy.sol", "L2SharedBridgeLegacy");
    }

    /// @notice Reads the bytecode of the L2SharedBridgeLegacy contract.
    /// @return The bytecode of the L2SharedBridgeLegacy contract.
    function readL2LegacySharedBridgeDevBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2SharedBridgeLegacyDev.sol", "L2SharedBridgeLegacyDev");
    }

    /// @notice Reads the bytecode of the L2GatewayUpgrade contract.
    /// @return The bytecode of the L2GatewayUpgrade contract.
    function readGatewayUpgradeBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeSystemContracts("L2GatewayUpgrade.sol", "L2GatewayUpgrade");
    }

    /// @notice Reads the bytecode of the L2AdminFactory contract.
    /// @return The bytecode of the L2AdminFactory contract.
    function readL2AdminFactoryBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2AdminFactory.sol", "L2AdminFactory");
    }

    function readProxyAdminBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("ProxyAdmin.sol", "ProxyAdmin");
    }

    /// @notice Reads the bytecode of the PermanentRestriction contract.
    /// @return The bytecode of the PermanentRestriction contract.
    function readPermanentRestrictionBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("PermanentRestriction.sol", "PermanentRestriction");
    }

    /// @notice Reads the bytecode of the L2ProxyAdminDeployer contract.
    /// @return The bytecode of the L2ProxyAdminDeployer contract.
    function readProxyAdminDeployerBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2ProxyAdminDeployer.sol", "L2ProxyAdminDeployer");
    }

    /// @notice Reads the bytecode of the L2WrappedBaseToken contract.
    /// @return The bytecode of the L2WrappedBaseToken contract.
    function readL2WrappedBaseToken() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("L2WrappedBaseToken.sol", "L2WrappedBaseToken");
    }

    /// @notice Reads the bytecode of the TimestampAsserter contract.
    /// @return The bytecode of the TimestampAsserter contract.
    function readTimestampAsserterBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL2("TimestampAsserter.sol", "TimestampAsserter");
    }

    /// @notice Reads the bytecode of the ChainAdmin contract.
    /// @return The bytecode of the ChainAdmin contract.
    function readChainAdminBytecode() internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1("ChainAdmin.sol", "ChainAdmin");
    }
}
