//SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {IBridgehub, Bridgehub} from "solpp/bridgehub/Bridgehub.sol";

contract ExperimentalBridgeTest is Test {

    Bridgehub bridgeHub;
    address public bridgeOwner;

    function setUp() public {
        bridgeHub = new Bridgehub();
        bridgeOwner = makeAddr("BRIDGE_OWNER");
    
        // test if the ownership of the bridgeHub is set correctly or not
        address defaultOwner = bridgeHub.owner();

        // The defaultOwner should be the same as this contract address, since this is the one deploying the bridgehub contract
        assertEq(defaultOwner, address(this));

        // Now, the `reentrancyGuardInitializer` should prevent anyone from calling `initialize` since we have called the constructor of the contract
        // @follow-up Is this the intended behavior? @Vlad @kalman
        vm.expectRevert(bytes("1B"));
        bridgeHub.initialize(bridgeOwner);

        // The ownership can only be transfered by the current owner to a new owner via the two-step approach
        
        // Default owner calls transferOwnership
        bridgeHub.transferOwnership(bridgeOwner);

        // bridgeOwner calls acceptOwnership
        vm.prank(bridgeOwner);
        bridgeHub.acceptOwnership();

        // Ownership should have changed
        assertEq(bridgeHub.owner(), bridgeOwner);
    }

    function test_ownerCanSetDeployer(address randomCaller, address randomDeployer) public {
        /**
            Case I: A random address tries to call the `setDeployer` method and the call fails with the error: `Ownable: caller is not the owner`
            Case II: The bridgeHub owner calls the `setDeployer` method on `randomDeployer` and it becomes the deployer
        */
        
        if(randomCaller != bridgeHub.owner()) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.setDeployer(randomDeployer);

            // The deployer shouldn't have changed.
            assertEq(address(0), bridgeHub.deployer());
        } else { 
            vm.prank(randomCaller);
            bridgeHub.setDeployer(randomDeployer);

            assertEq(randomDeployer, bridgeHub.deployer());
        }
    }

    // @follow-up Concern:
    // 1. Addresses that do not implement the correct interface or any interface whatsoever (EOAs and address(0)) can also be added as a StateTransitionManager
    // 2. After being added, if the contracts are upgradable, they can change their logic to include malicious code as well.
    function test_addStateTransitionManager(address randomAddressWithoutTheCorrectInterface, address randomCaller) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            
            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        } else {
            vm.prank(bridgeOwner);
            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
            
            isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
            assertTrue(isSTMRegistered);

            // An address that has already been registered, cannot be registered again (atleast not before calling `removeStateTransitionManager`).
            vm.prank(bridgeOwner);
            vm.expectRevert(bytes("Bridgehub: state transition already registered"));
            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

            isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
            assertTrue(isSTMRegistered);
        }
    }
}