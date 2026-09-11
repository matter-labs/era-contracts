// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../SystemContractsProcessing.s.sol";

import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {CTMUpgradeBase} from "./CTMUpgradeBase.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";

/// @notice Default L2 upgrade strategy for ZKsync OS chains.
abstract contract DefaultL2UpgradeStrategy is CTMUpgradeBase {
    function getUniversalForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal virtual override returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        return
            SystemContractsProcessing.mergeUniversalForceDeployments(
                SystemContractsProcessing.getBaseForceDeployments(),
                getAdditionalUniversalForceDeployments()
            );
    }

    function getUpgradeTxType() internal virtual override returns (uint256) {
        return ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function getComplexUpgraderTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        address _delegateTo,
        bytes memory _upgradeCalldata
    ) internal view returns (address, bytes memory) {
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_deployments, _delegateTo, _upgradeCalldata)
        );

        return (address(L2_COMPLEX_UPGRADER_ADDR), complexUpgraderCalldata);
    }

    /// @notice L2 upgrade target and data. Subclasses override this to route the upgrade through a
    /// different delegate target.
    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(IComplexUpgrader.forceDeployAndUpgradeUniversal, (_deployments, address(0), ""))
        );
    }
}
