// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {GatewayVotePreparation} from "deploy-scripts/gateway/GatewayVotePreparation.s.sol";
import {Call} from "contracts/governance/Common.sol";

/// @title GatewayVotePreparationForTests
/// @notice Test version of GatewayVotePreparation that exposes internal state for testing
contract GatewayVotePreparationForTests is GatewayVotePreparation {
    /// @notice Get the gateway chain ID from config
    function getGatewayChainId() public view returns (uint256) {
        return gatewayChainId;
    }

    /// @notice Get the CTM address
    function getCTM() public view returns (address) {
        return ctm;
    }

    /// @notice Get the refund recipient
    function getRefundRecipient() public view returns (address) {
        return refundRecipient;
    }

    /// @notice Get the era chain ID
    function getEraChainId() public view returns (uint256) {
        return eraChainId;
    }
}

/// @title GatewayVotePreparationTests
/// @notice Integration tests for GatewayVotePreparation script
/// @dev These tests verify that GatewayVotePreparation compiles and its contract structure is valid
contract GatewayVotePreparationTests is Test {
    /// @notice Test that GatewayVotePreparation contract can be instantiated
    /// @dev This verifies that the GatewayVotePreparation import compiles and the contract structure is valid
    function test_gatewayVotePreparationCanBeInstantiated() public {
        // Create the GatewayVotePreparation test script - this verifies the contract compiles and can be deployed
        GatewayVotePreparationForTests votePreparationScript = new GatewayVotePreparationForTests();

        // Verify the contract was created (address is non-zero)
        assertTrue(address(votePreparationScript) != address(0), "GatewayVotePreparation should be instantiated");
    }

    /// @notice Test that GatewayVotePreparation initial state is correct
    function test_gatewayVotePreparationInitialState() public {
        GatewayVotePreparationForTests votePreparationScript = new GatewayVotePreparationForTests();

        // Initial state should be zero/empty before initialization
        assertEq(votePreparationScript.getGatewayChainId(), 0, "Gateway chain ID should be 0 initially");
        assertEq(votePreparationScript.getCTM(), address(0), "CTM should be zero address initially");
        assertEq(votePreparationScript.getRefundRecipient(), address(0), "Refund recipient should be zero initially");
        assertEq(votePreparationScript.getEraChainId(), 0, "Era chain ID should be 0 initially");
    }

    // Exclude from coverage report
    function test() internal virtual {}
}
