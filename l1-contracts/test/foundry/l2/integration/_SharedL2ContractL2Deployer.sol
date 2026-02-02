// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2Utils} from "./L2Utils.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/Utils.sol";
import {ADDRESS_ONE} from "deploy-scripts/utils/Utils.sol";

import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
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
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
// import {DeployCTMIntegrationScript} from "../../l1/integration/deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";

contract SharedL2ContractL2Deployer is SharedL2ContractDeployer {
    using stdToml for string;

    /// @notice Override to avoid library delegatecall issues in ZKsync mode
    /// Returns hardcoded values from the test config
    function getChainCreationParamsConfig(
        string memory /* _config */
    ) internal virtual override returns (ChainCreationParamsConfig memory chainCreationParams) {
        // Values from config-deploy-ctm.toml
        chainCreationParams.genesisRoot = bytes32(0x1000000000000000000000000000000000000000000000000000000000000000);
        chainCreationParams.genesisRollupLeafIndex = 1;
        chainCreationParams.genesisBatchCommitment = bytes32(
            0x1000000000000000000000000000000000000000000000000000000000000000
        );
        chainCreationParams.latestProtocolVersion = 120259084288;
        chainCreationParams.bootloaderHash = bytes32(
            0x0100085F9382A7928DD83BFC529121827B5F29F18B9AA10D18AA68E1BE7DDC35
        );
        chainCreationParams.defaultAAHash = bytes32(0x010005F767ED85C548BCE536C18ED2E1643CA8A6F27EE40826D6936AEA0C87D4);
        chainCreationParams.evmEmulatorHash = bytes32(
            0x01000D83E0329D9144AD041430FAFCBC2B388E5434DB8CB8A96E80157738A1DA
        );
    }

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2Utils.initSystemContracts(_args);
    }

    /// @notice this is duplicate code, but the inheritance is already complex
    /// here we have to deploy contracts manually with new Contract(), because that can be handled by the compiler.
    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm.toml"
        );
        string memory permanentValuesInputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/permanent-values.toml"
        );

        initializeConfig(inputPath, permanentValuesInputPath, L2_BRIDGEHUB_ADDR);
        ctmAddresses.admin.transparentProxyAdmin = address(0x1);
        ctmAddresses.admin.governance = address(0x2); // Mock governance for tests
        config.l1ChainId = _l1ChainId;
        // Generate mock force deployments data for L2 tests
        _generateMockForceDeploymentsData(_l1ChainId);
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        ctmAddresses.stateTransition.genesisUpgrade = address(new L1GenesisUpgrade());
        ctmAddresses.stateTransition.verifiers.verifier = address(
            new EraTestnetVerifier(IVerifierV2(ADDRESS_ONE), IVerifier(ADDRESS_ONE))
        );
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        ctmAddresses.stateTransition.proxies.validatorTimelock = address(
            new TransparentUpgradeableProxy(
                address(new ValidatorTimelock(L2_BRIDGEHUB_ADDR)),
                ctmAddresses.admin.transparentProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.deployerAddress, executionDelay))
            )
        );
        ctmAddresses.stateTransition.facets.executorFacet = address(new ExecutorFacet(config.l1ChainId));
        ctmAddresses.stateTransition.facets.adminFacet = address(
            new AdminFacet(config.l1ChainId, RollupDAManager(ctmAddresses.daAddresses.rollupDAManager), false)
        );
        ctmAddresses.stateTransition.facets.mailboxFacet = address(
            new MailboxFacet(
                config.eraChainId,
                config.l1ChainId,
                L2_CHAIN_ASSET_HANDLER_ADDR,
                IEIP7702Checker(address(0)),
                false
            )
        );
        ctmAddresses.stateTransition.facets.gettersFacet = address(new GettersFacet());
        ctmAddresses.stateTransition.facets.diamondInit = address(new DiamondInit(false));
        // Deploy ChainTypeManager implementation
        if (config.isZKsyncOS) {
            ctmAddresses.stateTransition.implementations.chainTypeManager = address(
                new ZKsyncOSChainTypeManager(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), address(0))
            );
        } else {
            ctmAddresses.stateTransition.implementations.chainTypeManager = address(
                new EraChainTypeManager(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), address(0))
            );
        }

        // Deploy TransparentUpgradeableProxy for ChainTypeManager
        bytes memory initCalldata = abi.encodeCall(
            IChainTypeManager.initialize,
            getChainTypeManagerInitializeData(ctmAddresses.stateTransition)
        );

        ctmAddresses.stateTransition.proxies.chainTypeManager = address(
            new TransparentUpgradeableProxy(
                ctmAddresses.stateTransition.implementations.chainTypeManager,
                ctmAddresses.admin.transparentProxyAdmin,
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

    /// @notice Generate mock force deployments data for L2 tests using a pre-encoded value
    function _generateMockForceDeploymentsData(uint256) internal {
        // Use pre-generated force deployments data to avoid bytecode size issues
        // This is the same as what would be generated by _buildForceDeploymentsData
        generatedData
            .forceDeploymentsData = hex"00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000007b0000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000101000000000000000000000000000000000000000000000000000000000000001111000000000000000000000000000000000000000000000000000000000001100000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000028000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000048000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020010000000000000000000000000000000000000000000000000000000000000000";
    }
}
