// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig} from "../../utils/Types.sol";
import {Utils} from "../../utils/Utils.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {PublishFactoryDepsResult} from "../default-upgrade/CTMUpgradeBase.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    bytes internal l2V31UpgradeBytecodeInfo;

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

    function getForceDeploymentContracts() internal override returns (CoreContract[] memory forceDeploymentContracts) {
        forceDeploymentContracts = new CoreContract[](1);
        forceDeploymentContracts[0] = CoreContract.L2V31Upgrade;
    }

    // FIXME: the logic in this function is only suitable for the dummy upgrade implementation.
    // Should be rewritten once the full upgrade contract is available.
    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains).
        // The additionalForceDeploymentsData placeholder is rewritten per-chain by
        // SettlementLayerV31UpgradeBase._buildL2V31UpgradeCalldata at upgrade time.
        bytes memory l2UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (config.isZKsyncOS, address(0), newlyGeneratedData.fixedForceDeploymentsData, "")
        );

        bytes memory complexUpgraderCalldata;
        if (config.isZKsyncOS) {
            // For ZKsyncOS, the delegateTo address is a derived address (not the constant
            // L2_VERSION_SPECIFIC_UPGRADER_ADDR) to avoid overwriting existing bytecode.
            // Must match the newAddress in getAdditionalZKsyncOSForceDeployments.
            address delegateTo = _getZKsyncOSUpgradeAddress();
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (_deployments, delegateTo, l2UpgradeCalldata)
            );
        } else {
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (unwrapEraDeployments(_deployments), L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
            );
        }

        return (address(L2_COMPLEX_UPGRADER_ADDR), complexUpgraderCalldata);
    }

    /// @notice V31-specific: include L2V31Upgrade as an additional ZKsyncOS force deployment.
    function getAdditionalZKsyncOSForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        additional = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        additional[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade"),
            newAddress: _getZKsyncOSUpgradeAddress()
        });
    }

    /// @dev Compute the derived address for L2V31Upgrade on ZKsyncOS.
    /// Uses the same derivation as L2GenesisForceDeploymentsHelper.generateRandomAddress:
    /// address(uint160(uint256(keccak256(bytes32(0) ++ bytecodeInfo))))
    /// This avoids overwriting the constant L2_VERSION_SPECIFIC_UPGRADER_ADDR.
    function _getZKsyncOSUpgradeAddress() private returns (address) {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
        return address(uint160(uint256(keccak256(bytes.concat(bytes32(0), bytecodeInfo)))));
    }

    // FIXME: should be rewritten to be more generic once the full upgrade is available.
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

        // For ZKsyncOS v31 upgrades, upgrade the version-specific upgrader via proxy upgrade.
        // Prepare bytecode info for getL2UpgradeTargetAndData (used in composeUpgradeTx).
        l2V31UpgradeBytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo("L2V31Upgrade.sol", "L2V31Upgrade");
        // ZKsyncOS uses UniversalContractUpgradeInfo[] built from buildZKsyncOSForceDeployments().
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = buildZKsyncOSForceDeployments();

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
}
