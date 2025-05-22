// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// import {console} from "forge-std/console.sol";
import {BundleMetadata, InteropCall} from "../common/Messaging.sol";
import {TransientPrimitivesLib, taddress, tbytes32, tuint256} from "../common/libraries/TransientPrimitves/TransientPrimitives.sol";
import {TransientBytesLib} from "../common/libraries/TransientPrimitves/TransientBytesLib.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "../common/l2-helpers/L2ContractAddresses.sol";

bytes32 constant BUNDLE_METADATA_SLOT_MODIFIER = bytes32(uint256(keccak256("BUNDLE_METADATA_SLOT_MODIFIER")) - 1);
bytes32 constant CALL_SLOT_MODIFIER = bytes32(uint256(keccak256("CALL_SLOT_MODIFIER")) - 1);

library TransientInterop {
    function getBundleMetadata(bytes32 _bundleId) internal view returns (BundleMetadata memory bundleMetadata) {
        uint256 bundleSlot = uint256(keccak256(abi.encodePacked(BUNDLE_METADATA_SLOT_MODIFIER, _bundleId)));
        return
            BundleMetadata(
                TransientPrimitivesLib.getUint256(bundleSlot),
                address(uint160(TransientPrimitivesLib.getUint256(bundleSlot + 1))),
                TransientPrimitivesLib.getUint256(bundleSlot + 2),
                TransientPrimitivesLib.getUint256(bundleSlot + 3)
            );
    }

    function setBundleMetadata(bytes32 _bundleId, BundleMetadata memory _bundleMetadata) internal {
        uint256 bundleSlot = uint256(keccak256(abi.encodePacked(BUNDLE_METADATA_SLOT_MODIFIER, _bundleId)));
        TransientPrimitivesLib.set(bundleSlot, _bundleMetadata.destinationChainId);
        TransientPrimitivesLib.set(bundleSlot + 1, uint256(uint160(_bundleMetadata.sender)));
        TransientPrimitivesLib.set(bundleSlot + 2, _bundleMetadata.callCount);
        TransientPrimitivesLib.set(bundleSlot + 3, _bundleMetadata.totalValue);
    }

    function getBundleCall(bytes32 _bundleId, uint256 _index) internal view returns (InteropCall memory interopCall) {
        uint256 callSlot = uint256(keccak256(abi.encodePacked(CALL_SLOT_MODIFIER, _bundleId, _index)));
        interopCall.to = address(uint160(TransientPrimitivesLib.getUint256(callSlot)));
        interopCall.from = address(uint160(TransientPrimitivesLib.getUint256(callSlot + 1)));
        interopCall.value = TransientPrimitivesLib.getUint256(callSlot + 2);
        interopCall.data = TransientBytesLib.getBytes(callSlot + 3);
        return interopCall;
    }

    function addCallToBundle(bytes32 _bundleId, InteropCall memory _interopCall) internal {
        BundleMetadata memory bundleMetadata = getBundleMetadata(_bundleId);
        // console.log("addCallToBundle 2", bundleMetadata.sender);
        // console.logBytes32(_bundleId);

        uint256 callCount = bundleMetadata.callCount;
        // console.log("addCallToBundle", callCount);
        // console.logBytes32(_bundleId);

        // setting the bundle data
        uint256 callSlot = uint256(keccak256(abi.encodePacked(CALL_SLOT_MODIFIER, _bundleId, callCount)));
        TransientPrimitivesLib.set(callSlot, uint256(uint160(_interopCall.to)));
        TransientPrimitivesLib.set(callSlot + 1, uint256(uint160(_interopCall.from)));
        TransientPrimitivesLib.set(callSlot + 2, _interopCall.value);
        TransientBytesLib.setBytes(callSlot + 3, _interopCall.data);

        bundleMetadata.callCount = callCount + 1;
        // console.log("addCallToBundle totalValue", bundleMetadata.totalValue);
        // console.log("addCallToBundle added value", _interopCall.value);
        bundleMetadata.totalValue = bundleMetadata.totalValue + _interopCall.value;
        setBundleMetadata(_bundleId, bundleMetadata);
    }
}
