// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";

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
import {DefaultCTMUpgrade} from "../default_upgrade/DefaultCTMUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";
import {DefaultGatewayUpgrade} from "../default_upgrade/DefaultGatewayUpgrade.s.sol";
import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";

/// @notice Script used for v31 upgrade flow
contract EcosystemUpgrade_v31 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        preparePermanentValues();
        initialize(
            "/upgrade-envs/permanent-values/local.toml",
            "/upgrade-envs/v0.31.0-interopB/local.toml",
            vm.envString("V31_UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("V31_UPGRADE_ECOSYSTEM_OUTPUT")
        );

        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// todo create in deploy scripts instead of here.
    function preparePermanentValues() internal {
        string memory root = vm.projectRoot();
        string memory permanentValuesInputPath = string.concat(root, "/upgrade-envs/permanent-values/local.toml");
        string memory outputDeployL1Toml = vm.readFile(string.concat(root, "/script-out/output-deploy-l1.toml"));
        string memory outputDeployCTMToml = vm.readFile(string.concat(root,  "/script-out/output-deploy-ctm.toml"));

        bytes32 create2FactorySalt = outputDeployL1Toml.readBytes32("$.contracts.create2_factory_salt");
        address create2FactoryAddr;
        if (vm.keyExistsToml(outputDeployL1Toml, "$.contracts.create2_factory_addr")) {
            create2FactoryAddr = outputDeployL1Toml.readAddress("$.contracts.create2_factory_addr");
        }
        address ctm = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        address bytecodesSupplier = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.bytecodes_supplier_addr"
        );
        address l1Bridgehub = outputDeployL1Toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        address rollupDAManager = outputDeployCTMToml.readAddress("$.deployed_addresses.l1_rollup_da_manager");
        uint256 eraChainId = outputDeployL1Toml.readUint("$.era_chain_id");

        vm.serializeString("contracts", "create2_factory_salt", vm.toString(create2FactorySalt));
        vm.serializeAddress("contracts", "create2_factory_addr", create2FactoryAddr);
        vm.serializeAddress("contracts", "ctm_proxy_address", ctm);
        vm.serializeAddress("contracts", "bridgehub_proxy_address", l1Bridgehub);
        vm.serializeAddress("contracts", "rollup_da_manager", rollupDAManager);
        string memory contracts = vm.serializeAddress("contracts", "l1_bytecodes_supplier_addr", bytecodesSupplier);
        vm.serializeString("root", "contracts", contracts);
        string memory permanentValuesToml = vm.serializeUint("root", "era_chain_id", eraChainId);
        vm.writeToml(permanentValuesToml, permanentValuesInputPath);
    }

    function deployNewEcosystemContractsL1() public virtual override {
        DeployL1CoreUtils l1CoreDeployer = new DeployL1CoreUtils();
        string memory root = vm.projectRoot();
        string memory upgradeInputPath = string.concat(root, "/script-config/config-deploy-l1.toml");
        l1CoreDeployer.initializeConfig(upgradeInputPath);
        bridgehubAddresses.bridgehubImplementation = l1CoreDeployer.deploySimpleContract("L1Bridgehub", false);
        // deploySimpleContract("L1ChainTypeManager", false);
    }

    /*//////////////////////////////////////////////////////////////
                          Internal functions
    //////////////////////////////////////////////////////////////*/

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        return super.getCreationCalldata(contractName, isZKBytecode);
    }

    function deployUsedUpgradeContract() internal returns (address) {
        return deploySimpleContract("L1V31Upgrade", false);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZkBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "L1MessageRoot")) {
            return abi.encodeCall(L1MessageRoot.initializeL1V31Upgrade, ());
        }
        return super.getInitializeCalldata(contractName, isZkBytecode);
    }
}
