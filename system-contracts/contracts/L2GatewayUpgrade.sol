// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";

import {L2GenesisUpgradeHelper} from "./L2GenesisUpgradeHelper.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

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

        address l2LegacyBridgeAddress = additionalForceDeploymentsData.l2LegacySharedBridge;

        if (l2LegacyBridgeAddress != address(0)) {
            FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
                _fixedForceDeploymentsData,
                (FixedForceDeploymentsData)
            );

            // Firstly, upgrade the legacy L2SharedBridge
            bytes memory bridgeUpgradeData = abi.encodeCall(
                ITransparentUpgradeableProxy.upgradeTo,
                (fixedForceDeploymentsData.l2SharedBridgeLegacyImpl)
            );
            SystemContractHelper.mimicCallWithPropagatedRevert(
                l2LegacyBridgeAddress,
                fixedForceDeploymentsData.l2BridgeProxyOwnerAddress,
                bridgeUpgradeData
            );

            // Secondly, upgrade the tokens
            UpgradeableBeacon upgradableBeacon = IL2SharedBridgeLegacy(l2LegacyBridgeAddress).l2TokenBeacon();
            bytes memory beaconUpgradeData = abi.encodeCall(
                UpgradeableBeacon.upgradeTo,
                (fixedForceDeploymentsData.l2BridgedStandardERC20Impl)
            );
            SystemContractHelper.mimicCallWithPropagatedRevert(
                address(upgradableBeacon),
                fixedForceDeploymentsData.l2BridgedStandardERC20ProxyOwnerAddress,
                beaconUpgradeData
            );
        }
    }
}
