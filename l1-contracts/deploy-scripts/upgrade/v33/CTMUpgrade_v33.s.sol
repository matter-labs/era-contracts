// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";
import {IPriorityOpLowerBound} from "contracts/upgrades/IPriorityOpLowerBound.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {DeployCTMUtils} from "../../ctm/DeployCTMUtils.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";

/// @notice CTM-side half of the v33 upgrade flow, invoked once per CTM proxy.
///
/// @dev Extends {DefaultCTMUpgrade} directly rather than `CTMUpgrade_v31`, for the reasons given on
///      {CoreUpgrade_v33}. The default scaffold deploys only the stage validator and the governance
///      timer and picks the EraVM `DefaultUpgrade` as the per-chain upgrade contract, so everything
///      that makes this release a release is supplied here.
///
/// @dev v33 is ZKsync OS-only. {noGovernancePrepare} rejects an EraVM CTM up front rather than
///      letting the run get as far as deploying contracts, and the Era force-deployment and
///      L2-upgrade-calldata branches the v31 script carried are omitted rather than left as dead
///      code.
///
/// @dev The per-chain upgrade contract is still named `V32UpgradeZKsyncOS`, and the L2 side
///      `L2V32Upgrade`: this release was developed as v32 and renumbered to v33 when genesis moved
///      to `0.33.0`. The contracts are the v33 payload; only their names lag, and renaming them
///      would churn the bytecode vendored by zksync-os-server.
contract CTMUpgrade_v33 is Script, DefaultCTMUpgrade {
    /// @notice Priority-op lower-bound registry, deployed alongside the per-chain upgrade contract
    ///         which embeds it as an immutable. Lives here rather than in `DeployCTMUtils` because
    ///         nothing outside this release knows about it.
    address internal priorityOpLowerBound;

    /// @inheritdoc DeployCTMUtils
    /// @dev Supplies the registry to `V32UpgradeZKsyncOS`'s constructor; everything else falls
    ///      through to the shared implementation.
    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (keccak256(bytes(contractName)) == keccak256(bytes("V32UpgradeZKsyncOS"))) {
            require(priorityOpLowerBound != address(0), "PriorityOpLowerBound not deployed");
            return abi.encode(priorityOpLowerBound);
        }
        return super.getCreationCalldata(contractName, isZKBytecode);
    }

    /// @inheritdoc DefaultCTMUpgrade
    function serializeVersionSpecificStateTransition() internal virtual override {
        require(priorityOpLowerBound != address(0), "PriorityOpLowerBound not deployed");
        vm.serializeAddress("state_transition", "priority_op_lower_bound_addr", priorityOpLowerBound);
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev `V32UpgradeZKsyncOS` reverts with `LowerBoundNotRecorded()` unless the chain's
    ///      priority-op lower bound was pinned first, so the smoke test has to pin it. The call is
    ///      permissionless, which is why it can share the chain admin's sender rather than needing
    ///      one of its own. On a real rollout this is `protocol_ops chain
    ///      record-priority-op-lower-bound`, run per chain between the governance ceremony and the
    ///      diamond cut; here it just makes the generated smoke test self-contained.
    function TESTONLY_prepareVersionSpecificTestUpgradePrerequisites(
        address _chainDiamondProxyAddress
    ) internal virtual override returns (Call[] memory prerequisites) {
        require(priorityOpLowerBound != address(0), "PriorityOpLowerBound not deployed");

        prerequisites = new Call[](1);
        prerequisites[0] = Call({
            target: priorityOpLowerBound,
            data: abi.encodeCall(IPriorityOpLowerBound.lowerBoundPriorityOp, (_chainDiamondProxyAddress)),
            value: 0
        });
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Refuses an EraVM CTM before anything is deployed. There is no Era counterpart to this
    ///      release's per-chain upgrade, so a run that got further would either fail late or, worse,
    ///      produce a bundle for an upgrade that cannot be applied.
    function noGovernancePrepare(CTMUpgradeParams memory _params) public virtual override {
        require(_params.isZKsyncOS, "v33 is a ZKsync OS-only release; EraVM CTMs are not supported");
        super.noGovernancePrepare(_params);
    }

    /// @notice Deploy the per-chain upgrade contract.
    /// @dev Only ZKsync OS chains can be upgraded onto this release. There is no Era counterpart, and
    ///      falling back to the v31 one would generate an upgrade that re-runs v31's one-time work, so this
    ///      refuses to produce anything for Era instead.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
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
