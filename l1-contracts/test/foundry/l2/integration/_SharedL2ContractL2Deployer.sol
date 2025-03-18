// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2Utils} from "./L2Utils.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-in-l1-context/Utils.sol";
import {StateTransitionDeployedAddresses, FacetCut, Action} from "deploy-scripts/Utils.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
// import {DeployL1IntegrationScript} from "../../l1/integration/deploy-scripts/DeployL1Integration.s.sol";

import {StateTransitionDeployedAddresses, FacetCut, ADDRESS_ONE} from "deploy-scripts/Utils.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

contract SharedL2ContractL2Deployer is SharedL2ContractDeployer {
    using stdToml for string;

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2Utils.initSystemContracts(_args);
    }

    // note this is duplicate code, but the inheritance is already complex
    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml"
        );
        initializeConfig(inputPath);
        addresses.transparentProxyAdmin = address(0x1);
        addresses.bridgehub.bridgehubProxy = L2_BRIDGEHUB_ADDR;
        addresses.bridges.l1AssetRouterProxy = L2_ASSET_ROUTER_ADDR;
        addresses.vaults.l1NativeTokenVaultProxy = L2_NATIVE_TOKEN_VAULT_ADDR;
        addresses.blobVersionedHashRetriever = address(0x1);
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        addresses.stateTransition.genesisUpgrade = address(new L1GenesisUpgrade());
        addresses.stateTransition.verifier = address(
            new TestnetVerifier(IVerifierV2(ADDRESS_ONE), IVerifier(ADDRESS_ONE))
        );
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        addresses.stateTransition.validatorTimelock = address(
            new ValidatorTimelock(config.deployerAddress, executionDelay)
        );
        addresses.stateTransition.executorFacet = address(new ExecutorFacet(config.l1ChainId));
        addresses.stateTransition.adminFacet = address(
            new AdminFacet(config.l1ChainId, RollupDAManager(addresses.daAddresses.rollupDAManager))
        );
        addresses.stateTransition.mailboxFacet = address(new MailboxFacet(config.eraChainId, config.l1ChainId));
        addresses.stateTransition.gettersFacet = address(new GettersFacet());
        addresses.stateTransition.diamondInit = address(new DiamondInit());
        // Deploy ChainTypeManager implementation
        addresses.stateTransition.chainTypeManagerImplementation = address(
            new ChainTypeManager(addresses.bridgehub.bridgehubProxy)
        );

        // Deploy TransparentUpgradeableProxy for ChainTypeManager
        addresses.stateTransition.chainTypeManagerProxy = address(
            new TransparentUpgradeableProxy(
                addresses.stateTransition.chainTypeManagerImplementation,
                addresses.transparentProxyAdmin,
                abi.encodeCall(
                    ChainTypeManager.initialize,
                    getChainTypeManagerInitializeData(addresses.stateTransition)
                )
            )
        );
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual override returns (address) {
        console.log("Deploying via create2 L2");
        return L2Utils.deployViaCreat2L2(creationCode, constructorArgs, config.contracts.create2FactorySalt);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}

    function getCreationCode(string memory contractName) internal view virtual override returns (bytes memory) {
        revert("Not implemented");
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        return ("Not implemented initialize calldata");
    }

    function deployTuppWithContract(
        string memory contractName
    ) internal virtual override returns (address implementation, address proxy) {
        revert("Not implemented tupp");
    }

    // function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
    // }
}
