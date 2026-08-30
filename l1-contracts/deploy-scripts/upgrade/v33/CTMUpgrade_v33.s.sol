// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {ICTMUpgradeV33} from "contracts/script-interfaces/IUpgradeV33.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";

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
contract CTMUpgrade_v33 is Script, DefaultCTMUpgrade, ICTMUpgradeV33 {
    /// @notice Single-call entry point invoked by the protocol-ops CLI's `ecosystem upgrade-prepare-all`.
    ///         Drives the full CTM-side prepare phase (deploy + bytecode publish + upgrade-cut
    ///         generation + governance/admin call serialization) in one shot.
    function noGovernancePrepare(CTMUpgradeParams memory _params) public {
        initializeWithArgs(
            _params.ctmProxy,
            _params.bytecodesSupplier,
            _params.isZKsyncOS,
            _params.rollupDAManager,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath,
            _params.governance,
            _params.zkTokenAssetId
        );
        if (_params.chainRegistrationSender != address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = _params.chainRegistrationSender;
        }
        prepareCTMUpgrade();
        prepareDefaultGovernanceCalls();
        prepareDefaultCTMAdminCalls();
        // Emit test-only calls (`test_create_chain`, `test_upgrade_chain`) into the CTM output TOML so
        // protocol-ops can lift them into merged `ecosystem.toml` for tx-simulator checks.
        prepareDefaultTestUpgradeCalls();
    }

    /// @notice Deploy everything that should be deployed.
    function deployNewCTMContracts() public virtual override {
        (ctmAddresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        (ctmAddresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        deployVerifiers();

        deployEIP7702Checker();
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();

        // Both proxies were introduced by the v31 upgrade, so every ecosystem this release can upgrade
        // already has them: only their implementations are redeployed, and stage 1 points the discovered
        // proxies at them. Deploying fresh proxies would move the addresses the new CTM implementation is
        // constructed with, leaving each upgraded chain's `s.priorityModeInfo.permissionlessValidator`
        // (written at its v31 upgrade) pointing at the old validator while new chains get the new one.
        require(
            ctmAddresses.stateTransition.proxies.bytecodesSupplier != address(0),
            "CTM has no BytecodesSupplier registered; it is expected from v31 on"
        );
        require(
            ctmAddresses.stateTransition.proxies.permissionlessValidator != address(0),
            "CTM has no PermissionlessValidator registered; it is expected from v31 on"
        );
        ctmAddresses.stateTransition.implementations.bytecodesSupplier = deploySimpleContract(
            "BytecodesSupplier",
            false
        );
        ctmAddresses.stateTransition.implementations.permissionlessValidator = deploySimpleContract(
            "PermissionlessValidator",
            false
        );

        // The constructor receives the new BytecodesSupplier and PermissionlessValidator proxy addresses.
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);

        // Deploy `MultisigCommitter` (a superset of ValidatorTimelock) as the default validator impl so the
        // upgrade does NOT downgrade proxies that already run a MultisigCommitter.
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract(
            "MultisigCommitter",
            false
        );

        deployStateTransitionDiamondFacets();
    }

    /// @notice Append the proxy-admin upgrades of the CTM-side proxies this release keeps to the stage-1
    ///         governance bundle.
    /// @dev Plain `ProxyAdmin.upgrade` (not `upgradeAndCall`) for all three: the new implementations are
    ///      deployed with no reinitializer call. For the validator timelock in particular, proxies already
    ///      running a `MultisigCommitter` are at `_initialized=2` with their multisig storage intact, so the
    ///      swap just restores the multisig code; calling `reinitializeV2()` again would revert "already
    ///      initialized".
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        calls = new Call[](3);
        calls[0] = _buildProxyImplementationUpgrade(
            ctmAddresses.stateTransition.proxies.validatorTimelock,
            ctmAddresses.stateTransition.implementations.validatorTimelock,
            "validatorTimelock"
        );
        calls[1] = _buildProxyImplementationUpgrade(
            ctmAddresses.stateTransition.proxies.bytecodesSupplier,
            ctmAddresses.stateTransition.implementations.bytecodesSupplier,
            "bytecodesSupplier"
        );
        calls[2] = _buildProxyImplementationUpgrade(
            ctmAddresses.stateTransition.proxies.permissionlessValidator,
            ctmAddresses.stateTransition.implementations.permissionlessValidator,
            "permissionlessValidator"
        );
    }

    function _buildProxyImplementationUpgrade(
        address _proxy,
        address _implementation,
        string memory _name
    ) private view returns (Call memory) {
        require(_proxy != address(0), string.concat("v33: ", _name, " proxy not set"));
        require(_implementation != address(0), string.concat("v33: ", _name, " impl not deployed"));

        return
            Call({
                target: Utils.getProxyAdminAddress(_proxy),
                data: abi.encodeCall(
                    ProxyAdmin.upgrade,
                    (ITransparentUpgradeableProxy(payable(_proxy)), _implementation)
                ),
                value: 0
            });
    }

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
