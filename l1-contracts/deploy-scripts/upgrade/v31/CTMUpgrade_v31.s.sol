// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {Call} from "contracts/governance/Common.sol";

import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {DefaultEcosystemUpgrade} from "../default_upgrade/DefaultEcosystemUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";

import {DefaultCTMUpgrade} from "../default_upgrade/DefaultCTMUpgrade.s.sol";

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
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(
            "EraChainTypeManager",
            false
        );

        deployStateTransitionDiamondFacets();
    }

    /// @notice Override to deploy v31-specific upgrade contract
    /// @dev SettlementLayerV31Upgrade contains the setMigrationNumberForV31() call
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
    ) internal view virtual override returns (address, bytes memory) {
        bytes32 ethAssetId = IL1AssetRouter(address(bridgehub.assetRouter())).ETH_TOKEN_ASSET_ID();
        bytes memory v29UpgradeCalldata = abi.encodeCall(
            IL2V29Upgrade.upgrade,
            (AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress), ethAssetId)
        );
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, v29UpgradeCalldata)
            )
        );
    }
}
