// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {L2EcosystemContract} from "../../ecosystem/CoreContract.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    /// @notice Single-call entry point invoked by the protocol-ops CLI's `ecosystem upgrade-prepare-all`.
    ///         Mirrors `CoreUpgrade_v31.noGovernancePrepare`: drives the full CTM-side prepare phase
    ///         (deploy + bytecode publish + upgrade-cut generation + governance/admin call serialization)
    ///         in one shot so the caller doesn't need to chain `initializeWithArgs` → `prepareCTMUpgrade`
    ///         → call-serialization helpers over forge-script invocations.
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

        // Emit test-only calls (`test_create_chain`, `test_upgrade_chain`) into
        // the CTM output TOML so protocol-ops can lift them into merged
        // `ecosystem.toml` for tx-simulator checks.
        prepareDefaultTestUpgradeCalls();
    }

    /// @notice Deploy everything that should be deployed
    function deployNewCTMContracts() public virtual override {
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

        // Deploy new ChainTypeManager implementation
        // The constructor will receive the new BytecodesSupplier and PermissionlessValidator proxy addresses.
        // Select the correct ChainTypeManager based on chain type (Era vs ZKsyncOS)
        // FIXME we never actually use deploySimpleContract or deploy TUPP with anything else than false. We need to clean this code.
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        // Deploy new ServerNotifier implementation
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);

        // v31 adds `UPGRADER_ROLE` + `upgradeChainFromVersion()` (IChainUpgrader) to ValidatorTimelock;
        // existing chains' proxy still points at the v30 impl, so swap it under the same CREATE2 flow.
        // Deploy `MultisigCommitter` (a superset of ValidatorTimelock) as the default validator impl so the
        // upgrade does NOT downgrade proxies that already run a MultisigCommitter — the v31 stage-1 upgrade
        // previously deployed plain `ValidatorTimelock` here, which silently dropped multisig-commit support.
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract(
            "MultisigCommitter",
            false
        );

        // `deployStateTransitionDiamondFacets` also deploys the genesis `CTMRelease`, whose manifest
        // embeds the fixed force-deployments data, so that data must exist before the release deploy
        // rather than only by the later `generateUpgradeData` step. It is artifact-derived and cached,
        // so the later call is a no-op. Same ordering as the v32 script.
        getFixedForceDeploymentsData();

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
        require(_proxy != address(0), string.concat("v31: ", _name, " proxy not set"));
        require(_implementation != address(0), string.concat("v31: ", _name, " impl not deployed"));

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

    /// @notice Override to deploy the per-chain upgrade contract.
    /// @dev Only ZKsync OS chains can be upgraded onto this release. There is no Era counterpart, and
    ///      falling back to the v31 one would generate an upgrade that re-runs v31's one-time work, so this
    ///      refuses to produce anything for Era instead.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        require(config.isZKsyncOS, "Upgrading Era chains onto this release is not supported");

        // The registry must exist first: the v32 upgrade contract embeds its address as an immutable.
        priorityOpLowerBound = deploySimpleContract("PriorityOpLowerBound", false);
        console.log("Deployed PriorityOpLowerBound at", priorityOpLowerBound);

        console.log("Deploying V32UpgradeZKsyncOS");
        return deploySimpleContract("V32UpgradeZKsyncOS", false);
    }

    function getV31AdditionalFactoryDependencyContracts()
        internal
        pure
        returns (L2EcosystemContract[] memory additionalDependencyContracts)
    {
        additionalDependencyContracts = new L2EcosystemContract[](1);
        additionalDependencyContracts[0] = L2EcosystemContract.L2V32Upgrade;
    }

    function getAdditionalFactoryDependencyContracts()
        internal
        override
        returns (L2EcosystemContract[] memory additionalDependencyContracts)
    {
        return getV31AdditionalFactoryDependencyContracts();
    }

    function getAdditionalUniversalForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        if (config.isZKsyncOS) {
            return getV31AdditionalZKsyncOSUniversalForceDeployments();
        }

        return buildEraUniversalForceDeployments(getV31AdditionalFactoryDependencyContracts());
    }

    function getV31L2UpgradeCalldata() internal returns (bytes memory) {
        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains).
        // The additionalForceDeploymentsData placeholder is rewritten per-chain by
        // DefaultUpgradeZKsyncOS.getL2UpgradeTxData at upgrade time.
        return
            abi.encodeCall(
                IL2V32Upgrade.upgrade,
                (
                    config.isZKsyncOS,
                    coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                    generatedData.forceDeploymentsData,
                    ""
                )
            );
    }

    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        return
            getComplexUpgraderTargetAndData(_deployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, getV31L2UpgradeCalldata());
    }

    /// @notice V31-specific: include L2V32Upgrade as an additional ZKsyncOS force deployment.
    /// @dev L2V32Upgrade is deployed as a standalone contract at the derived random address used as
    /// the delegate target in `forceDeployAndUpgradeUniversal`, so it uses `ZKsyncOSUnsafeForceDeployment`
    /// rather than `ZKsyncOSSystemProxyUpgrade`.
    function getV31AdditionalZKsyncOSUniversalForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
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
        // For ZKsyncOS, the delegateTo address is a derived address (not the constant
        // L2_VERSION_SPECIFIC_UPGRADER_ADDR) to avoid overwriting existing bytecode.
        // Must match the newAddress in getV31AdditionalZKsyncOSUniversalForceDeployments.
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V32Upgrade.sol", "L2V32Upgrade");
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo);

        return getComplexUpgraderTargetAndData(_deployments, delegateTo, getV31L2UpgradeCalldata());
    }
}
