// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";

import {L2GenesisUpgradeHelper} from "./L2GenesisUpgradeHelper.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Storage slot with the admin of the contract used for EIP1967 proxies (e.g. TUP, BeaconProxy, etc).
bytes32 constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that is used for facilitating the upgrade of the L2
/// to the protocol version that supports gateway
/// @dev This contract is neither predeployed nor a system contract. It is located
/// in this folder due to very overlapping functionality with `L2GenesisUpgrade` and
/// facilitating reusage of the code.
/// @dev During the upgrade, it will be delegate-called by the `ComplexUpgrader` contract.
contract L2GatewayUpgrade {
    /// @dev Note that this contract will be deployed inside the `ComplexUpgrader` contracts'
    /// address and the upgrade logic will reside in the constructor.
    /// This is needed because we can not be sure that the implementation contract for the
    /// `ComplexUpgrader` was deployed before.
    constructor(
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
    ) {
        // Secondly, we perform the more complex deployment of the gateway contracts.
        L2GenesisUpgradeHelper.performForceDeployedContractsInit(
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
        address l2WethAddress = additionalForceDeploymentsData.l2Weth;
        if (l2LegacyBridgeAddress != address(0)) {
            forceUpgradeProxy(
                l2LegacyBridgeAddress,
                // We are sure that `impl` is deployed, since it is supposed to included
                // as part of the "usual" force deployments array.
                fixedForceDeploymentsData.l2SharedBridgeLegacyImpl
            );

            forceUpgradeProxy(
                address(IL2SharedBridgeLegacy(l2LegacyBridgeAddress).l2TokenBeacon()),
                // We are sure that `impl` is deployed, since it is supposed to included
                // as part of the "usual" force deployments array.
                fixedForceDeploymentsData.l2BridgedStandardERC20Impl
            );
        }

        if (l2WethAddress != address(0)) {
            forceUpgradeProxy(
                l2WethAddress,
                // We are sure that `impl` is deployed, since it is supposed to included
                // as part of the "usual" force deployments array.
                fixedForceDeploymentsData.l2WethTokenImpl
            );
        }
    }

    function forceUpgradeProxy(
        address _proxyAddr,
        address _newImpl
    ) internal {
        // Note, that here we use the fact that the `upgrade` method signature is the same for both 
        // `UpgradeableBeacon` and `ITransparentUpgradeableProxy`
        bytes memory upgradeData = abi.encodeCall(
            ITransparentUpgradeableProxy.upgradeTo,
            (_newImpl)
        );
        address proxyAdmin = address(uint160(uint256(SystemContractHelper.forcedSload(
            address(_proxyAddr),
            PROXY_ADMIN_SLOT
        ))));
        SystemContractHelper.mimicCallWithPropagatedRevert(
            address(_proxyAddr),
            proxyAdmin,
            upgradeData
        );
    }

    function forceUpgradeAndCallProxy(
        address _proxyAddr,
        address _newImpl,
        bytes memory _initializeData
    ) internal {
        bytes memory upgradeData = abi.encodeCall(
            ITransparentUpgradeableProxy.upgradeToAndCall,
            (_newImpl, _initializeData)
        );
        address proxyAdmin = address(uint160(uint256(SystemContractHelper.forcedSload(
            address(_proxyAddr),
            PROXY_ADMIN_SLOT
        ))));
        SystemContractHelper.mimicCallWithPropagatedRevert(
            address(_proxyAddr),
            proxyAdmin,
            upgradeData
        );
    }

}
