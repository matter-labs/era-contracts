// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Unauthorized, InvalidSelector} from "contracts/common/L1ContractErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2_ASSET_ROUTER_ADDR, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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

    /// @notice Test that receiveMessage does not revert with Unauthorized when called by InteropHandler
    /// @dev We craft a payload with a deliberately wrong selector. Reaching the InvalidSelector
    ///      revert at L2AssetRouter.receiveMessage:251 is causally downstream of:
    ///        - the onlyL2InteropHandler gate at line 226, and
    ///        - the secondary sender-address Unauthorized check at line 244.
    ///      Therefore an InvalidSelector revert proves the access-control gate is open for InteropHandler.
    function test_regression_receiveMessageAllowedForInteropHandler() public {
        bytes4 bogusSelector = bytes4(0xdeadbeef);

        // Sender bytes that pass the L244 check: senderChainId != L1_CHAIN_ID and senderAddress == address(this).
        bytes memory sender = InteroperableAddress.formatEvmV1(block.chainid + 1, L2_ASSET_ROUTER_ADDR);

        // Payload with a non-finalizeDeposit selector so the L251 selector check is the deterministic next failure.
        bytes memory payload = abi.encodeWithSelector(
            bogusSelector,
            block.chainid + 1, // originChainId (different from L1 and current chain)
            bytes32(uint256(1)), // assetId
            abi.encode(address(0), address(this), address(0), uint256(1000), bytes(""))
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(InvalidSelector.selector, bogusSelector));
        IERC7786Recipient(L2_ASSET_ROUTER_ADDR).receiveMessage(bytes32(0), sender, payload);
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

/* Code/case coverage improvement suggestions:
  Unhappy-path
  1. test_regression_receiveMessageRevertsWhen_PayloadTooShort — call from L2_INTEROP_HANDLER_ADDR with payload.length <= 4 and
  vm.expectRevert(PayloadTooShort.selector). Pins the L248 check; complementary to the existing InvalidSelector-based test.
  2. test_regression_receiveMessageRevertsWhen_SenderChainIsL1 — craft sender with senderChainId == L1_CHAIN_ID, expect Unauthorized(senderAddress)
  from L244. Locks down the secondary Unauthorized check (currently only the gate-level Unauthorized at L226 is exercised).
  3. test_regression_receiveMessageRevertsWhen_SenderAddressNotSelf — craft sender with senderAddress != L2_ASSET_ROUTER_ADDR, expect
  Unauthorized(senderAddress) from L244. Same line, different branch.
  4. test_regression_receiveMessageRevertsWhen_ExecutedPayloadFails — valid selector but malformed inner args so address(this).call(payload) returns
   false, expect ExecuteMessageFailed.selector. Pins L255.

  Edge cases (best-effort)
  5. test_regression_receiveMessageRevertsWhen_SenderBytesMalformed — pass sender that fails InteroperableAddress.parseEvmV1Calldata (e.g., wrong
  length / version byte). Confirms parse errors surface as reverts before access-state checks corrupt anything
*/

/// @notice Malicious contract that attempts to call receiveMessage
contract MaliciousInteropCaller {
    function tryCallReceiveMessage(address assetRouter, bytes memory sender, bytes memory payload) external {
        IERC7786Recipient(assetRouter).receiveMessage(bytes32(0), sender, payload);
    }
}
