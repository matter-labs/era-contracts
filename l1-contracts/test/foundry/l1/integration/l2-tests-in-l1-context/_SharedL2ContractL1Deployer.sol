// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {DeployCTMIntegrationScript} from "../deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "../l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {DummyInteropRecipient} from "contracts/dev-contracts/test/DummyInteropRecipient.sol";

import {L2UtilsBase} from "./L2UtilsBase.sol";
import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {L2UtilsBase} from "./L2UtilsBase.sol";

contract SharedL2ContractL1Deployer is SharedL2ContractDeployer, DeployCTMIntegrationScript {
    using stdToml for string;
    using stdStorage for StdStorage;

    /// @dev We provide a fast form of debugging the L2 contracts using L1 foundry. We also test using zk foundry.

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2UtilsBase.initSystemContracts(_args);
        // Deploy DummyInteropRecipient and etch its bytecode to interopTargetContract
        DummyInteropRecipient impl = new DummyInteropRecipient();
        vm.etch(interopTargetContract, address(impl).code);
    }

    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        deployL2ContractsInner(_l1ChainId, false);
    }

    function deployL2ContractsInner(uint256 _l1ChainId, bool _skip) public {
        string memory root = vm.projectRoot();
        string memory CONTRACTS_PATH = vm.envString("CONTRACTS_PATH");
        string memory inputPath = string.concat(
            root,
            "/",
            CONTRACTS_PATH,
            "/l1-contracts",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm.toml"
        );
        string memory permanentValuesInputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/permanent-values.toml"
        );
        initializeConfig(inputPath, permanentValuesInputPath, L2_BRIDGEHUB_ADDR);
        coreAddresses.bridgehub.proxies.bridgehub = L2_BRIDGEHUB_ADDR;
        coreAddresses.bridges.proxies.l1AssetRouter = L2_ASSET_ROUTER_ADDR;
        coreAddresses.bridges.proxies.l1NativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        if (!_skip) {
            instantiateCreate2Factory();
        }

        // TODO refactor
        ctmAddresses.admin.transparentProxyAdmin = makeAddr("transparentProxyAdmin");
        ctmAddresses.admin.governance = makeAddr("governance");
        ctmAddresses.chainAdmin = makeAddr("chainAdmin");
        ctmAddresses.stateTransition.genesisUpgrade = deploySimpleContract("L1GenesisUpgrade", true);
        ctmAddresses.stateTransition.verifiers.verifier = deploySimpleContract("Verifier", true);
        ctmAddresses.stateTransition.proxies.validatorTimelock = deploySimpleContract("ValidatorTimelock", true);
        (
            ctmAddresses.stateTransition.implementations.serverNotifier,
            ctmAddresses.stateTransition.proxies.serverNotifier
        ) = deployServerNotifier();
        ctmAddresses.admin.eip7702Checker = address(0);
        initializeGeneratedData();
        deployStateTransitionDiamondFacets();
        string memory ctmContractName = config.isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        (
            ctmAddresses.stateTransition.implementations.chainTypeManager,
            ctmAddresses.stateTransition.proxies.chainTypeManager
        ) = deployTuppWithContract(ctmContractName, true);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override(DeployCTMIntegrationScript, SharedL2ContractDeployer) {}

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    )
        internal
        virtual
        override(DeployCTMIntegrationScript, DeployIntegrationUtils)
        returns (Diamond.FacetCut[] memory)
    {
        return super.getChainCreationFacetCuts(stateTransition);
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    )
        internal
        virtual
        override(DeployCTMIntegrationScript, DeployIntegrationUtils)
        returns (Diamond.FacetCut[] memory)
    {
        return super.getUpgradeAddedFacetCuts(stateTransition);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override(DeployIntegrationUtils, DeployCTMUtils) returns (bytes memory) {
        return super.getInitializeCalldata(contractName, isZKBytecode);
    }
}
