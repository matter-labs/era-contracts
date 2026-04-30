// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {EraForceDeploymentsLib} from "../default-upgrade/EraForceDeploymentsLib.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    /// @notice Single-call entry point invoked by the protocol-ops CLI.
    ///         One invocation per CTM (e.g. ZKsyncOS, EraVM) — combined with a separate
    ///         `CoreUpgrade_v31.noGovernancePrepare` run on the same anvil session, this
    ///         replaces the monolithic `EcosystemUpgrade_v31.noGovernancePrepare` flow.
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

        // Deploy new ChainTypeManager implementation
        // The constructor will receive the new BytecodesSupplier proxy address
        // Select the correct ChainTypeManager based on chain type (Era vs ZKsyncOS)
        // FIXME we never actually use deploySimpleContract or deploy TUPP with anything else than false. We need to clean this code.
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        deployStateTransitionDiamondFacets();
    }

    /// @notice Override to deploy the correct v31 upgrade contract based on chain type.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        string memory contractName = config.isZKsyncOS
            ? "ZKsyncOSSettlementLayerV31Upgrade"
            : "EraSettlementLayerV31Upgrade";
        console.log("Deploying", contractName);
        return deploySimpleContract(contractName, false);
    }

    function getAdditionalForcedCoreContracts()
        internal
        override
        returns (CoreContract[] memory additionalForcedCoreContracts)
    {
        additionalForcedCoreContracts = new CoreContract[](1);
        additionalForcedCoreContracts[0] = CoreContract.L2V31Upgrade;
    }

    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains).
        // The additionalForceDeploymentsData placeholder is rewritten per-chain by
        // SettlementLayerV31UpgradeBase._buildL2V31UpgradeCalldata at upgrade time.
        bytes memory l2UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            // additionalForceDeploymentsData ("") is rewritten per-chain by SettlementLayerV31UpgradeBase
            (
                config.isZKsyncOS,
                coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                generatedData.forceDeploymentsData,
                ""
            )
        );

        bytes memory complexUpgraderCalldata;
        if (config.isZKsyncOS) {
            // For ZKsyncOS, the delegateTo address is a derived address (not the constant
            // L2_VERSION_SPECIFIC_UPGRADER_ADDR) to avoid overwriting existing bytecode.
            // Must match the newAddress in getAdditionalZKsyncOSForceDeployments.
            bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
            address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo);
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (_deployments, delegateTo, l2UpgradeCalldata)
            );
        } else {
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (EraForceDeploymentsLib.unwrap(_deployments), L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
            );
        }

        return (address(L2_COMPLEX_UPGRADER_ADDR), complexUpgraderCalldata);
    }

    /// @notice V31-specific: include L2V31Upgrade as an additional ZKsyncOS force deployment.
    /// @dev L2V31Upgrade is deployed as a standalone contract at the derived random address used as
    /// the delegate target in `forceDeployAndUpgradeUniversal`, so it uses `ZKsyncOSUnsafeForceDeployment`
    /// rather than `ZKsyncOSSystemProxyUpgrade`.
    function getAdditionalZKsyncOSForceDeployments()
        internal
        override
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
}
