// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdStorage, Test, stdStorage, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2Utils} from "./L2Utils.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/Utils.sol";
import {ADDRESS_ONE} from "deploy-scripts/Utils.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
// import {DeployCTMIntegrationScript} from "../../l1/integration/deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

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
        config.l1ChainId = _l1ChainId;
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        addresses.stateTransition.genesisUpgrade = address(new L1GenesisUpgrade());
        addresses.stateTransition.verifier = address(
            new EraTestnetVerifier(IVerifierV2(ADDRESS_ONE), IVerifier(ADDRESS_ONE))
        );
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        addresses.stateTransition.validatorTimelock = address(
            new TransparentUpgradeableProxy(
                address(new ValidatorTimelock(L2_BRIDGEHUB_ADDR)),
                addresses.transparentProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.deployerAddress, executionDelay))
            )
        );
        addresses.stateTransition.executorFacet = address(new ExecutorFacet(config.l1ChainId));
        addresses.stateTransition.adminFacet = address(
            new AdminFacet(config.l1ChainId, RollupDAManager(addresses.daAddresses.rollupDAManager))
        );
        addresses.stateTransition.mailboxFacet = address(new MailboxFacet(config.eraChainId, config.l1ChainId));
        addresses.stateTransition.gettersFacet = address(new GettersFacet());
        addresses.stateTransition.diamondInit = address(new DiamondInit(false));
        // Deploy ChainTypeManager implementation
        if (config.isZKsyncOS) {
            addresses.stateTransition.chainTypeManagerImplementation = address(
                new ZKsyncOSChainTypeManager(addresses.bridgehub.bridgehubProxy)
            );
        } else {
            addresses.stateTransition.chainTypeManagerImplementation = address(
                new EraChainTypeManager(addresses.bridgehub.bridgehubProxy)
            );
        }

        // Deploy TransparentUpgradeableProxy for ChainTypeManager
        bytes memory initCalldata;
        if (config.isZKsyncOS) {
            initCalldata = abi.encodeCall(
                IChainTypeManager.initialize,
                getChainTypeManagerInitializeData(addresses.stateTransition)
            );
        } else {
            initCalldata = abi.encodeCall(
                IChainTypeManager.initialize,
                getChainTypeManagerInitializeData(addresses.stateTransition)
            );
        }

        addresses.stateTransition.chainTypeManagerProxy = address(
            new TransparentUpgradeableProxy(
                addresses.stateTransition.chainTypeManagerImplementation,
                addresses.transparentProxyAdmin,
                initCalldata
            )
        );
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual override returns (address) {
        console.log("Deploying via create2 L2");
        return L2Utils.deployViaCreat2L2(creationCode, constructorArgs, create2FactoryParams.factorySalt);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        revert("Not implemented");
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        return ("Not implemented initialize calldata");
    }

    function deployTuppWithContract(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (address implementation, address proxy) {
        revert("Not implemented tupp");
    }

    // function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
    // }
}
