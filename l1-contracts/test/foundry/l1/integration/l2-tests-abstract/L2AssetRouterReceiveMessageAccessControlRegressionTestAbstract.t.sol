// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2_ASSET_ROUTER_ADDR, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

/// @title L2AssetRouterReceiveMessageAccessControlRegressionTestAbstract
/// @notice Regression tests for the receiveMessage access control fix in L2AssetRouter
abstract contract L2AssetRouterReceiveMessageAccessControlRegressionTestAbstract is Test, SharedL2ContractDeployer {
    address internal attacker;

    function setUp() public virtual override {
        super.setUp();
        attacker = makeAddr("attacker");
    }

    function test_regression_receiveMessageRevertsForUnauthorizedCaller() public {
        // Prepare a valid-looking payload (finalizeDeposit selector + data)
        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            block.chainid, // originChainId
            bytes32(uint256(1)), // assetId
            abi.encode(address(0), address(attacker), address(0), uint256(1000), bytes("")) // transferData
        );

        // Create sender bytes (ERC-7930 format) - pretending to be L2AssetRouter on another chain
        bytes memory sender = InteroperableAddress.formatEvmV1(block.chainid + 1, L2_ASSET_ROUTER_ADDR);

        // Attacker tries to call receiveMessage directly
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, attacker));
        IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage(
            bytes32(0), // receiveId
            sender,
            payload
        );
    }

    /// @notice Test that receiveMessage reverts for any address that is not InteropHandler
    /// @dev Tests various addresses to ensure none can bypass the access control
    function test_regression_receiveMessageRevertsForVariousUnauthorizedAddresses() public {
        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            block.chainid,
            bytes32(uint256(1)),
            abi.encode(address(0), address(attacker), address(0), uint256(1000), bytes(""))
        );
        bytes memory sender = InteroperableAddress.formatEvmV1(block.chainid + 1, L2_ASSET_ROUTER_ADDR);

        // Test with various addresses
        address[] memory unauthorizedAddresses = new address[](5);
        unauthorizedAddresses[0] = address(0x1);
        unauthorizedAddresses[1] = address(this);
        unauthorizedAddresses[2] = makeAddr("randomUser");
        unauthorizedAddresses[3] = makeAddr("maliciousContract");
        unauthorizedAddresses[4] = address(l2AssetRouter); // Even the asset router itself can't call it

        for (uint256 i = 0; i < unauthorizedAddresses.length; i++) {
            vm.prank(unauthorizedAddresses[i]);
            vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, unauthorizedAddresses[i]));
            IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage(bytes32(0), sender, payload);
        }
    }

    /// @notice Test that receiveMessage does not revert when called by InteropHandler
    /// @dev Verifies the legitimate path still works - InteropHandler can call receiveMessage
    function test_regression_receiveMessageAllowedForInteropHandler() public {
        // Note: This test verifies that the InteropHandler CAN call receiveMessage.
        // The actual execution may still fail due to other validations (sender address, payload format, etc.)
        // but it should NOT fail with Unauthorized error.

        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            block.chainid + 1, // originChainId (different from L1 and current chain)
            bytes32(uint256(1)), // assetId
            abi.encode(address(0), address(this), address(0), uint256(1000), bytes(""))
        );

        // Sender must be L2AssetRouter on another L2 chain (not L1)
        bytes memory sender = InteroperableAddress.formatEvmV1(block.chainid + 1, L2_ASSET_ROUTER_ADDR);

        // InteropHandler calls receiveMessage - should not revert with Unauthorized
        vm.prank(L2_INTEROP_HANDLER_ADDR);

        // The call might revert for other reasons (e.g., asset not registered, invalid data),
        // but it should NOT revert with Unauthorized
        // We use a try-catch to verify the error is NOT Unauthorized
        try IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage(bytes32(0), sender, payload) {
            // If it succeeds, that's fine
        } catch (bytes memory reason) {
            // Check that it's not an Unauthorized error
            bytes4 errorSelector = bytes4(reason);
            assertTrue(errorSelector != Unauthorized.selector, "InteropHandler should not get Unauthorized error");
        }
    }

    /// @notice Test that a contract trying to impersonate InteropHandler still fails
    /// @dev Ensures that the access control cannot be bypassed by contract tricks
    function test_regression_contractCannotImpersonateInteropHandler() public {
        bytes memory payload = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            block.chainid,
            bytes32(uint256(1)),
            abi.encode(address(0), address(attacker), address(0), uint256(1000), bytes(""))
        );
        bytes memory sender = InteroperableAddress.formatEvmV1(block.chainid + 1, L2_ASSET_ROUTER_ADDR);

        // Deploy a malicious contract that tries to call receiveMessage
        MaliciousInteropCaller maliciousContract = new MaliciousInteropCaller();

        // The malicious contract should also be rejected
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(maliciousContract)));
        maliciousContract.tryCallReceiveMessage(L2_ASSET_ROUTER_ADDR, sender, payload);
    }
}

/// @notice Malicious contract that attempts to call receiveMessage
contract MaliciousInteropCaller {
    function tryCallReceiveMessage(address assetRouter, bytes memory sender, bytes memory payload) external {
        IERC7786Recipient(assetRouter).receiveMessage(bytes32(0), sender, payload);
    }
}
