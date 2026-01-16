// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployedContracts, GatewayCTMDeployerConfig, GatewayDADeployerConfig, GatewayDADeployerResult, GatewayProxyAdminDeployerConfig, GatewayProxyAdminDeployerResult, GatewayValidatorTimelockDeployerConfig, GatewayValidatorTimelockDeployerResult, GatewayVerifiersDeployerConfig, GatewayVerifiersDeployerResult, GatewayCTMFinalConfig, GatewayCTMFinalResult} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {GatewayCTMDeployerDA} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerDA.sol";
import {GatewayCTMDeployerProxyAdmin} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerProxyAdmin.sol";
import {GatewayCTMDeployerValidatorTimelock} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerValidatorTimelock.sol";
import {GatewayCTMDeployerVerifiers} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerVerifiers.sol";
import {GatewayCTMDeployerCTM} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerCTM.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "contracts/state-transition/data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";

import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";

import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR, L2_CREATE2_FACTORY_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GatewayCTMDeployerHelper, PhaseCreate2Calldata, PhaseDeployerAddresses} from "deploy-scripts/gateway/GatewayCTMDeployerHelper.sol";

import {AllPhaseResults, DeployedContractsComparator, GatewayCTMDeployerTestUtils} from "test/foundry/unit/utils/GatewayCTMDeployerTestUtils.sol";

// We need to use contract the zkfoundry consistently uses
// zk environment only within a deployed contract
contract GatewayCTMDeployerTester {
    /// @notice Deploys Phase 1: DA contracts
    function deployPhase1(
        bytes memory data
    ) external returns (GatewayDADeployerResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = L2_CREATE2_FACTORY_ADDR.call(data);
        require(success, "Phase 1 deployment failed");

        deployerAddr = abi.decode(returnData, (address));
        result = GatewayCTMDeployerDA(deployerAddr).getResult();
    }

    /// @notice Deploys Phase 2: ProxyAdmin
    function deployPhase2(
        bytes memory data
    ) external returns (GatewayProxyAdminDeployerResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = L2_CREATE2_FACTORY_ADDR.call(data);
        require(success, "Phase 2 deployment failed");

        deployerAddr = abi.decode(returnData, (address));
        result = GatewayCTMDeployerProxyAdmin(deployerAddr).getResult();
    }

    /// @notice Deploys Phase 3: ValidatorTimelock
    function deployPhase3(
        bytes memory data
    ) external returns (GatewayValidatorTimelockDeployerResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = L2_CREATE2_FACTORY_ADDR.call(data);
        require(success, "Phase 3 deployment failed");

        deployerAddr = abi.decode(returnData, (address));
        result = GatewayCTMDeployerValidatorTimelock(deployerAddr).getResult();
    }

    /// @notice Deploys Phase 4: Verifiers
    function deployPhase4(
        bytes memory data
    ) external returns (GatewayVerifiersDeployerResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = L2_CREATE2_FACTORY_ADDR.call(data);
        require(success, "Phase 4 deployment failed");

        deployerAddr = abi.decode(returnData, (address));
        result = GatewayCTMDeployerVerifiers(deployerAddr).getResult();
    }

    /// @notice Deploys Phase 5: CTM and ServerNotifier
    function deployPhase5(
        bytes memory data
    ) external returns (GatewayCTMFinalResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = L2_CREATE2_FACTORY_ADDR.call(data);
        require(success, "Phase 5 deployment failed");

        deployerAddr = abi.decode(returnData, (address));
        result = GatewayCTMDeployerCTM(deployerAddr).getResult();
    }
}

contract GatewayCTMDeployerTest is Test {
    GatewayCTMDeployerConfig deployerConfig;

    // This is done merely to publish the respective bytecodes.
    function _predeployContracts() internal {
        // Phase 1 contracts (DA)
        new RollupDAManager();
        new ValidiumL1DAValidator();
        new RelayedSLDAValidator();

        // Phase 2 contracts (ProxyAdmin)
        new ProxyAdmin();

        // Phase 3 contracts (ValidatorTimelock)
        new ValidatorTimelock(L2_BRIDGEHUB_ADDR);

        // Phase 4 contracts (Verifiers)
        new EraVerifierFflonk();
        new EraVerifierPlonk();
        new EraTestnetVerifier(EraVerifierFflonk(address(0)), EraVerifierPlonk(address(0)));

        // Phase 5 contracts (CTM)
        new ServerNotifier();
        new ZKsyncOSChainTypeManager(address(0), address(0));
        new EraChainTypeManager(address(0), address(0));

        // Direct deployment contracts (no deployer)
        new AdminFacet(1, RollupDAManager(address(0)), false);
        new MailboxFacet(1, 1, L2_CHAIN_ASSET_HANDLER_ADDR, IEIP7702Checker(address(0)), false);
        new ExecutorFacet(1);
        new GettersFacet();
        new DiamondInit(false);
        new L1GenesisUpgrade();
        new Multicall3();

        // This call will likely fail due to various checks, but we just need to get the bytecode published
        try new TransparentUpgradeableProxy(address(0), address(0), hex"") {} catch {}
    }

    function setUp() external {
        // Initialize the configuration with sample data
        GatewayCTMDeployerConfig memory config = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: address(0x123),
            salt: keccak256("test-salt"),
            eraChainId: 1001,
            l1ChainId: 1,
            testnetVerifier: true,
            isZKsyncOS: false,
            adminSelectors: new bytes4[](2),
            executorSelectors: new bytes4[](2),
            mailboxSelectors: new bytes4[](2),
            gettersSelectors: new bytes4[](2),
            bootloaderHash: bytes32(uint256(0xabc)),
            defaultAccountHash: bytes32(uint256(0xdef)),
            evmEmulatorHash: bytes32(uint256(0xdef)),
            genesisRoot: bytes32(uint256(0x123)),
            genesisRollupLeafIndex: 10,
            genesisBatchCommitment: bytes32(uint256(0x456)),
            forceDeploymentsData: hex"deadbeef",
            protocolVersion: 1
        });

        // Initialize selectors with sample function selectors
        config.adminSelectors[0] = bytes4(keccak256("adminFunction1()"));
        config.adminSelectors[1] = bytes4(keccak256("adminFunction2()"));
        config.executorSelectors[0] = bytes4(keccak256("executorFunction1()"));
        config.executorSelectors[1] = bytes4(keccak256("executorFunction2()"));
        config.mailboxSelectors[0] = bytes4(keccak256("mailboxFunction1()"));
        config.mailboxSelectors[1] = bytes4(keccak256("mailboxFunction2()"));
        config.gettersSelectors[0] = bytes4(keccak256("gettersFunction1()"));
        config.gettersSelectors[1] = bytes4(keccak256("gettersFunction2()"));

        deployerConfig = config;

        _predeployContracts();
    }

    // It is more a smoke test that indeed the deployment works
    function testGatewayCTMDeployer() external {
        // Calculate expected addresses using the helper FIRST
        // This is needed because some deployer constructors need addresses from earlier phases
        (
            DeployedContracts memory calculatedContracts,
            PhaseCreate2Calldata memory phaseCalldata,
            PhaseDeployerAddresses memory expectedDeployers, // DirectCreate2Calldata and create2FactoryAddress not needed for this test
            ,

        ) = GatewayCTMDeployerHelper.calculateAddresses(bytes32(0), deployerConfig);

        // Publish bytecodes for all 5 phase deployers using calculated addresses
        _publishPhaseDeployerBytecodes(calculatedContracts);

        GatewayCTMDeployerTester tester = new GatewayCTMDeployerTester();

        // Deploy all phases and collect results
        AllPhaseResults memory results = _deployAllPhases(
            tester,
            phaseCalldata,
            expectedDeployers,
            calculatedContracts
        );

        // Assemble actual deployed contracts from all phases
        DeployedContracts memory actualContracts = GatewayCTMDeployerTestUtils.assembleActualContracts(
            results,
            calculatedContracts
        );

        // Compare calculated addresses with actual deployed addresses
        DeployedContractsComparator.compareDeployedContracts(calculatedContracts, actualContracts);
    }

    function _publishPhaseDeployerBytecodes(DeployedContracts memory calculatedContracts) internal {
        // Phase 1: DA
        GatewayDADeployerConfig memory daConfig = GatewayDADeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress
        });
        new GatewayCTMDeployerDA(daConfig);

        // Phase 2: ProxyAdmin
        GatewayProxyAdminDeployerConfig memory proxyAdminConfig = GatewayProxyAdminDeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress
        });
        new GatewayCTMDeployerProxyAdmin(proxyAdminConfig);

        // Phase 3: ValidatorTimelock - needs calculated ProxyAdmin address
        GatewayValidatorTimelockDeployerConfig memory vtConfig = GatewayValidatorTimelockDeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress,
            chainTypeManagerProxyAdmin: calculatedContracts.stateTransition.chainTypeManagerProxyAdmin
        });
        new GatewayCTMDeployerValidatorTimelock(vtConfig);

        // Phase 4: Verifiers
        GatewayVerifiersDeployerConfig memory verifiersConfig = GatewayVerifiersDeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress,
            testnetVerifier: deployerConfig.testnetVerifier,
            isZKsyncOS: deployerConfig.isZKsyncOS
        });
        new GatewayCTMDeployerVerifiers(verifiersConfig);
    }

    function _deployAllPhases(
        GatewayCTMDeployerTester tester,
        PhaseCreate2Calldata memory phaseCalldata,
        PhaseDeployerAddresses memory expectedDeployers,
        DeployedContracts memory calculatedContracts
    ) internal returns (AllPhaseResults memory results) {
        address deployer;

        // DA phase
        (results.daResult, deployer) = tester.deployPhase1(phaseCalldata.daCalldata);
        require(deployer == expectedDeployers.daDeployer, "DA deployer address mismatch");

        // ProxyAdmin phase
        (results.proxyAdminResult, deployer) = tester.deployPhase2(phaseCalldata.proxyAdminCalldata);
        require(deployer == expectedDeployers.proxyAdminDeployer, "ProxyAdmin deployer address mismatch");

        // ValidatorTimelock phase
        (results.validatorTimelockResult, deployer) = tester.deployPhase3(phaseCalldata.validatorTimelockCalldata);
        require(deployer == expectedDeployers.validatorTimelockDeployer, "ValidatorTimelock deployer address mismatch");

        // Verifiers phase
        (results.verifiersResult, deployer) = tester.deployPhase4(phaseCalldata.verifiersCalldata);
        require(deployer == expectedDeployers.verifiersDeployer, "Verifiers deployer address mismatch");

        // Need to publish CTM phase bytecode with actual addresses
        _publishPhase5Bytecode(results, calculatedContracts);

        // CTM phase
        (results.ctmResult, deployer) = tester.deployPhase5(phaseCalldata.ctmCalldata);
        require(deployer == expectedDeployers.ctmDeployer, "CTM deployer address mismatch");

        return results;
    }

    function _publishPhase5Bytecode(
        AllPhaseResults memory results,
        DeployedContracts memory calculatedContracts
    ) internal {
        // Use calculated addresses for direct deployments (facets, etc.)
        GatewayCTMFinalConfig memory ctmConfig = GatewayCTMFinalConfig({
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress,
            salt: deployerConfig.salt,
            eraChainId: deployerConfig.eraChainId,
            l1ChainId: deployerConfig.l1ChainId,
            isZKsyncOS: deployerConfig.isZKsyncOS,
            adminSelectors: deployerConfig.adminSelectors,
            executorSelectors: deployerConfig.executorSelectors,
            mailboxSelectors: deployerConfig.mailboxSelectors,
            gettersSelectors: deployerConfig.gettersSelectors,
            bootloaderHash: deployerConfig.bootloaderHash,
            defaultAccountHash: deployerConfig.defaultAccountHash,
            evmEmulatorHash: deployerConfig.evmEmulatorHash,
            genesisRoot: deployerConfig.genesisRoot,
            genesisRollupLeafIndex: deployerConfig.genesisRollupLeafIndex,
            genesisBatchCommitment: deployerConfig.genesisBatchCommitment,
            forceDeploymentsData: deployerConfig.forceDeploymentsData,
            protocolVersion: deployerConfig.protocolVersion,
            chainTypeManagerProxyAdmin: results.proxyAdminResult.chainTypeManagerProxyAdmin,
            validatorTimelock: results.validatorTimelockResult.validatorTimelock,
            adminFacet: calculatedContracts.stateTransition.adminFacet,
            gettersFacet: calculatedContracts.stateTransition.gettersFacet,
            mailboxFacet: calculatedContracts.stateTransition.mailboxFacet,
            executorFacet: calculatedContracts.stateTransition.executorFacet,
            diamondInit: calculatedContracts.stateTransition.diamondInit,
            genesisUpgrade: calculatedContracts.stateTransition.genesisUpgrade,
            verifier: results.verifiersResult.verifier
        });
        new GatewayCTMDeployerCTM(ctmConfig);
    }
}
