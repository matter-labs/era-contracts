// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";

import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {StateTransitionDeployedAddresses, ChainCreationParamsConfig} from "../../utils/Types.sol";
import {PublishFactoryDepsResult} from "../default-upgrade/CTMUpgradeBase.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {DefaultGatewayUpgrade} from "../default-upgrade/DefaultGatewayUpgrade.s.sol";

/// @notice Script used for gateway upgrade flow. Not used in V31, but was used in V29 and will be used in V32.
contract GatewayUpgrade_v31 is Script, DefaultGatewayUpgrade {
    function getForceDeploymentContracts() internal override returns (CoreContract[] memory forceDeploymentContracts) {
        if (config.isZKsyncOS) {
            return new CoreContract[](0);
        }
        forceDeploymentContracts = new CoreContract[](1);
        forceDeploymentContracts[0] = CoreContract.L2V31Upgrade;
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256,
        address,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 protocolUpgradeNonce
    ) public virtual override returns (ProposedUpgrade memory proposedUpgrade) {
        if (!config.isZKsyncOS) {
            return
                super.getProposedUpgrade(
                    stateTransition,
                    chainCreationParams,
                    config.l1ChainId,
                    config.ownerAddress,
                    _factoryDepsResult,
                    protocolUpgradeNonce
                );
        }

        FixedForceDeploymentsData memory fixedData = getFixedForceDeploymentsData();
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = buildZKsyncOSForceDeployments(fixedData);

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(deployments, _factoryDepsResult, protocolUpgradeNonce),
            bootloaderHash: chainCreationParams.bootloaderHash,
            defaultAccountHash: chainCreationParams.defaultAAHash,
            evmEmulatorHash: chainCreationParams.evmEmulatorHash,
            verifier: address(0),
            verifierParams: getEmptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: chainCreationParams.latestProtocolVersion
        });
    }

    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal view override returns (address, bytes memory) {
        bytes memory l2V31UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (config.isZKsyncOS, address(0), "", "")
        );

        bytes memory complexUpgraderCalldata;
        if (config.isZKsyncOS) {
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (_deployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2V31UpgradeCalldata)
            );
        } else {
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (unwrapEraDeployments(_deployments), L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2V31UpgradeCalldata)
            );
        }

        return (address(L2_COMPLEX_UPGRADER_ADDR), complexUpgraderCalldata);
    }
}
