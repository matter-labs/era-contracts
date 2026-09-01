// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TODO(EVM-1644): LEGACY UPGRADE PROCESS — remove once the registry-driven upgrade process
// (contracts/upgrades/registry: CTMUpgradeExecutor / EcosystemUpgradeExecutor +
// release/transition registries) has fully replaced off-chain governance-calldata generation. Kept for the
// v34 bootstrap edge, whose L2 payload is still script-composed.

import "../SystemContractsProcessing.s.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {CTMUpgradeBase} from "./CTMUpgradeBase.sol";
import {EraForceDeploymentsLib} from "./EraForceDeploymentsLib.sol";
import {UpgradeHelperLib} from "./UpgradeHelperLib.sol";

/// @notice Default runtime-selected L2 upgrade strategy.
/// @dev CTMUpgradeBase remains VM-neutral; this layer owns the default
///      Era/ZKsyncOS split for scripts that are instantiated before config is
///      initialized.
abstract contract DefaultL2UpgradeStrategy is CTMUpgradeBase {
    function getUniversalForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal virtual override returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        return
            SystemContractsProcessing.mergeUniversalForceDeployments(
                getBaseUniversalForceDeployments(_l1ChainId, _ownerAddress),
                getAdditionalUniversalForceDeployments()
            );
    }

    function getBaseUniversalForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal virtual returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        if (config.isZKsyncOS) {
            return SystemContractsProcessing.getBaseZKsyncOSForceDeployments();
        }

        return
            EraForceDeploymentsLib.wrap(SystemContractsProcessing.getBaseForceDeployments(_l1ChainId, _ownerAddress));
    }

    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        if (config.isZKsyncOS) {
            return getZKsyncOSL2UpgradeTargetAndData(_deployments);
        }

        return getEraL2UpgradeTargetAndData(_deployments);
    }

    function getUpgradeTxType() internal virtual override returns (uint256) {
        return UpgradeHelperLib.getUpgradeTxType(config.isZKsyncOS);
    }

    /// @notice Composes the `ComplexUpgrader` target and calldata via the universal
    ///         `forceDeployAndUpgradeUniversal` entrypoint (from v32 both VMs use it), which
    ///         `L2UpgradeTxLib` validates at rewrite time.
    function getUniversalComplexUpgraderTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        address _delegateTo,
        bytes memory _upgradeCalldata
    ) internal pure returns (address, bytes memory) {
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (_deployments, _delegateTo, _upgradeCalldata)
            )
        );
    }

    /// @notice Get Era L2 upgrade target and data.
    /// @dev From V32 onwards, both Era and ZKsyncOS should use forceDeployAndUpgradeUniversal
    /// (via L2_COMPLEX_UPGRADER_ADDR) since it supports both chain types via ContractUpgradeType.
    /// This default uses forceDeployOnAddresses only because V31 Era chains do not yet
    /// have forceDeployAndUpgradeUniversal deployed.
    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual returns (address, bytes memory) {
        return (
            address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR),
            abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (EraForceDeploymentsLib.unwrap(_deployments)))
        );
    }

    /// @notice Get ZKsyncOS L2 upgrade target and data.
    function getZKsyncOSL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual returns (address, bytes memory) {
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(IComplexUpgrader.forceDeployAndUpgradeUniversal, (_deployments, address(0), ""))
        );
    }
}
