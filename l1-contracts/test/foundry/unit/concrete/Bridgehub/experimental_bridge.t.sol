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
    }

    function test_isOwnerBeingSetCorrectly() public {
        address defaultOwner = bridgeHub.owner();

        emit log_named_address("Owner", defaultOwner);
        emit log_named_address("This contract's address", address(this));

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
}