// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {Call} from "contracts/governance/Common.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @title GatewayVotePreparationTests
/// @notice Integration tests for GatewayVotePreparation functionality
/// @dev Tests the gateway registration and governance call generation
contract GatewayVotePreparationTests is
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer,
    L2TxMocker,
    GatewayDeployer
{
    uint256 constant TEST_USERS_COUNT = 5;
    address[] public users;

    uint256 gatewayChainId = 506;
    IZKChain gatewayChain;

    function _generateUserAddresses() internal {
        require(users.length == 0, "Addresses already generated");
        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("user", i)));
            users.push(newAddress);
        }
    }

    function setUp() public {
        _generateUserAddresses();

        _deployL1Contracts();

        // Deploy the gateway chain
        _deployZKChain(ETH_TOKEN_ADDRESS, gatewayChainId);
        acceptPendingAdmin(gatewayChainId);

        _initializeGatewayScript();

        vm.deal(ecosystemConfig.ownerAddress, 100 ether);
        gatewayChain = IZKChain(IL1Bridgehub(addresses.bridgehub).getZKChain(gatewayChainId));
        vm.deal(gatewayChain.getAdmin(), 100 ether);
    }

    /// @notice Test that gateway can be registered as settlement layer
    function test_gatewayPreparationForTests_governanceRegisterGateway() public {
        // Verify gateway is not whitelisted before
        bool isWhitelistedBefore = addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId);
        assertFalse(isWhitelistedBefore, "Gateway should not be whitelisted initially");

        // Register gateway as settlement layer using the gatewayScript
        gatewayScript.governanceRegisterGateway();

        // Verify gateway is now whitelisted as a settlement layer
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should be whitelisted as settlement layer"
        );
    }

    /// @notice Test deploying and setting the gateway transaction filterer
    function test_gatewayPreparationForTests_deployAndSetTransactionFilterer() public {
        // First register gateway
        gatewayScript.governanceRegisterGateway();

        // Verify no filterer is set initially
        address filtererBefore = gatewayChain.getTransactionFilterer();
        assertEq(filtererBefore, address(0), "Filterer should not be set initially");

        // Deploy and set the transaction filterer
        gatewayScript.deployAndSetGatewayTransactionFilterer();

        // Verify the filterer is now set
        address filtererAfter = gatewayChain.getTransactionFilterer();
        assertTrue(filtererAfter != address(0), "Transaction filterer should be deployed and set");
    }

    /// @notice Test the full gateway registration flow
    function test_fullGatewayRegistrationFlow() public {
        // First register gateway as settlement layer
        gatewayScript.governanceRegisterGateway();

        // Deploy and set the transaction filterer
        gatewayScript.deployAndSetGatewayTransactionFilterer();

        // Verify the filterer is set
        address filterer = gatewayChain.getTransactionFilterer();
        assertTrue(filterer != address(0), "Transaction filterer should be deployed");

        // Perform full gateway registration
        gatewayScript.fullGatewayRegistration();

        // Verify gateway is still properly configured
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should remain whitelisted"
        );

        // Verify the chain is still accessible
        address zkChainAddress = addresses.bridgehub.getZKChain(gatewayChainId);
        assertTrue(zkChainAddress != address(0), "Gateway chain should still be registered");
    }

    /// @notice Test that register settlement layer call data is correctly encoded
    function test_registerSettlementLayerCallEncoding() public {
        // Build the expected call data
        bytes memory expectedData = abi.encodeCall(IL1Bridgehub.registerSettlementLayer, (gatewayChainId, true));

        // Execute the call as the bridgehub owner
        vm.prank(addresses.bridgehub.owner());
        (bool success, ) = address(addresses.bridgehub).call(expectedData);
        assertTrue(success, "Register settlement layer call should succeed");

        // Verify the gateway is now whitelisted
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should be whitelisted after direct call"
        );
    }

    /// @notice Test that multiple settlement layer registrations work correctly
    function test_multipleSettlementLayerRegistrations() public {
        // Register the first gateway
        gatewayScript.governanceRegisterGateway();
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "First gateway should be whitelisted"
        );

        // Deploy another chain
        uint256 secondGatewayChainId = 507;
        _deployZKChain(ETH_TOKEN_ADDRESS, secondGatewayChainId);
        acceptPendingAdmin(secondGatewayChainId);

        // Register the second chain as settlement layer
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(secondGatewayChainId, true);

        // Verify both are whitelisted
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "First gateway should still be whitelisted"
        );
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(secondGatewayChainId),
            "Second gateway should be whitelisted"
        );
    }

    /// @notice Test that settlement layer can be unregistered
    function test_unregisterSettlementLayer() public {
        // Register gateway
        gatewayScript.governanceRegisterGateway();
        assertTrue(addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId), "Gateway should be whitelisted");

        // Unregister gateway
        vm.prank(addresses.bridgehub.owner());
        addresses.bridgehub.registerSettlementLayer(gatewayChainId, false);

        // Verify gateway is no longer whitelisted
        assertFalse(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should not be whitelisted after unregistration"
        );
    }

    // Exclude from coverage report
    function test() internal override {}
}
