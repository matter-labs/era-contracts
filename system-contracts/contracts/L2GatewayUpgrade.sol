// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Storage slot with the admin of the contract used for EIP1967 proxies (e.g., TUP, BeaconProxy, etc.).
bytes32 constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2GatewayUpgrade
/// @notice Facilitates the upgrade of the L2 protocol to a version that supports the gateway.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder due to overlapping functionality with `L2GenesisUpgrade` and to facilitate code reuse.
/// @dev During the upgrade process, this contract will be force-deployed onto the address of the `ComplexUpgrader` system contract, so
/// `this` will take the address of the `ComplexUpgrader`. This approach is used instead of delegate-calling `ComplexUpgrader`
/// to alleviate the need to predeploy the implementation. In the future this limitation will be removed with the new `ComplexUpgrader`
/// functionality.
/// @dev All the logic happens inside the constructor, since once the constructor execution is done, the normal `ComplexUpgrader`
/// bytecode will be deployed back in its place.
contract L2GatewayUpgrade {
    /// @notice Initializes the `L2GatewayUpgrade` contract.
    /// @dev This constructor is intended to be delegate-called by the `ComplexUpgrader` contract.
    /// @param _ctmDeployer Address of the CTM Deployer contract.
    /// @param _fixedForceDeploymentsData Encoded data for fixed force deployments.
    /// @param _additionalForceDeploymentsData Encoded data for ZK-Chain specific force deployments.
    constructor(
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
    ) {
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData
        );

        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );

        address l2LegacyBridgeAddress = additionalForceDeploymentsData.l2LegacySharedBridge;
        if (l2LegacyBridgeAddress != address(0)) {
            // Force upgrade the TransparentUpgradeableProxy for the legacy bridge.
            forceUpgradeTransparentProxy(
                l2LegacyBridgeAddress,
                // We are sure that `impl` is deployed, since it is supposed to be included
                // as part of the "usual" force deployments array.
                fixedForceDeploymentsData.l2SharedBridgeLegacyImpl,
                hex""
            );

            // Force upgrade the UpgradeableBeacon proxy for the bridged standard ERC20.
            forceUpgradeBeaconProxy(
                address(IL2SharedBridgeLegacy(l2LegacyBridgeAddress).l2TokenBeacon()),
                // We are sure that `impl` is deployed, since it is supposed to be included
                // as part of the "usual" force deployments array.
                fixedForceDeploymentsData.l2BridgedStandardERC20Impl
            );
        }
    }

    /// @notice Forces an upgrade of a TransparentUpgradeableProxy contract.
    /// @dev Constructs the appropriate calldata for upgrading the proxy and executes the upgrade
    /// by mimicCall-ing the admin of the proxy.
    /// @param _proxyAddr Address of the TransparentUpgradeableProxy to upgrade.
    /// @param _newImpl Address of the new implementation contract.
    /// @param _additionalData Additional calldata to pass to the `upgradeToAndCall` function, if any.
    function forceUpgradeTransparentProxy(address _proxyAddr, address _newImpl, bytes memory _additionalData) internal {
        bytes memory upgradeData;
        if (_additionalData.length > 0) {
            upgradeData = abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (_newImpl, _additionalData));
        } else {
            upgradeData = abi.encodeCall(ITransparentUpgradeableProxy.upgradeTo, (_newImpl));
        }

        // Retrieve the proxy admin address from the proxy's storage slot.
        address proxyAdmin = address(uint160(uint256(SystemContractHelper.forcedSload(_proxyAddr, PROXY_ADMIN_SLOT))));

        SystemContractHelper.mimicCallWithPropagatedRevert(_proxyAddr, proxyAdmin, upgradeData);
    }

    /// @notice Forces an upgrade of an UpgradeableBeacon proxy contract.
    /// @dev Constructs the appropriate calldata for upgrading the proxy and executes the upgrade
    /// by mimicCall-ing the admin of the proxy.
    /// @param _proxyAddr Address of the UpgradeableBeacon proxy to upgrade.
    /// @param _newImpl Address of the new implementation contract.
    function forceUpgradeBeaconProxy(address _proxyAddr, address _newImpl) internal {
        bytes memory upgradeData = abi.encodeCall(UpgradeableBeacon.upgradeTo, (_newImpl));

        // Retrieve the owner of the beacon.
        address owner = UpgradeableBeacon(_proxyAddr).owner();

        // Execute the upgrade via a low-level call, propagating any revert.
        SystemContractHelper.mimicCallWithPropagatedRevert(_proxyAddr, owner, upgradeData);
    }
}
