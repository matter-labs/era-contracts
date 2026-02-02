// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployedContracts, GatewayCTMDeployerConfig, DAContracts, GatewayProxyAdminDeployerResult, GatewayValidatorTimelockDeployerResult, Verifiers, GatewayCTMFinalResult} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {GatewayCTMDeployerDA} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerDA.sol";
import {GatewayCTMDeployerProxyAdmin} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerProxyAdmin.sol";
import {GatewayCTMDeployerValidatorTimelock} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerValidatorTimelock.sol";
import {GatewayCTMDeployerVerifiersZKsyncOS} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerVerifiersZKsyncOS.sol";
import {GatewayCTMDeployerCTMZKsyncOS} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerCTMZKsyncOS.sol";

import {GatewayCTMDeployerHelper, DeployerCreate2Calldata, DeployerAddresses, DirectDeployedAddresses, DirectCreate2Calldata} from "deploy-scripts/gateway/GatewayCTMDeployerHelper.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {AllDeployerResults, DeployedContractsComparator, GatewayCTMDeployerTestUtils} from "test/foundry/unit/utils/GatewayCTMDeployerTestUtils.sol";

/// @notice Tester contract that deploys via the deterministic CREATE2 factory (Arachnid's)
contract GatewayCTMDeployerTesterZKsyncOS {
    address constant DETERMINISTIC_CREATE2_ADDRESS = Utils.DETERMINISTIC_CREATE2_ADDRESS;

    /// @notice Converts raw 20-byte return data to address
    /// @dev Arachnid's CREATE2 factory returns raw 20 bytes, not ABI-encoded
    function _bytesToAddress(bytes memory data) internal pure returns (address addr) {
        require(data.length == 20, "Invalid address length");
        assembly {
            addr := shr(96, mload(add(data, 32)))
        }
    }

    /// @notice Deploys DA contracts
    function deployDA(bytes memory data) external returns (DAContracts memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = DETERMINISTIC_CREATE2_ADDRESS.call(data);
        require(success, "DA deployment failed");

        deployerAddr = _bytesToAddress(returnData);
        result = GatewayCTMDeployerDA(deployerAddr).getResult();
    }

    /// @notice Deploys ProxyAdmin
    function deployProxyAdmin(
        bytes memory data
    ) external returns (GatewayProxyAdminDeployerResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = DETERMINISTIC_CREATE2_ADDRESS.call(data);
        require(success, "ProxyAdmin deployment failed");

        deployerAddr = _bytesToAddress(returnData);
        result = GatewayCTMDeployerProxyAdmin(deployerAddr).getResult();
    }

    /// @notice Deploys ValidatorTimelock
    function deployValidatorTimelock(
        bytes memory data
    ) external returns (GatewayValidatorTimelockDeployerResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = DETERMINISTIC_CREATE2_ADDRESS.call(data);
        require(success, "ValidatorTimelock deployment failed");

        deployerAddr = _bytesToAddress(returnData);
        result = GatewayCTMDeployerValidatorTimelock(deployerAddr).getResult();
    }

    /// @notice Deploys Verifiers (ZKsyncOS version)
    function deployVerifiers(bytes memory data) external returns (Verifiers memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = DETERMINISTIC_CREATE2_ADDRESS.call(data);
        require(success, "Verifiers deployment failed");

        deployerAddr = _bytesToAddress(returnData);
        result = GatewayCTMDeployerVerifiersZKsyncOS(deployerAddr).getResult();
    }

    /// @notice Deploys CTM and ServerNotifier (ZKsyncOS version)
    function deployCTM(bytes memory data) external returns (GatewayCTMFinalResult memory result, address deployerAddr) {
        (bool success, bytes memory returnData) = DETERMINISTIC_CREATE2_ADDRESS.call(data);
        require(success, "CTM deployment failed");

        deployerAddr = _bytesToAddress(returnData);
        result = GatewayCTMDeployerCTMZKsyncOS(deployerAddr).getResult();
    }

    /// @notice Deploys a contract directly via the deterministic CREATE2 factory
    function deployDirect(bytes memory data) external returns (address deployedAddr) {
        (bool success, bytes memory returnData) = DETERMINISTIC_CREATE2_ADDRESS.call(data);
        require(success, "Direct deployment failed");
        deployedAddr = _bytesToAddress(returnData);
    }
}

/// @notice Test for GatewayCTMDeployer in ZKsyncOS (EVM) mode
/// @dev This test verifies that the deployment logic works correctly for standard EVM systems
contract GatewayCTMDeployerZKsyncOSTest is Test {
    GatewayCTMDeployerConfig deployerConfig;

    function setUp() external {
        // Deploy the deterministic CREATE2 factory at the expected address
        vm.etch(Utils.DETERMINISTIC_CREATE2_ADDRESS, Utils.CREATE2_FACTORY_RUNTIME_BYTECODE);

        // Initialize the configuration with sample data for ZKsyncOS mode
        GatewayCTMDeployerConfig memory config = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: address(0x123),
            salt: keccak256("test-salt"),
            eraChainId: 1001,
            l1ChainId: 1,
            testnetVerifier: true,
            isZKsyncOS: true, // ZKsyncOS mode enabled
            adminSelectors: new bytes4[](2),
            executorSelectors: new bytes4[](2),
            mailboxSelectors: new bytes4[](2),
            gettersSelectors: new bytes4[](2),
            migratorSelectors: new bytes4[](2),
            committerSelectors: new bytes4[](2),
            bootloaderHash: bytes32(uint256(0xabc)),
            defaultAccountHash: bytes32(uint256(0xdef)),
            evmEmulatorHash: bytes32(uint256(0xdef)),
            genesisRoot: bytes32(uint256(0x123)),
            genesisRollupLeafIndex: 10,
            // For ZKsyncOS mode, the genesis batch commitment must be equal to 1
            genesisBatchCommitment: bytes32(uint256(1)),
            forceDeploymentsData: hex"deadbeef",
            protocolVersion: 1,
            permissionlessValidator: address(0)
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
        config.migratorSelectors[0] = bytes4(keccak256("migratorFunction1()"));
        config.migratorSelectors[1] = bytes4(keccak256("migratorFunction2()"));
        config.committerSelectors[0] = bytes4(keccak256("committerFunction1()"));
        config.committerSelectors[1] = bytes4(keccak256("committerFunction2()"));

        deployerConfig = config;
    }

    /// @notice Smoke test that verifies the deployment works correctly in ZKsyncOS mode
    function testGatewayCTMDeployerZKsyncOS() external {
        // Calculate expected addresses using the helper FIRST
        // This is needed because some deployer constructors need addresses from earlier deployers
        (
            DeployedContracts memory calculatedContracts,
            DeployerCreate2Calldata memory deployerCalldata,
            DeployerAddresses memory expectedDeployers,
            DirectCreate2Calldata memory directCalldata,
            address create2FactoryAddress
        ) = GatewayCTMDeployerHelper.calculateAddresses(bytes32(0), deployerConfig);

        // Verify we're using the deterministic CREATE2 factory
        assertEq(
            create2FactoryAddress,
            Utils.DETERMINISTIC_CREATE2_ADDRESS,
            "Should use deterministic CREATE2 factory"
        );

        GatewayCTMDeployerTesterZKsyncOS tester = new GatewayCTMDeployerTesterZKsyncOS();

        // Deploy all deployers and collect results
        AllDeployerResults memory results = _deployAllDeployers(
            tester,
            deployerCalldata,
            expectedDeployers,
            calculatedContracts,
            directCalldata
        );

        // Assemble actual deployed contracts from all deployers
        DeployedContracts memory actualContracts = GatewayCTMDeployerTestUtils.assembleActualContracts(
            results,
            calculatedContracts
        );

        // Compare calculated addresses with actual deployed addresses
        DeployedContractsComparator.compareDeployedContracts(calculatedContracts, actualContracts);
    }

    function _deployAllDeployers(
        GatewayCTMDeployerTesterZKsyncOS tester,
        DeployerCreate2Calldata memory deployerCalldata,
        DeployerAddresses memory expectedDeployers,
        DeployedContracts memory calculatedContracts,
        DirectCreate2Calldata memory directCalldata
    ) internal returns (AllDeployerResults memory results) {
        address deployer;

        // DA deployer
        (results.daResult, deployer) = tester.deployDA(deployerCalldata.daCalldata);
        assertEq(deployer, expectedDeployers.daDeployer, "DA deployer address mismatch");

        // ProxyAdmin deployer
        (results.proxyAdminResult, deployer) = tester.deployProxyAdmin(deployerCalldata.proxyAdminCalldata);
        assertEq(deployer, expectedDeployers.proxyAdminDeployer, "ProxyAdmin deployer address mismatch");

        // ValidatorTimelock deployer
        (results.validatorTimelockResult, deployer) = tester.deployValidatorTimelock(
            deployerCalldata.validatorTimelockCalldata
        );
        assertEq(deployer, expectedDeployers.validatorTimelockDeployer, "ValidatorTimelock deployer address mismatch");

        // Verifiers deployer (ZKsyncOS)
        (results.verifiersResult, deployer) = tester.deployVerifiers(deployerCalldata.verifiersCalldata);
        assertEq(deployer, expectedDeployers.verifiersDeployer, "Verifiers deployer address mismatch");

        // Deploy direct contracts (facets, etc.)
        _deployDirectContracts(tester, directCalldata, calculatedContracts);

        // CTM deployer (ZKsyncOS)
        (results.ctmResult, deployer) = tester.deployCTM(deployerCalldata.ctmCalldata);
        assertEq(deployer, expectedDeployers.ctmDeployer, "CTM deployer address mismatch");

        return results;
    }

    function _deployDirectContracts(
        GatewayCTMDeployerTesterZKsyncOS tester,
        DirectCreate2Calldata memory directCalldata,
        DeployedContracts memory calculatedContracts
    ) internal {
        address deployed;

        // AdminFacet
        deployed = tester.deployDirect(directCalldata.adminFacetCalldata);
        assertEq(deployed, calculatedContracts.stateTransition.facets.adminFacet, "AdminFacet address mismatch");

        // MailboxFacet
        deployed = tester.deployDirect(directCalldata.mailboxFacetCalldata);
        assertEq(deployed, calculatedContracts.stateTransition.facets.mailboxFacet, "MailboxFacet address mismatch");

        // ExecutorFacet
        deployed = tester.deployDirect(directCalldata.executorFacetCalldata);
        assertEq(deployed, calculatedContracts.stateTransition.facets.executorFacet, "ExecutorFacet address mismatch");

        // GettersFacet
        deployed = tester.deployDirect(directCalldata.gettersFacetCalldata);
        assertEq(deployed, calculatedContracts.stateTransition.facets.gettersFacet, "GettersFacet address mismatch");

        // DiamondInit
        deployed = tester.deployDirect(directCalldata.diamondInitCalldata);
        assertEq(deployed, calculatedContracts.stateTransition.facets.diamondInit, "DiamondInit address mismatch");

        // GenesisUpgrade
        deployed = tester.deployDirect(directCalldata.genesisUpgradeCalldata);
        assertEq(deployed, calculatedContracts.stateTransition.genesisUpgrade, "GenesisUpgrade address mismatch");

        // Multicall3
        deployed = tester.deployDirect(directCalldata.multicall3Calldata);
        assertEq(deployed, calculatedContracts.multicall3, "Multicall3 address mismatch");
    }
}
