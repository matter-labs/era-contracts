// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";

import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

/// @title L2BridgehubAliasRegressionTestAbstract
/// @notice Regression tests for the onlyChainRegistrationSender modifier alias fix (PR #1765)
abstract contract L2BridgehubAliasRegressionTestAbstract is Test, SharedL2ContractDeployer {
    // The L1 address that will be the chain registration sender
    address internal l1ChainRegistrationSender;
    // The aliased version (as it appears on L2)
    address internal aliasedChainRegistrationSender;

    function setUp() public virtual override {
        super.setUp();

        // Get the stored chainRegistrationSender from L2Bridgehub
        aliasedChainRegistrationSender = L2Bridgehub(L2_BRIDGEHUB_ADDR).chainRegistrationSender();

        // Calculate what the original L1 address would be
        l1ChainRegistrationSender = AddressAliasHelper.undoL1ToL2Alias(aliasedChainRegistrationSender);
    }

    /// @notice Test that the aliased sender can successfully call registerChainForInterop
    /// @dev This is the correct behavior after the fix
    /// @dev Note: We don't verify the storage write because mock calls in the test setup interfere.
    ///      The key test is that the call doesn't revert with Unauthorized.
    function test_regression_aliasedSenderCanRegisterChain() public {
        uint256 testChainId = 12345;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0xABCDEF));

        // Verify that aliasedChainRegistrationSender is set and is what we expect
        assertNotEq(aliasedChainRegistrationSender, address(0), "chainRegistrationSender should be set");

        // The aliased address should be able to call registerChainForInterop
        // This call should NOT revert - if it does, the test fails
        vm.prank(aliasedChainRegistrationSender);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).registerChainForInterop(testChainId, testBaseTokenAssetId);

        // If we get here without revert, the authorization check passed
        // That's the core of this regression test - verifying the modifier allows the correct caller
    }

    /// @notice Test that the non-aliased (original L1) address cannot call registerChainForInterop
    /// @dev Before the fix, the buggy modifier would have checked against this address
    function test_regression_nonAliasedSenderCannotRegisterChain() public {
        uint256 testChainId = 12346;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x123456));

        // The non-aliased address (original L1 address) should NOT be able to call
        vm.prank(l1ChainRegistrationSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, l1ChainRegistrationSender));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).registerChainForInterop(testChainId, testBaseTokenAssetId);
    }

    /// @notice Test that SERVICE_TRANSACTION_SENDER can still call registerChainForInterop
    /// @dev The modifier has a special bypass for SERVICE_TRANSACTION_SENDER
    function test_regression_serviceTransactionSenderCanRegisterChain() public {
        uint256 testChainId = 12347;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x789ABC));

        // SERVICE_TRANSACTION_SENDER should be able to call without reverting
        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).registerChainForInterop(testChainId, testBaseTokenAssetId);

        // If we get here without revert, the SERVICE_TRANSACTION_SENDER bypass works correctly
    }

    /// @notice Test that random addresses cannot call registerChainForInterop
    function test_regression_randomAddressCannotRegisterChain() public {
        uint256 testChainId = 12348;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0xDEADBEEF));
        address randomAddress = makeAddr("randomAddress");

        vm.prank(randomAddress);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomAddress));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).registerChainForInterop(testChainId, testBaseTokenAssetId);
    }

    /// @notice Test demonstrating the aliasing relationship
    /// @dev This unit test verifies the address aliasing math
    function test_regression_aliasingRelationship() public view {
        // Verify the aliasing relationship
        address reAliased = AddressAliasHelper.applyL1ToL2Alias(l1ChainRegistrationSender);
        assertEq(reAliased, aliasedChainRegistrationSender, "Aliasing should be reversible");

        // Verify that the stored chainRegistrationSender is different from the L1 address
        // (This would only be equal if the address was never aliased, which is not the case on L2)
        assertNotEq(
            l1ChainRegistrationSender,
            aliasedChainRegistrationSender,
            "L1 address and aliased address should be different"
        );
    }

    /// @notice Fuzz test with various chain IDs and asset IDs
    /// @dev Ensures the modifier works correctly for any registration parameters
    function testFuzz_regression_aliasedSenderCanRegisterVariousChains(
        uint256 testChainId,
        bytes32 testBaseTokenAssetId
    ) public {
        // Avoid chainId 0 which might have special meaning
        vm.assume(testChainId > 0);

        // The aliased sender should be able to register any chain without Unauthorized revert
        vm.prank(aliasedChainRegistrationSender);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).registerChainForInterop(testChainId, testBaseTokenAssetId);

        // If we get here without revert, the authorization check passed for any chain ID
    }

    /// @notice Fuzz test that random addresses are always rejected
    /// @dev Ensures the modifier correctly rejects unauthorized callers
    function testFuzz_regression_randomAddressesCannotRegister(address randomCaller) public {
        // Exclude the valid callers
        vm.assume(randomCaller != aliasedChainRegistrationSender);
        vm.assume(randomCaller != SERVICE_TRANSACTION_SENDER);

        uint256 testChainId = 99999;
        bytes32 testBaseTokenAssetId = bytes32(uint256(0x12345));

        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        L2Bridgehub(L2_BRIDGEHUB_ADDR).registerChainForInterop(testChainId, testBaseTokenAssetId);
    }
}
