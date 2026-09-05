// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IComplexUpgrader {
    /// @notice The type of contract upgrade.
    /// @param __DEPRECATED_EraForceDeployment ordinal 0, retired: the EraVM force deployment. The
    /// member is kept so the wire ordinals of the live members below never shift; supplying it
    /// reverts with {UnsupportedUpgradeType} in `L2GenesisForceDeploymentsHelper.conductContractUpgrade`.
    /// @param ZKsyncOSSystemProxyUpgrade the upgrade of the system proxy on ZKsyncOS. It will involve force
    /// deployment of both the implementation on an empty address that depends on the bytecode and upgrading the implementation.
    /// In case the proxy has not been initialized yet, it will also involve force deploying the proxy and initializing the admin.
    /// @param ZKsyncOSUnsafeForceDeployment the force deployment for ZKsyncOS. This should be used only
    /// for exceptional cases, when the deployer is certain that the contract does not contain any address
    /// on top of it or overriding the existing bytecode is expected.
    /// The typical use case for an unsafe deployment is to deploy the implementation of the upgrade that the ComplexUpgrader should
    /// delegatecall to. It was also used to migrate the non-proxy system contracts to proxies during the testnet upgrade.
    enum ContractUpgradeType {
        __DEPRECATED_EraForceDeployment,
        ZKsyncOSSystemProxyUpgrade,
        ZKsyncOSUnsafeForceDeployment
    }

    /// @notice Information about the force deployment.
    /// @dev This struct is used to store the information about the force deployment.
    /// @dev The `deployedBytecodeInfo` is the abi-encoded tuple of `(bytes32, uint32, bytes32)`.
    /// @dev Note, that ZKsyncOS does not support constructors, so the `deployedBytecodeInfo` should only describe the
    /// deployed bytecode.
    /// @param upgradeType the type of the upgrade.
    /// @param deployedBytecodeInfo the bytecode information for deployment.
    /// @param newAddress the address where the contract should be deployed.
    // solhint-disable-next-line gas-struct-packing
    struct UniversalContractUpgradeInfo {
        ContractUpgradeType upgradeType;
        bytes deployedBytecodeInfo;
        address newAddress;
    }

    /// @notice Executes upgrade with universal force deployments.
    /// @param _forceDeployments Universal deployment descriptors.
    /// @param _delegateTo Target contract for delegatecall.
    /// @param _calldata Calldata passed to delegate target.
    function forceDeployAndUpgradeUniversal(
        UniversalContractUpgradeInfo[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}
