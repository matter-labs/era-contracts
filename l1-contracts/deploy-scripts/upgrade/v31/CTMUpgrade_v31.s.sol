// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    GW_ASSET_TRACKER_ADDR,
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IComplexUpgraderZKsyncOSV29} from "contracts/state-transition/l2-deps/IComplexUpgraderZKsyncOSV29.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";
import {Utils} from "../../utils/Utils.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("UPGRADE_CTM_INPUT"),
            vm.envString("UPGRADE_CTM_OUTPUT")
        );
        prepareCTMUpgrade();

        /// kl todo check that no chain is on GW. We can write a contract to check it and call it in V31 stage 0 calls.

        prepareDefaultGovernanceCalls();
    }

    function initialize(
        string memory permanentValuesInputPath,
        string memory newConfigPath,
        string memory upgradeEcosystemOutputPath
    ) public virtual override {
        super.initialize(permanentValuesInputPath, newConfigPath, upgradeEcosystemOutputPath);
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
        string memory ctmContractName = config.isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        deployStateTransitionDiamondFacets();
    }

    /// @notice Override to deploy v31-specific upgrade contract
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        console.log("Deploying SettlementLayerV31Upgrade as the chain upgrade contract");
        return deploySimpleContract("SettlementLayerV31Upgrade", false);
    }

    function getForceDeploymentNames() internal override returns (string[] memory forceDeploymentNames) {
        forceDeploymentNames = new string[](1);
        forceDeploymentNames[0] = "L2V31Upgrade";
    }

    function getExpectedL2Address(string memory contractName) public override returns (address) {
        if (compareStrings(contractName, "L2V31Upgrade")) {
            return address(L2_VERSION_SPECIFIC_UPGRADER_ADDR);
        }

        return super.getExpectedL2Address(contractName);
    }

    function getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal virtual override returns (address, bytes memory) {
        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains).
        // The additionalForceDeploymentsData placeholder is rewritten per-chain by
        // SettlementLayerV31Upgrade.getL2V31UpgradeCalldata at upgrade time.
        bytes memory l2UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (config.isZKsyncOS, address(0), newlyGeneratedData.fixedForceDeploymentsData, "")
        );

        if (config.isZKsyncOS) {
            if (newConfig.useV29IntrospectionOverride) {
                // v29 ZKsyncOS ComplexUpgrader uses the v29 ABI variant.
                IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo[]
                    memory v29ForceDeployments = new IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo[](1);
                v29ForceDeployments[0] = IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo({
                    isZKsyncOS: true,
                    deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade"),
                    newAddress: L2_VERSION_SPECIFIC_UPGRADER_ADDR
                });

                return (
                    address(L2_COMPLEX_UPGRADER_ADDR),
                    abi.encodeCall(
                        IComplexUpgraderZKsyncOSV29.forceDeployAndUpgradeUniversal,
                        (v29ForceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
                    )
                );
            }

            // v30+ ZKsyncOS ComplexUpgrader uses the current ABI.
            // Include all system contracts in the outer force deployment list so
            // that the test harness (which reads addresses from this list) can
            // pre-deploy EVM bytecodes at every address the upgrade touches.
            IComplexUpgrader.UniversalContractUpgradeInfo[]
                memory universalForceDeployments = _buildZKsyncOSForceDeployments();

            return (
                address(L2_COMPLEX_UPGRADER_ADDR),
                abi.encodeCall(
                    IComplexUpgrader.forceDeployAndUpgradeUniversal,
                    (universalForceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
                )
            );
        }

        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
            )
        );
    }

    /// @dev Build the full ZKsyncOS force deployment array from FixedForceDeploymentsData.
    /// Maps each bytecodeInfo field to its well-known L2 address and includes L2V31Upgrade.
    /// TODO: The base system contract entries could be moved to CTMUpgradeBase for reuse
    /// by future version upgrades. Kept here for now since it references v31-specific data.
    function _buildZKsyncOSForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        FixedForceDeploymentsData memory data = abi.decode(
            newlyGeneratedData.fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );

        // All system contracts that performForceDeployedContractsInit deploys via
        // conductContractUpgrade, plus contracts called during the upgrade (GWAssetTracker,
        // WrappedBaseToken), plus the L2V31Upgrade delegateTo target.
        uint256 count = 12;
        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](count);

        uint256 i = 0;
        deployments[i++] = _zkosEntry(data.messageRootBytecodeInfo, address(L2_MESSAGE_ROOT_ADDR));
        deployments[i++] = _zkosEntry(data.bridgehubBytecodeInfo, address(L2_BRIDGEHUB_ADDR));
        deployments[i++] = _zkosEntry(data.l2AssetRouterBytecodeInfo, address(L2_ASSET_ROUTER_ADDR));
        deployments[i++] = _zkosEntry(data.l2NtvBytecodeInfo, L2_NATIVE_TOKEN_VAULT_ADDR);
        deployments[i++] = _zkosEntry(data.chainAssetHandlerBytecodeInfo, address(L2_CHAIN_ASSET_HANDLER_ADDR));
        deployments[i++] = _zkosEntry(data.assetTrackerBytecodeInfo, L2_ASSET_TRACKER_ADDR);
        deployments[i++] = _zkosEntry(data.interopCenterBytecodeInfo, address(L2_INTEROP_CENTER_ADDR));
        deployments[i++] = _zkosEntry(data.interopHandlerBytecodeInfo, address(L2_INTEROP_HANDLER_ADDR));
        deployments[i++] = _zkosEntry(data.baseTokenHolderBytecodeInfo, L2_BASE_TOKEN_HOLDER_ADDR);
        // GWAssetTracker and WrappedBaseToken: called during upgrade (initL2, _ensureWethToken)
        // but not deployed via conductContractUpgrade — include as unsafe force deployments.
        deployments[i++] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("GWAssetTracker.sol", "GWAssetTracker"),
            newAddress: GW_ASSET_TRACKER_ADDR
        });
        deployments[i++] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("L2WrappedBaseToken.sol", "L2WrappedBaseToken"),
            newAddress: L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
        });
        // L2V31Upgrade: the delegateTo target
        deployments[i++] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade"),
            newAddress: L2_VERSION_SPECIFIC_UPGRADER_ADDR
        });
    }

    function _zkosEntry(
        bytes memory _bytecodeInfo,
        address _addr
    ) private pure returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        return IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
            deployedBytecodeInfo: _bytecodeInfo,
            newAddress: _addr
        });
    }

}
