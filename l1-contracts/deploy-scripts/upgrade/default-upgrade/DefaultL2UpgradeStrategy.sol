// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";
import {Utils} from "../../utils/Utils.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";

import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2DefaultUpgrade} from "contracts/upgrades/IL2DefaultUpgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {CTMUpgradeBase} from "./CTMUpgradeBase.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";

/// @notice Default L2 upgrade strategy for ZKsync OS chains.
/// @dev The L2 upgrade transaction force-deploys the base contract set together with `L2DefaultUpgrade`,
/// then delegatecalls `L2DefaultUpgrade.upgrade`, whose per-chain data is left as a placeholder that
/// `DefaultUpgradeZKsyncOS` substitutes at upgrade time.
abstract contract DefaultL2UpgradeStrategy is CTMUpgradeBase {
    function getUniversalForceDeployments()
        internal
        virtual
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory l2DefaultUpgradeDeployment = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        l2DefaultUpgradeDeployment[0] = getL2DefaultUpgradeDeployment();

        return
            SystemContractsProcessing.mergeUniversalForceDeployments(
                SystemContractsProcessing.mergeUniversalForceDeployments(
                    SystemContractsProcessing.getBaseForceDeployments(),
                    l2DefaultUpgradeDeployment
                ),
                getAdditionalUniversalForceDeployments()
            );
    }

    /// @notice The bytecodes the upgrade publishes as factory deps: `L2DefaultUpgrade`, which every upgrade
    /// force-deploys, followed by the release-specific {getAdditionalFactoryDependencyContracts}.
    function getFactoryDependencyContracts() internal returns (CoreContract[] memory dependencyContracts) {
        CoreContract[] memory additional = getAdditionalFactoryDependencyContracts();
        dependencyContracts = new CoreContract[](additional.length + 1);
        dependencyContracts[0] = CoreContract.L2DefaultUpgrade;
        for (uint256 i = 0; i < additional.length; ++i) {
            dependencyContracts[i + 1] = additional[i];
        }
    }

    function getUpgradeTxType() internal virtual override returns (uint256) {
        return ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    /// @notice The force deployment of the `L2DefaultUpgrade` delegate target.
    /// @dev `L2DefaultUpgrade` is a standalone contract at an address derived from its bytecode (not the
    /// constant `L2_VERSION_SPECIFIC_UPGRADER_ADDR`, so no existing bytecode is overwritten), hence
    /// `ZKsyncOSUnsafeForceDeployment` rather than `ZKsyncOSSystemProxyUpgrade`.
    function getL2DefaultUpgradeDeployment()
        internal
        virtual
        returns (IComplexUpgrader.UniversalContractUpgradeInfo memory)
    {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2DefaultUpgrade.sol", "L2DefaultUpgrade");
        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo)
            });
    }

    function getComplexUpgraderTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        address _delegateTo,
        bytes memory _upgradeCalldata
    ) internal pure returns (address, bytes memory) {
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_deployments, _delegateTo, _upgradeCalldata)
        );

        return (address(L2_COMPLEX_UPGRADER_ADDR), complexUpgraderCalldata);
    }

    /// @notice L2 upgrade target and data: `forceDeployAndUpgradeUniversal` delegating to `L2DefaultUpgrade`.
    /// Subclasses override this to route the upgrade through a different delegate target.
    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains). The
        // additionalForceDeploymentsData placeholder is rewritten per-chain by
        // DefaultUpgradeZKsyncOS.getL2UpgradeTxData at upgrade time.
        bytes memory upgradeCalldata = abi.encodeCall(
            IL2DefaultUpgrade.upgrade,
            (coreAddresses.bridgehub.proxies.ctmDeploymentTracker, generatedData.forceDeploymentsData, "")
        );

        return
            getComplexUpgraderTargetAndData(_deployments, getL2DefaultUpgradeDeployment().newAddress, upgradeCalldata);
    }
}
