// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";

/// @notice CTM-side half of the v33 upgrade flow, invoked once per CTM proxy.
///
/// @dev Extends {DefaultCTMUpgrade} directly rather than `CTMUpgrade_v31`, for the reasons given on
///      {CoreUpgrade_v33}. The default scaffold deploys only the stage validator and the governance
///      timer and picks the EraVM `DefaultUpgrade` as the per-chain upgrade contract, so everything
///      that makes this release a release is supplied here.
///
/// @dev v33 is ZKsync OS-only: {deployUsedUpgradeContract} rejects Era CTMs, and consequently the
///      Era force-deployment and L2-upgrade-calldata branches the v31 script carried are omitted
///      rather than left as dead code.
///
/// @dev The per-chain upgrade contract is still named `V32UpgradeZKsyncOS`, and the L2 side
///      `L2V32Upgrade`: this release was developed as v32 and renumbered to v33 when genesis moved
///      to `0.33.0`. The contracts are the v33 payload; only their names lag, and renaming them
///      would churn the bytecode vendored by zksync-os-server.
contract CTMUpgrade_v33 is Script, DefaultCTMUpgrade {
    /// @notice Deploy the per-chain upgrade contract.
    /// @dev Only ZKsync OS chains can be upgraded onto this release. There is no Era counterpart, and
    ///      falling back to the v31 one would generate an upgrade that re-runs v31's one-time work, so this
    ///      refuses to produce anything for Era instead.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        require(config.isZKsyncOS, "Upgrading Era chains onto this release is not supported");

        // The registry must exist first: the upgrade contract embeds its address as an immutable.
        priorityOpLowerBound = deploySimpleContract("PriorityOpLowerBound", false);
        console.log("Deployed PriorityOpLowerBound at", priorityOpLowerBound);

        console.log("Deploying V32UpgradeZKsyncOS");
        return deploySimpleContract("V32UpgradeZKsyncOS", false);
    }

    function getAdditionalFactoryDependencyContracts()
        internal
        pure
        override
        returns (CoreContract[] memory additionalDependencyContracts)
    {
        additionalDependencyContracts = new CoreContract[](1);
        additionalDependencyContracts[0] = CoreContract.L2V32Upgrade;
    }

    function getAdditionalUniversalForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        require(config.isZKsyncOS, "Upgrading Era chains onto this release is not supported");

        // L2V32Upgrade is deployed as a standalone contract at the derived address used as the delegate
        // target in `forceDeployAndUpgradeUniversal`, so it uses `ZKsyncOSUnsafeForceDeployment` rather
        // than `ZKsyncOSSystemProxyUpgrade`.
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V32Upgrade.sol", "L2V32Upgrade");
        additional = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        additional[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: bytecodeInfo,
            newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo)
        });
    }

    function getZKsyncOSL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        // The delegateTo address is a derived address (not the constant L2_VERSION_SPECIFIC_UPGRADER_ADDR)
        // to avoid overwriting existing bytecode. Must match the newAddress above.
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V32Upgrade.sol", "L2V32Upgrade");
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo);

        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains). The
        // additionalForceDeploymentsData placeholder is rewritten per-chain by
        // DefaultUpgradeZKsyncOS.getL2UpgradeTxData at upgrade time.
        bytes memory upgradeCalldata = abi.encodeCall(
            IL2V32Upgrade.upgrade,
            (
                config.isZKsyncOS,
                coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                generatedData.forceDeploymentsData,
                ""
            )
        );

        return getComplexUpgraderTargetAndData(_deployments, delegateTo, upgradeCalldata);
    }
}
