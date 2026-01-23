// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/Script.sol";

import {DAContracts, DeployedContracts, GatewayCTMDeployer, GatewayCTMDeployerConfig, StateTransitionContracts} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "contracts/state-transition/data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";

import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {ZKsyncOSVerifierFflonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR, L2_CREATE2_FACTORY_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GatewayCTMDeployerHelper} from "deploy-scripts/gateway/GatewayCTMDeployerHelper.sol";

// We need to use contract the zkfoundry consistently uses
// zk environment only within a deployed contract
contract GatewayCTMDeployerTester {
    function deployCTMDeployer(
        bytes memory data
    ) external returns (DeployedContracts memory deployedContracts, address addr) {
        (bool success, bytes memory result) = L2_CREATE2_FACTORY_ADDR.call(data);
        require(success, "failed to deploy");

        addr = abi.decode(result, (address));

        deployedContracts = GatewayCTMDeployer(addr).getDeployedContracts();
    }
}

contract GatewayCTMDeployerTest is Test {
    GatewayCTMDeployerConfig deployerConfig;

    // This is done merely to publish the respective bytecodes.
    function _predeployContracts() internal {
        new MailboxFacet(1, L2_CHAIN_ASSET_HANDLER_ADDR, IEIP7702Checker(address(0)), false);
        new ExecutorFacet(1);
        new GettersFacet();
        new AdminFacet(1, RollupDAManager(address(0)), false);

        new DiamondInit(false);
        new L1GenesisUpgrade();
        new RollupDAManager();
        new ValidiumL1DAValidator();
        new RelayedSLDAValidator();
        new ZKsyncOSChainTypeManager(address(0), address(0), address(0));
        new EraChainTypeManager(address(0), address(0), address(0));
        new ProxyAdmin();

        new EraVerifierFflonk();
        new EraVerifierPlonk();

        new EraTestnetVerifier(EraVerifierFflonk(address(0)), EraVerifierPlonk(address(0)));

        new ValidatorTimelock(L2_BRIDGEHUB_ADDR);
        new ServerNotifier();

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
        require(a.multicall3 == b.multicall3, "multicall3 differs");
        compareStateTransitionContracts(a.stateTransition, b.stateTransition);
        compareDAContracts(a.daContracts, b.daContracts);
        compareBytes(a.diamondCutData, b.diamondCutData, "diamondCutData");
    }

    function compareStateTransitionContracts(
        StateTransitionContracts memory a,
        StateTransitionContracts memory b
    ) internal pure {
        require(a.verifiers.verifier == b.verifiers.verifier, "verifier differs");
        require(a.facets.adminFacet == b.facets.adminFacet, "adminFacet differs");
        require(a.facets.mailboxFacet == b.facets.mailboxFacet, "mailboxFacet differs");
        require(a.facets.executorFacet == b.facets.executorFacet, "executorFacet differs");
        require(a.facets.gettersFacet == b.facets.gettersFacet, "gettersFacet differs");
        require(a.facets.diamondInit == b.facets.diamondInit, "diamondInit differs");
        require(a.genesisUpgrade == b.genesisUpgrade, "genesisUpgrade differs");
        require(a.validatorTimelock == b.validatorTimelock, "validatorTimelock differs");
        require(a.chainTypeManagerProxyAdmin == b.chainTypeManagerProxyAdmin, "chainTypeManagerProxyAdmin differs");
        require(a.serverNotifierProxy == b.serverNotifierProxy, "serverNotifier proxy differs");
        require(a.chainTypeManagerProxy == b.chainTypeManagerProxy, "chainTypeManagerProxy differs");
        require(
            a.chainTypeManagerImplementation == b.chainTypeManagerImplementation,
            "chainTypeManagerImplementation differs"
        );
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
