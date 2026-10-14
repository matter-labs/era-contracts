// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {INTEROP_FEE_UNITS_SLOT} from "contracts/common/Config.sol";
import {
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BOOTLOADER_ADDRESS
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

/// @title L2InteropFeeUnitsTestAbstract
/// @notice Covers the InteropCenter's interop fee unit counter that the L1 interop fee is charged on.
/// See {protocol-docs/interop-fee.md}.
abstract contract L2InteropFeeUnitsTestAbstract is L2InteropTestUtils {
    /// @dev The bundle salt of the next `_sendBundle`.
    uint256 internal sentBundles;

    function test_interopFeeUnits_slotConstantMatchesDerivation() public pure {
        assertEq(INTEROP_FEE_UNITS_SLOT, bytes32(uint256(keccak256("zksync.interop-center.interop-fee-units")) - 1));
    }

    function test_interopFeeUnits_startsAtZero() public view {
        assertEq(l2InteropCenter.interopFeeUnits(), 0);
    }

    function test_interopFeeUnits_countsEveryCallOfL2ToL2Bundles() public {
        _sendBundle(1, 0);
        assertEq(l2InteropCenter.interopFeeUnits(), 1);

        _sendBundle(3, 0);
        assertEq(l2InteropCenter.interopFeeUnits(), 4);
    }

    function test_interopFeeUnits_bundleWithoutCallsAddsNothing() public {
        _sendBundle(1, 0);
        _sendBundle(0, 0);
        assertEq(l2InteropCenter.interopFeeUnits(), 1);
    }

    /// @dev An indirect call (the asset router's token transfer) counts like a direct one.
    function test_interopFeeUnits_countsIndirectCalls() public {
        address l2Token = initializeTokenByDeposit();
        uint256 balanceBefore = IERC20(l2Token).balanceOf(address(this));
        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = _tokenCallStarter(l2Token, TRANSFER_AMOUNT, makeAddr("feeUnitsRecipient"))[0];
        calls[1] = _calls(1)[0];

        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false, bytes32(0))
        );

        assertEq(IERC20(l2Token).balanceOf(address(this)), balanceBefore - TRANSFER_AMOUNT, "the indirect call ran");
        assertEq(l2InteropCenter.interopFeeUnits(), 2);
    }

    /// @dev The bootloader reads the counter straight from this slot, so the getter and the slot must agree.
    function test_interopFeeUnits_isStoredAtTheConsensusSlot() public {
        _sendBundle(2, 0);
        assertEq(uint256(vm.load(L2_INTEROP_CENTER_ADDR, INTEROP_FEE_UNITS_SLOT)), 2);
        assertEq(uint256(vm.load(L2_INTEROP_CENTER_ADDR, INTEROP_FEE_UNITS_SLOT)), l2InteropCenter.interopFeeUnits());
    }

    /// @dev The L1 operator fee is independent of the user-side fees: a bundle that pays the L2 base-token fee
    /// is still counted once per call.
    function test_interopFeeUnits_countedRegardlessOfUserFee() public {
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        _sendBundle(2, protocolFee * 2);

        assertEq(l2InteropCenter.interopFeeUnits(), 2);
    }

    /// @dev The ERC-7786 entry point sends a single-call bundle.
    function test_interopFeeUnits_sendMessageCountsOneCall() public {
        vm.prank(makeAddr("feeUnitsSender"));
        l2InteropCenter.sendMessage(
            InteroperableAddress.formatEvmV1(destinationChainId, interopTargetContract),
            hex"",
            InteropLibrary.buildBundleAttributes(address(0), address(0), false, bytes32(0))
        );
        assertEq(l2InteropCenter.interopFeeUnits(), 1);
    }

    function test_interopFeeUnits_withdrawalToL1IsNotCounted() public {
        TestnetERC20Token l2NativeToken = new TestnetERC20Token("token", "T", 18);
        uint256 withdrawAmount = 100;
        l2NativeToken.mint(address(this), withdrawAmount);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, withdrawAmount);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(l2NativeToken));
        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(L1_CHAIN_ID),
            DataEncoding.encodeInteropWithdrawalCallStarters(
                assetId,
                DataEncoding.encodeBridgeBurnData(withdrawAmount, address(1), address(l2NativeToken))
            ),
            new bytes[](0)
        );

        assertEq(l2NativeToken.balanceOf(address(this)), 0, "the withdrawal must have gone through");
        assertEq(l2InteropCenter.interopFeeUnits(), 0);
    }

    function testFuzz_interopFeeUnits_sumsCallsAcrossBundles(uint8 _first, uint8 _second) public {
        uint256 first = bound(_first, 0, 8);
        uint256 second = bound(_second, 0, 8);

        _sendBundle(first, 0);
        _sendBundle(second, 0);

        assertEq(l2InteropCenter.interopFeeUnits(), first + second);
    }

    function _sendBundle(uint256 _callCount, uint256 _value) internal {
        address sender = makeAddr("feeUnitsSender");
        vm.deal(sender, _value);
        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(
            address(0),
            UNBUNDLER_ADDRESS,
            false,
            bytes32(sentBundles++)
        );
        InteropCallStarter[] memory calls = _calls(_callCount);
        vm.prank(sender);
        l2InteropCenter.sendBundle{value: _value}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );
    }

    function _calls(uint256 _count) internal view returns (InteropCallStarter[] memory calls) {
        calls = new InteropCallStarter[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            calls[i] = InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(interopTargetContract),
                data: hex"",
                callAttributes: new bytes[](0)
            });
        }
    }
}
