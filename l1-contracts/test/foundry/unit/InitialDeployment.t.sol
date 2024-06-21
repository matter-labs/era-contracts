// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployL1Script} from "../../../deploy-scripts/DeployL1.s.sol";
import {Bridgehub} from "../../../contracts/bridgehub/Bridgehub.sol";
import {L1SharedBridge} from "../../../contracts/bridge/L1SharedBridge.sol";

contract InitialDeploymentTest is Test {
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

    StateTransitionDeployedAddresses addr;
    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    address public sharedBridgeProxyAddress;
    L1SharedBridge public sharedBridge;

    address stateTransitionProxy;
    address diamondProxy;

    function setUp() public {
        DeployL1Script l1Script = new DeployL1Script();
        l1Script.run();

        bridgehubProxyAddress = l1Script.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);

        sharedBridgeProxyAddress = l1Script.getSharedBridgeProxyAddress();
        sharedBridge = L1SharedBridge(sharedBridgeProxyAddress);

        bridgehubOwnerAddress = bridgeHub.owner();

        stateTransitionProxy = l1Script.getBridgehubStateTransitionProxy();
        diamondProxy = l1Script.getStateTransitionDiamondProxy();

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
        address stateTransitionAddress1 = stateTransitionProxy;
        address stateTransitionAddress2 = addr.stateTransitionProxy;
        assertEq(stateTransitionAddress1, stateTransitionAddress2);
    }

    function test_checkStateTransitionHyperChainAddress() public {
        address stateTransitionAddress1 = diamondProxy;
        address stateTransitionAddress2 = addr.diamondProxy;
        assertEq(stateTransitionAddress1, stateTransitionAddress2);
    }

    function test_checkBridgeHubHyperchainAddress() public {
        address stateTransitionAddress1 = addr.diamondProxy;
        address stateTransitionAddress3 = 0xB1a3e11Fe6c863f21b1c93eF53528A7797FD0fa9;
        assertEq(stateTransitionAddress1, stateTransitionAddress3);
    }
}
