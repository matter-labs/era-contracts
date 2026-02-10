// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {GatewayCTMDeployerHelper, DeployerCreate2Calldata, DeployerAddresses, DirectCreate2Calldata} from "deploy-scripts/gateway/GatewayCTMDeployerHelper.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @notice Deploy-script-style wrapper that calls GatewayCTMDeployerHelper.calculateAddresses
/// via a run() function, mimicking how GatewayVotePreparation.deployGatewayCTM() invokes it.
contract CalculateGatewayCTMAddressesScript {
    struct Result {
        DeployedContracts contracts;
        DeployerCreate2Calldata deployerCalldata;
        DeployerAddresses deployers;
        DirectCreate2Calldata directCalldata;
        address create2FactoryAddress;
    }

    /// @notice Mirrors the calculateAddresses call in GatewayVotePreparation.deployGatewayCTM()
    function run(GatewayCTMDeployerConfig memory config) public returns (Result memory result) {
        (
            result.contracts,
            result.deployerCalldata,
            result.deployers,
            result.directCalldata,
            result.create2FactoryAddress
        ) = GatewayCTMDeployerHelper.calculateAddresses(bytes32(0), config);
    }
}

/// @notice Test that exercises GatewayCTMDeployerHelper.calculateAddresses indirectly
/// by calling a deploy-script-style wrapper's run() function.
contract CalculateGatewayCTMAddressesTest is Test {
    CalculateGatewayCTMAddressesScript script;
    GatewayCTMDeployerConfig deployerConfig;

    function setUp() external {
        // Deploy the deterministic CREATE2 factory at the expected address
        vm.etch(Utils.DETERMINISTIC_CREATE2_ADDRESS, Utils.CREATE2_FACTORY_RUNTIME_BYTECODE);

        script = new CalculateGatewayCTMAddressesScript();

        GatewayCTMDeployerConfig memory config = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: address(0x123),
            salt: keccak256("test-salt"),
            eraChainId: 1001,
            l1ChainId: 1,
            testnetVerifier: true,
            isZKsyncOS: true,
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
            genesisBatchCommitment: bytes32(uint256(1)),
            forceDeploymentsData: hex"deadbeef",
            protocolVersion: 1
        });

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

    /// @notice Calls calculateAddresses indirectly through the script's run() function
    /// and verifies all returned addresses are non-zero and deterministic.
    function testCalculateAddressesViaScript() external {
        CalculateGatewayCTMAddressesScript.Result memory result = script.run(deployerConfig);

        // Verify create2 factory address matches ZKsyncOS mode
        assertEq(
            result.create2FactoryAddress,
            Utils.DETERMINISTIC_CREATE2_ADDRESS,
            "Should use deterministic CREATE2 factory for ZKsyncOS mode"
        );

        // Verify all deployer addresses are non-zero
        assertTrue(result.deployers.daDeployer != address(0), "DA deployer should be non-zero");
        assertTrue(result.deployers.proxyAdminDeployer != address(0), "ProxyAdmin deployer should be non-zero");
        assertTrue(
            result.deployers.validatorTimelockDeployer != address(0),
            "ValidatorTimelock deployer should be non-zero"
        );
        assertTrue(result.deployers.verifiersDeployer != address(0), "Verifiers deployer should be non-zero");
        assertTrue(result.deployers.ctmDeployer != address(0), "CTM deployer should be non-zero");

        // Verify all deployer addresses are unique
        assertTrue(result.deployers.daDeployer != result.deployers.proxyAdminDeployer, "Deployers should be unique");
        assertTrue(result.deployers.daDeployer != result.deployers.ctmDeployer, "Deployers should be unique");

        // Verify key contract addresses from DeployedContracts
        assertTrue(
            result.contracts.stateTransition.chainTypeManagerProxy != address(0),
            "CTM proxy should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.chainTypeManagerImplementation != address(0),
            "CTM impl should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.validatorTimelockProxy != address(0),
            "ValidatorTimelock proxy should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.verifiers.verifier != address(0),
            "Verifier should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.adminFacet != address(0),
            "AdminFacet should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.mailboxFacet != address(0),
            "MailboxFacet should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.executorFacet != address(0),
            "ExecutorFacet should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.gettersFacet != address(0),
            "GettersFacet should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.migratorFacet != address(0),
            "MigratorFacet should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.committerFacet != address(0),
            "CommitterFacet should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.facets.diamondInit != address(0),
            "DiamondInit should be non-zero"
        );
        assertTrue(
            result.contracts.stateTransition.genesisUpgrade != address(0),
            "GenesisUpgrade should be non-zero"
        );
        assertTrue(result.contracts.multicall3 != address(0), "Multicall3 should be non-zero");
        assertTrue(result.contracts.diamondCutData.length > 0, "Diamond cut data should be non-empty");

        // Verify DA contracts
        assertTrue(
            result.contracts.daContracts.rollupDAManager != address(0),
            "RollupDAManager should be non-zero"
        );
        assertTrue(
            result.contracts.daContracts.validiumDAValidator != address(0),
            "ValidiumDAValidator should be non-zero"
        );
        assertTrue(
            result.contracts.daContracts.relayedSLDAValidator != address(0),
            "RelayedSLDAValidator should be non-zero"
        );

        // Verify determinism: calling again with same config produces identical results
        CalculateGatewayCTMAddressesScript.Result memory result2 = script.run(deployerConfig);
        assertEq(
            result.deployers.daDeployer,
            result2.deployers.daDeployer,
            "DA deployer should be deterministic"
        );
        assertEq(
            result.deployers.ctmDeployer,
            result2.deployers.ctmDeployer,
            "CTM deployer should be deterministic"
        );
        assertEq(
            result.contracts.stateTransition.chainTypeManagerProxy,
            result2.contracts.stateTransition.chainTypeManagerProxy,
            "CTM proxy should be deterministic"
        );
        assertEq(
            result.contracts.multicall3,
            result2.contracts.multicall3,
            "Multicall3 should be deterministic"
        );
    }

    /// @notice Verifies that different salts produce different addresses.
    function testDifferentSaltProducesDifferentAddresses() external {
        CalculateGatewayCTMAddressesScript.Result memory result1 = script.run(deployerConfig);

        // Change the inner salt
        deployerConfig.salt = keccak256("different-salt");
        CalculateGatewayCTMAddressesScript.Result memory result2 = script.run(deployerConfig);

        assertTrue(
            result1.contracts.stateTransition.chainTypeManagerProxy !=
                result2.contracts.stateTransition.chainTypeManagerProxy,
            "Different salt should produce different CTM proxy address"
        );
        assertTrue(
            result1.deployers.daDeployer != result2.deployers.daDeployer,
            "Different salt should produce different DA deployer address"
        );
    }
}
