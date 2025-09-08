// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {MockContract} from "contracts/dev-contracts/MockContract.sol";

contract L2ComplexUpgraderTest is Test {
    L2ComplexUpgrader internal complexUpgrader;
    MockContract internal dummyUpgrade;

    address internal constant TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS = address(0x900f);
    address internal constant TEST_FORCE_DEPLOYER_ADDRESS = address(0x9007);

    event Called(uint256 value, bytes data);

    function setUp() public {
        // Deploy mock contract for testing
        dummyUpgrade = new MockContract();

        // Deploy the L2ComplexUpgrader contract normally first to get proper bytecode
        L2ComplexUpgrader tempUpgrader = new L2ComplexUpgrader();
        bytes memory deployedBytecode = address(tempUpgrader).code;

        // Set the bytecode at the system contract address
        vm.etch(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, deployedBytecode);
        complexUpgrader = L2ComplexUpgrader(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS);
    }

    function test_NonForceDeployerFailedToCall() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized(address)", address(this)));
        complexUpgrader.upgrade(address(dummyUpgrade), hex"deadbeef");
    }

    function test_SuccessfullyUpgraded() public {
        // Configure the mock to emit Called event for the specific calldata
        dummyUpgrade.setResult(MockContract.CallResult({input: hex"deadbeef", failure: false, returnData: ""}));

        // Impersonate the force deployer
        vm.prank(TEST_FORCE_DEPLOYER_ADDRESS);

        // Execute the upgrade - this will delegatecall to dummyUpgrade with the provided calldata
        // Since the delegatecall runs in the context of complexUpgrader, the event will appear from that address
        vm.expectEmit(true, true, true, true, TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS);
        emit Called(0, hex"deadbeef");

        complexUpgrader.upgrade(address(dummyUpgrade), hex"deadbeef");
    }
}
