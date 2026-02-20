// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    /// @notice E2e upgrade generation
    function run() public virtual override {
        revert(
            "CTMUpgrade_v31.run() is deprecated. Use --sig initializeWithArgs(...) and call preparation methods explicitly"
        );
    }

    function initialize(
        string memory permanentValuesInputPath,
        string memory newConfigPath,
        string memory upgradeEcosystemOutputPath
    ) public virtual override {
        permanentValuesInputPath;
        newConfigPath;
        upgradeEcosystemOutputPath;
        revert("CTMUpgrade_v31.initialize(permanent-values path,...) is deprecated. Use initializeWithArgs(...)");
    }

    function initializeWithArgs(
        address ctmProxy,
        address bytecodesSupplier,
        bool isZKsyncOS,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        string memory upgradeEcosystemOutputPath,
        address governance
    ) public virtual override {
        super.initializeWithArgs(
            ctmProxy,
            bytecodesSupplier,
            isZKsyncOS,
            rollupDAManager,
            create2FactorySalt,
            newConfigPath,
            upgradeEcosystemOutputPath,
            governance
        );
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
    ) internal view virtual override returns (address, bytes memory) {
        bytes32 ethAssetId = IL1AssetRouter(address(bridgehub.assetRouter())).ETH_TOKEN_ASSET_ID();
        bytes memory l2UpgradeCalldata = abi.encodeCall(
            IL2V29Upgrade.upgrade,
            (AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress), ethAssetId)
        );
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
            )
        );
    }
}
