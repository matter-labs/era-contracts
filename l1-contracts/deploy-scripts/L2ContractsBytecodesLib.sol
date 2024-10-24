// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Utils.sol";

/// @title L2ContractsBytecodesLib
/// @notice Library providing functions to read bytecodes of L2 contracts individually.
library L2ContractsBytecodesLib {
    /// @notice Reads the bytecode of the Bridgehub contract.
    /// @return The bytecode of the Bridgehub contract.
    function readBridgehubBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode("/../l1-contracts/artifacts-zk/contracts/bridgehub/Bridgehub.sol/Bridgehub.json");
    }

    /// @notice Reads the bytecode of the L2NativeTokenVault contract.
    /// @return The bytecode of the L2NativeTokenVault contract.
    function readL2NativeTokenVaultBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/ntv/L2NativeTokenVault.sol/L2NativeTokenVault.json"
            );
    }

    /// @notice Reads the bytecode of the L2AssetRouter contract.
    /// @return The bytecode of the L2AssetRouter contract.
    function readL2AssetRouterBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/asset-router/L2AssetRouter.sol/L2AssetRouter.json"
            );
    }

    /// @notice Reads the bytecode of the MessageRoot contract.
    /// @return The bytecode of the MessageRoot contract.
    function readMessageRootBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridgehub/MessageRoot.sol/MessageRoot.json"
            );
    }

    /// @notice Reads the bytecode of the UpgradeableBeacon contract.
    /// @return The bytecode of the UpgradeableBeacon contract.
    function readUpgradeableBeaconBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol/UpgradeableBeacon.json"
            );
    }

    /// @notice Reads the bytecode of the BeaconProxy contract.
    /// @return The bytecode of the BeaconProxy contract.
    function readBeaconProxyBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
            );
    }

    /// @notice Reads the bytecode of the BridgedStandardERC20 contract.
    /// @return The bytecode of the BridgedStandardERC20 contract.
    function readStandardERC20Bytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/BridgedStandardERC20.sol/BridgedStandardERC20.json"
            );
    }

    /// @notice Reads the bytecode of the TransparentUpgradeableProxy contract.
    /// @return The bytecode of the TransparentUpgradeableProxy contract.
    function readTransparentUpgradeableProxyBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
            );
    }

    /// @notice Reads the bytecode of the TransparentUpgradeableProxy contract.
    /// @return The bytecode of the TransparentUpgradeableProxy contract.
    function readTransparentUpgradeableProxyBytecodeFromSystemContracts() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../system-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
            );
    }

    /// @notice Reads the bytecode of the ForceDeployUpgrader contract.
    /// @return The bytecode of the ForceDeployUpgrader contract.
    function readForceDeployUpgraderBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/ForceDeployUpgrader.sol/ForceDeployUpgrader.json"
            );
    }

    /// @notice Reads the bytecode of the RollupL2DAValidator contract.
    /// @return The bytecode of the RollupL2DAValidator contract.
    function readRollupL2DAValidatorBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/data-availability/RollupL2DAValidator.sol/RollupL2DAValidator.json"
            );
    }

    /// @notice Reads the bytecode of the ValidiumL2DAValidator contract.
    /// @return The bytecode of the ValidiumL2DAValidator contract.
    function readValidiumL2DAValidatorBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/data-availability/ValidiumL2DAValidator.sol/ValidiumL2DAValidator.json"
            );
    }

    /// @notice Reads the bytecode of the ChainTypeManager contract.
    /// @return The bytecode of the ChainTypeManager contract.
    function readChainTypeManagerBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/ChainTypeManager.sol/ChainTypeManager.json"
            );
    }

    /// @notice Reads the bytecode of the AdminFacet contract.
    /// @return The bytecode of the AdminFacet contract.
    function readAdminFacetBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Admin.sol/AdminFacet.json"
            );
    }

    /// @notice Reads the bytecode of the MailboxFacet contract.
    /// @return The bytecode of the MailboxFacet contract.
    function readMailboxFacetBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Mailbox.sol/MailboxFacet.json"
            );
    }

    /// @notice Reads the bytecode of the ExecutorFacet contract.
    /// @return The bytecode of the ExecutorFacet contract.
    function readExecutorFacetBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Executor.sol/ExecutorFacet.json"
            );
    }

    /// @notice Reads the bytecode of the GettersFacet contract.
    /// @return The bytecode of the GettersFacet contract.
    function readGettersFacetBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Getters.sol/GettersFacet.json"
            );
    }

    /// @notice Reads the bytecode of the Verifier contract.
    /// @return The bytecode of the Verifier contract.
    function readVerifierBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/Verifier.sol/Verifier.json"
            );
    }

    /// @notice Reads the bytecode of the L2 Verifier contract.
    /// @return The bytecode of the Verifier contract.
    function readL2VerifierBytecode() internal view returns (bytes memory) {
        return Utils.readHardhatBytecode("/../l2-contracts/artifacts-zk/contracts/verifier/Verifier.sol/Verifier.json");
    }

    /// @notice Reads the bytecode of the Verifier contract.
    /// @return The bytecode of the Verifier contract.
    function readConsensusRegistryBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/ConsensusRegistry.sol/ConsensusRegistry.json"
            );
    }

    /// @notice Reads the bytecode of the TestnetVerifier contract.
    /// @return The bytecode of the TestnetVerifier contract.
    function readL2TestnetVerifierBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/verifier/TestnetVerifier.sol/TestnetVerifier.json"
            );
    }

    /// @notice Reads the bytecode of the ValidatorTimelock contract.
    /// @return The bytecode of the ValidatorTimelock contract.
    function readValidatorTimelockBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/ValidatorTimelock.sol/ValidatorTimelock.json"
            );
    }

    /// @notice Reads the bytecode of the DiamondInit contract.
    /// @return The bytecode of the DiamondInit contract.
    function readDiamondInitBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/DiamondInit.sol/DiamondInit.json"
            );
    }

    /// @notice Reads the bytecode of the DiamondProxy contract.
    /// @return The bytecode of the DiamondProxy contract.
    function readDiamondProxyBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/DiamondProxy.sol/DiamondProxy.json"
            );
    }

    /// @notice Reads the bytecode of the L1GenesisUpgrade contract.
    /// @return The bytecode of the L1GenesisUpgrade contract.
    function readL1GenesisUpgradeBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/upgrades/L1GenesisUpgrade.sol/L1GenesisUpgrade.json"
            );
    }

    /// @notice Reads the bytecode of the DefaultUpgrade contract.
    /// @return The bytecode of the DefaultUpgrade contract.
    function readDefaultUpgradeBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/upgrades/DefaultUpgrade.sol/DefaultUpgrade.json"
            );
    }

    /// @notice Reads the bytecode of the Multicall3 contract.
    /// @return The bytecode of the Multicall3 contract.
    function readMulticall3Bytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/dev-contracts/Multicall3.sol/Multicall3.json"
            );
    }

    /// @notice Reads the bytecode of the RelayedSLDAValidator contract.
    /// @return The bytecode of the RelayedSLDAValidator contract.
    function readRelayedSLDAValidatorBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/data-availability/RelayedSLDAValidator.sol/RelayedSLDAValidator.json"
            );
    }

    function readValidiumL1DAValidatorBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/data-availability/ValidiumL1DAValidator.sol/ValidiumL1DAValidator.json"
            );
    }

    /// @notice Reads the bytecode of the L2SharedBridgeLegacy contract.
    /// @return The bytecode of the L2SharedBridgeLegacy contract.
    function readL2LegacySharedBridgeBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/L2SharedBridgeLegacy.sol/L2SharedBridgeLegacy.json"
            );
    }

    /// @notice Reads the bytecode of the L2GatewayUpgrade contract.
    /// @return The bytecode of the L2GatewayUpgrade contract.
    function readGatewayUpgradeBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../system-contracts/artifacts-zk/contracts-preprocessed/L2GatewayUpgrade.sol/L2GatewayUpgrade.json"
            );
    }

    /// @notice Reads the bytecode of the L2GatewayUpgrade contract.
    /// @return The bytecode of the L2GatewayUpgrade contract.
    function readL2AdminFactoryBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/governance/L2AdminFactory.sol/L2AdminFactory.json"
            );
    }

    function readProxyAdminBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol/ProxyAdmin.json"
            );
    }

    /// @notice Reads the bytecode of the L2GatewayUpgrade contract.
    /// @return The bytecode of the L2GatewayUpgrade contract.
    function readPermanentRestrictionBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/governance/PermanentRestriction.sol/PermanentRestriction.json"
            );
    }

    /// @notice Reads the bytecode of the L2ProxyAdminDeployer contract.
    /// @return The bytecode of the L2ProxyAdminDeployer contract.
    function readProxyAdminDeployerBytecode() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/governance/L2ProxyAdminDeployer.sol/L2ProxyAdminDeployer.json"
            );
    }

    /// @notice Reads the bytecode of the L2WrappedBaseToken contract.
    /// @return The bytecode of the L2WrappedBaseToken contract.
    function readL2WrappedBaseToken() internal view returns (bytes memory) {
        return
            Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/L2WrappedBaseToken.sol/L2WrappedBaseToken.json"
            );
    }
}
