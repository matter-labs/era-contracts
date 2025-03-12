// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/Script.sol";

import {GatewayCTMDeployer, GatewayCTMDeployerConfig, DeployedContracts, StateTransitionContracts, DAContracts} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "contracts/state-transition/data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";

import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {L2VerifierFflonk} from "contracts/state-transition/verifiers/L2VerifierFflonk.sol";
import {L2VerifierPlonk} from "contracts/state-transition/verifiers/L2VerifierPlonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {GatewayCTMDeployerHelper} from "deploy-scripts/GatewayCTMDeployerHelper.sol";

import {L2_CREATE2_FACTORY_ADDRESS} from "deploy-scripts/Utils.sol";

// We need to use contract the zkfoundry consistently uses
// zk environment only within a deployed contract
contract GatewayCTMDeployerTester {
    function deployCTMDeployer(
        bytes memory data
    ) external returns (DeployedContracts memory deployedContracts, address addr) {
        (bool success, bytes memory result) = L2_CREATE2_FACTORY_ADDRESS.call(data);
        require(success, "failed to deploy");

        addr = abi.decode(result, (address));

        deployedContracts = GatewayCTMDeployer(addr).getDeployedContracts();
    }
}

contract GatewayCTMDeployerTest is Test {
    GatewayCTMDeployerConfig deployerConfig;

    // This is done merely to publish the respective bytecodes.
    function _predeployContracts() internal {
        new MailboxFacet(1, 1);
        new ExecutorFacet(1);
        new GettersFacet();
        new AdminFacet(1, RollupDAManager(address(0)));

        new DiamondInit();
        new L1GenesisUpgrade();
        new RollupDAManager();
        new ValidiumL1DAValidator();
        new RelayedSLDAValidator();
        new ChainTypeManager(address(0));
        new ProxyAdmin();

        new L2VerifierFflonk();
        new L2VerifierPlonk();

        new TestnetVerifier(L2VerifierFflonk(address(0)), L2VerifierPlonk(address(0)));
        new DualVerifier(L2VerifierFflonk(address(0)), L2VerifierPlonk(address(0)));

        new ValidatorTimelock(address(0), 0);
        new ServerNotifier(false);

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
            rollupL2DAValidatorAddress: address(0x456),
            testnetVerifier: true,
            adminSelectors: new bytes4[](2),
            executorSelectors: new bytes4[](2),
            mailboxSelectors: new bytes4[](2),
            gettersSelectors: new bytes4[](2),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            feeParams: FeeParams({
                // Just random values
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: uint32(1_000_000),
                maxPubdataPerBatch: uint32(500_000),
                maxL2GasPerBatch: uint32(2_000_000_000),
                priorityTxMaxPubdata: uint32(99_000),
                minimalL2GasPrice: uint64(20000000)
            }),
            bootloaderHash: bytes32(uint256(0xabc)),
            defaultAccountHash: bytes32(uint256(0xdef)),
            evmEmulatorHash: bytes32(uint256(0xdef)),
            priorityTxMaxGasLimit: 100000,
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
        // Just to publish bytecode
        new GatewayCTMDeployer(deployerConfig);

        (
            DeployedContracts memory calculatedDeployedContracts,
            bytes memory create2Calldata,
            address ctmDeployerAddress
        ) = GatewayCTMDeployerHelper.calculateAddresses(bytes32(0), deployerConfig);

        GatewayCTMDeployerTester tester = new GatewayCTMDeployerTester();
        (DeployedContracts memory deployedContracts, address correctCTMDeployerAddress) = tester.deployCTMDeployer(
            create2Calldata
        );

        require(ctmDeployerAddress == correctCTMDeployerAddress, "Incorrect address");

        DeployedContractsComparator.compareDeployedContracts(calculatedDeployedContracts, deployedContracts);

        // require(keccak256(abi.encode(calculatedDeployedContracts)) == keccak256(abi.encode(deployedContracts)), "Incorrect calculated addresses");

        // GatewayCTMDeployer deployer = new GatewayCTMDeployer(
        //     deployerConfig
        // );

        // DeployedContracts memory deployedContracts = deployer.getDeployedContracts();
    }
}

library DeployedContractsComparator {
    function compareDeployedContracts(DeployedContracts memory a, DeployedContracts memory b) internal pure {
        compareStateTransitionContracts(a.stateTransition, b.stateTransition);
        compareDAContracts(a.daContracts, b.daContracts);
        compareBytes(a.diamondCutData, b.diamondCutData, "diamondCutData");
    }

    function compareStateTransitionContracts(
        StateTransitionContracts memory a,
        StateTransitionContracts memory b
    ) internal pure {
        require(a.chainTypeManagerProxy == b.chainTypeManagerProxy, "chainTypeManagerProxy differs");
        require(
            a.chainTypeManagerImplementation == b.chainTypeManagerImplementation,
            "chainTypeManagerImplementation differs"
        );
        require(a.verifier == b.verifier, "verifier differs");
        require(a.adminFacet == b.adminFacet, "adminFacet differs");
        require(a.mailboxFacet == b.mailboxFacet, "mailboxFacet differs");
        require(a.executorFacet == b.executorFacet, "executorFacet differs");
        require(a.gettersFacet == b.gettersFacet, "gettersFacet differs");
        require(a.diamondInit == b.diamondInit, "diamondInit differs");
        require(a.genesisUpgrade == b.genesisUpgrade, "genesisUpgrade differs");
        require(a.validatorTimelock == b.validatorTimelock, "validatorTimelock differs");
        require(a.chainTypeManagerProxyAdmin == b.chainTypeManagerProxyAdmin, "chainTypeManagerProxyAdmin differs");
        require(a.serverNotifierProxy == b.serverNotifierProxy, "serverNotifier proxy differs");
    }

    function compareDAContracts(DAContracts memory a, DAContracts memory b) internal pure {
        require(a.rollupDAManager == b.rollupDAManager, "rollupDAManager differs");
        require(a.relayedSLDAValidator == b.relayedSLDAValidator, "relayedSLDAValidator differs");
        require(a.validiumDAValidator == b.validiumDAValidator, "validiumDAValidator differs");
    }

    function compareBytes(bytes memory a, bytes memory b, string memory fieldName) internal pure {
        require(keccak256(a) == keccak256(b), string(abi.encodePacked(fieldName, " differs")));
    }
}
