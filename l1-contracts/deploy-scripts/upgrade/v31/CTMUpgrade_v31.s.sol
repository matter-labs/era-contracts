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

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
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
        prepareCTMUpgrade();
        prepareDefaultGovernanceCalls();
        prepareDefaultCTMAdminCalls();
    }

    /// @notice Deploy everything that should be deployed
    function deployNewCTMContracts() public virtual override {
        (ctmAddresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        (ctmAddresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        deployVerifiers();

        deployEIP7702Checker();
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();

        // Deploy BytecodesSupplier as TUPP (was a simple contract in old version)
        // This creates both implementation and proxy
        (
            ctmAddresses.stateTransition.implementations.bytecodesSupplier,
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        ) = deployTuppWithContract("BytecodesSupplier", false);

        (
            ctmAddresses.stateTransition.implementations.permissionlessValidator,
            ctmAddresses.stateTransition.proxies.permissionlessValidator
        ) = deployTuppWithContract("PermissionlessValidator", false);

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
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract(
            "ValidatorTimelock",
            false
        );

        deployStateTransitionDiamondFacets();
    }

    /// @notice Append the ValidatorTimelock proxy-admin upgrade to the stage-1 governance bundle.
    /// @dev The new impl has no reinitializer — `ProxyAdmin.upgrade` (not `upgradeAndCall`) is enough.
    function prepareVersionSpecificStage1GovernanceCallsL1()
        public
        virtual
        override
        returns (Call[] memory calls)
    {
        address validatorTimelockProxy = ctmAddresses.stateTransition.proxies.validatorTimelock;
        address newImpl = ctmAddresses.stateTransition.implementations.validatorTimelock;
        require(validatorTimelockProxy != address(0), "v31: validatorTimelock proxy not set");
        require(newImpl != address(0), "v31: validatorTimelock impl not deployed");

        address proxyAdminAddr = Utils.getProxyAdminAddress(validatorTimelockProxy);

        calls = new Call[](1);
        calls[0] = Call({
            target: proxyAdminAddr,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(validatorTimelockProxy)), newImpl)
            ),
            value: 0
        });
    }

    /// @notice Override to deploy the correct v31 upgrade contract based on chain type.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        string memory contractName = config.isZKsyncOS
            ? "ZKsyncOSSettlementLayerV31Upgrade"
            : "EraSettlementLayerV31Upgrade";
        console.log("Deploying", contractName);
        return deploySimpleContract(contractName, false);
    }

    function getV31AdditionalFactoryDependencyContracts()
        internal
        pure
        returns (CoreContract[] memory additionalDependencyContracts)
    {
        additionalDependencyContracts = new CoreContract[](1);
        additionalDependencyContracts[0] = CoreContract.L2V31Upgrade;
    }

    function getAdditionalFactoryDependencyContracts()
        internal
        override
        returns (CoreContract[] memory additionalDependencyContracts)
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
        // SettlementLayerV31UpgradeBase._buildL2V31UpgradeCalldata at upgrade time.
        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
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

    /// @notice V31-specific: include L2V31Upgrade as an additional ZKsyncOS force deployment.
    /// @dev L2V31Upgrade is deployed as a standalone contract at the derived random address used as
    /// the delegate target in `forceDeployAndUpgradeUniversal`, so it uses `ZKsyncOSUnsafeForceDeployment`
    /// rather than `ZKsyncOSSystemProxyUpgrade`.
    function getV31AdditionalZKsyncOSUniversalForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
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
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo);

        return getComplexUpgraderTargetAndData(_deployments, delegateTo, getV31L2UpgradeCalldata());
    }
}
