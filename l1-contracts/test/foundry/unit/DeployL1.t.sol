// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StateTransitionManager} from "../../../contracts/state-transition/StateTransitionManager.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployL1Script} from "../../../deploy-scripts/DeployL1.s.sol";
import {Bridgehub} from "../../../contracts/bridgehub/Bridgehub.sol";
import {L1SharedBridge} from "../../../contracts/bridge/L1SharedBridge.sol";
import {DeployL1Utils} from "../../../deploy-scripts/_DeployL1.s.sol";
import {RegisterHyperchainScript} from "../../../deploy-scripts/RegisterHyperchain.s.sol";
import {ValidatorTimelock} from "../../../contracts/state-transition/ValidatorTimelock.sol";
import {console2} from "forge-std/Script.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "forge-std/console.sol";
import {AcceptAdmin} from "../../../deploy-scripts/AcceptAdmin.s.sol";

contract DeployL1Test is Test {
    using stdStorage for StdStorage;
    using stdToml for string;

    struct StateTransitionDeployedAddresses {
        address stateTransitionProxy;
        address stateTransitionImplementation;
        address verifier;
        address adminFacet;
        address mailboxFacet;
        address executorFacet;
        address gettersFacet;
        address diamondInit;
        address genesisUpgrade;
        address defaultUpgrade;
        address diamondProxy;
    }

    DeployL1Script private l1Script;
    RegisterHyperchainScript private hyperchain;

    StateTransitionDeployedAddresses addr;
    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    address public sharedBridgeProxyAddress;
    L1SharedBridge public sharedBridge;

    address stateTransitionProxy;
    address diamondProxy;

    function _run() public {
        DeployL1Utils._initializeConfig();
        DeployL1Utils._instantiateCreate2Factory();
        DeployL1Utils._deployIfNeededMulticall3();
        DeployL1Utils._deployVerifier();
        DeployL1Utils._deployDefaultUpgrade();
        DeployL1Utils._deployGenesisUpgrade();
        DeployL1Utils._deployValidatorTimelock();
        DeployL1Utils._deployGovernance();

        ProxyAdmin proxyAdmin = new ProxyAdmin();
        vm.startBroadcast(proxyAdmin.owner());
        proxyAdmin.transferOwnership(DeployL1Utils.getOwnerAddress());
        vm.stopBroadcast();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        DeployL1Utils.saveTransparentProxyAdminAddress(address(proxyAdmin));

        DeployL1Utils._deployBridgehubContract();
        DeployL1Utils._deployBlobVersionedHashRetriever();
        DeployL1Utils._deployStateTransitionManagerContract();

        Bridgehub bridgehub = Bridgehub(DeployL1Utils.getBridgehubProxyAddress());
        vm.startBroadcast(bridgehub.owner());
        bridgehub.addStateTransitionManager(DeployL1Utils.getBridgehubStateTransitionProxy());
        vm.stopBroadcast();

        vm.startBroadcast(bridgehub.owner());
        ValidatorTimelock validatorTimelock = ValidatorTimelock(DeployL1Utils.getValidatorTimlock());
        validatorTimelock.setStateTransitionManager(
            IStateTransitionManager(DeployL1Utils.getBridgehubStateTransitionProxy())
        );
        console.log("StateTransitionManager set in ValidatorTimelock");
        vm.stopBroadcast();

        DeployL1Utils._deployDiamondProxy();
        DeployL1Utils._deploySharedBridgeContracts();

        vm.startBroadcast(bridgehub.owner());
        bridgehub.addToken(DeployL1Utils.ADDRESS_ONE);
        bridgehub.setSharedBridge(DeployL1Utils.getBridgesProxy());
        vm.stopBroadcast();
        console.log("SharedBridge registered");

        DeployL1Utils._deployErc20BridgeImplementation();
        DeployL1Utils._deployErc20BridgeProxy();

        L1SharedBridge sharedBridge = L1SharedBridge(DeployL1Utils.getBridgesProxy());
        vm.startBroadcast(sharedBridge.owner());
        sharedBridge.setL1Erc20Bridge(DeployL1Utils.getERC20Proxy());
        vm.stopBroadcast();
        console.log("SharedBridge updated with ERC20Bridge address");

        vm.startBroadcast(bridgehub.owner());
        validatorTimelock.transferOwnership(DeployL1Utils.getOwnerAddress());
        vm.stopBroadcast();

        vm.startBroadcast(bridgehub.owner());
        bridgehub.transferOwnership(DeployL1Utils.getGovernanceAddress());
        vm.stopBroadcast();
        _acceptOwnership(bridgehub);
        console.log("Bridge Owner", bridgehub.owner());
        console.log("Governance", DeployL1Utils.getGovernanceAddress());
        vm.startBroadcast(sharedBridge.owner());
        sharedBridge.transferOwnership(DeployL1Utils.getGovernanceAddress());
        vm.stopBroadcast();

        DeployL1Utils._saveOutput();
    }

    function _acceptOwnership(Bridgehub bridgeHub) private {
        vm.startPrank(bridgeHub.pendingOwner());
        bridgeHub.acceptOwnership();
        vm.stopPrank();
    }

    function setUp() public {
        // l1Script = new DeployL1Script();
        // l1Script.run();

        _run();

        // AcceptAdmin acceptAdminScript = new AcceptAdmin();
        // acceptAdminScript.run();
        
        vm.warp(100);

        hyperchain = new RegisterHyperchainScript();
        hyperchain.run();

        bridgehubProxyAddress = DeployL1Utils.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);

        sharedBridgeProxyAddress = DeployL1Utils.getSharedBridgeProxyAddress();
        sharedBridge = L1SharedBridge(sharedBridgeProxyAddress);

        bridgehubOwnerAddress = bridgeHub.owner();

        stateTransitionProxy = DeployL1Utils.getBridgehubStateTransitionProxy();
        diamondProxy = DeployL1Utils.getStateTransitionDiamondProxy();

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l1.toml");
        string memory toml = vm.readFile(path);
        string memory key = "$.deployed_addresses.state_transition";
        addr.stateTransitionProxy = toml.readAddress(string.concat(key, ".state_transition_proxy_addr"));
        addr.stateTransitionImplementation = toml.readAddress(
            string.concat(key, ".state_transition_implementation_addr")
        );
        addr.verifier = toml.readAddress(string.concat(key, ".verifier_addr"));
        addr.adminFacet = toml.readAddress(string.concat(key, ".admin_facet_addr"));
        addr.mailboxFacet = toml.readAddress(string.concat(key, ".mailbox_facet_addr"));
        addr.executorFacet = toml.readAddress(string.concat(key, ".executor_facet_addr"));
        addr.gettersFacet = toml.readAddress(string.concat(key, ".getters_facet_addr"));
        addr.diamondInit = toml.readAddress(string.concat(key, ".diamond_init_addr"));
        addr.genesisUpgrade = toml.readAddress(string.concat(key, ".genesis_upgrade_addr"));
        addr.defaultUpgrade = toml.readAddress(string.concat(key, ".default_upgrade_addr"));
        addr.diamondProxy = toml.readAddress(string.concat(key, ".diamond_proxy_addr"));
    }

    function test_checkStateTransitionMenagerAddress() public {
        // address stateTransitionAddress1 = addr.stateTransitionProxy;
        // address stateTransitionAddress2 = l1Script.deployStateTransitionManagerProxy();
        // assertEq(stateTransitionAddress1, stateTransitionAddress2);
    }

    // function test_checkStateTransitionHyperChainAddress() public {
    //     address stateTransitionAddress1 = addr.diamondProxy;
    //     address stateTransitionAddress2 = diamondProxy;
    //     assertEq(stateTransitionAddress1, stateTransitionAddress2);
    // }

    // function test_checkBridgeHubHyperchainAddress() public {
    //     address stateTransitionAddress1 = addr.diamondProxy;
    //     address stateTransitionAddress3 = 0xB1a3e11Fe6c863f21b1c93eF53528A7797FD0fa9;
    //     assertEq(stateTransitionAddress1, stateTransitionAddress3);
    // }
}
