// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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
        bytes memory l2UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (uint256(0), address(0), "", "", uint256(0))
        );

        if (config.isZKsyncOS) {
            // The tx is executed by the pre-v31 L2ComplexUpgrader, so it must use the
            // latest pre-upgrade ABI exposed on zksync-os-stable.
            IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo[]
                memory universalForceDeployments = new IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo[](1);
            universalForceDeployments[0] = IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo({
                isZKsyncOS: true,
                deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade"),
                newAddress: L2_VERSION_SPECIFIC_UPGRADER_ADDR
            });

            return (
                address(L2_COMPLEX_UPGRADER_ADDR),
                abi.encodeCall(
                    IComplexUpgraderZKsyncOSV29.forceDeployAndUpgradeUniversal,
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
}
