// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {MsgValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_FEE_UNITS_SLOT} from "contracts/common/Config.sol";
import {
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

/// @title L2InteropFeeUnitsTestAbstract
/// @notice Covers the InteropCenter's interop fee unit counter that the L1 interop fee is charged on.
/// See {protocol-docs/interop-fee.md}.
abstract contract L2InteropFeeUnitsTestAbstract is L2InteropTestUtils {
    function setUp() public virtual override {
        super.setUp();
        // `sendBundle` to another L2 needs a settlement layer.
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(block.chainid)
        );
    }

    function test_interopFeeUnits_slotConstantMatchesDerivation() public pure {
        assertEq(
            INTEROP_FEE_UNITS_SLOT,
            bytes32(uint256(keccak256("zksync.interop-center.interop-fee-units")) - 1)
        );
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

    function test_interopFeeUnits_failedSendIsNotCounted() public {
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        address sender = makeAddr("feeUnitsSender");
        vm.deal(sender, 1 ether);
        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(
            address(0),
            UNBUNDLER_ADDRESS,
            false,
            bytes32(0)
        );
        InteropCallStarter[] memory calls = _calls(2);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, protocolFee * 2, 0));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(destinationChainId), calls, bundleAttributes);

        assertEq(l2InteropCenter.interopFeeUnits(), 0);
    }

    function test_interopFeeUnits_withdrawalToL1IsNotCounted() public {
        TestnetERC20Token l2NativeToken = new TestnetERC20Token("token", "T", 18);
        uint256 withdrawAmount = 100;
        l2NativeToken.mint(address(this), withdrawAmount);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, withdrawAmount);
        // All L2->L1 messages pass in this environment.
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)"),
            abi.encode(bytes32(uint256(1)))
        );

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
        uint256 first = bound(_first, 1, 8);
        uint256 second = bound(_second, 1, 8);

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
            keccak256(abi.encode(l2InteropCenter.interopFeeUnits(), _callCount))
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
