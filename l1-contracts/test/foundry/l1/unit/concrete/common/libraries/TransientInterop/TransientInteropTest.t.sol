// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransientInterop} from "contracts/bridgehub/TransientInterop.sol";
import {TransientInteropTester} from "contracts/dev-contracts/test/TransientInteropTest.sol";
import {BundleMetadata, InteropCall} from "contracts/common/Messaging.sol";
import {console} from "forge-std/console.sol";

// import {MerklePathEmpty, MerkleIndexOutOfBounds, MerklePathOutOfBounds} from "contracts/common/L1ContractErrors.sol";

contract TransientInteropTest is Test {
    bytes32 public bundleId = keccak256("test");
    TransientInteropTester interopTester;

    function setUp() public {
        interopTester = new TransientInteropTester();
    }

    function test_getBundleMetadata() public {
        BundleMetadata memory bundleMetadataBefore = TransientInterop.getBundleMetadata(bundleId);
        assertEq(bundleMetadataBefore.initiator, address(0));
        assertEq(bundleMetadataBefore.callCount, 0);
        assertEq(bundleMetadataBefore.totalValue, 0);

        uint256 checkpointGasLeftBefore = gasleft();
        TransientInterop.setBundleMetadata(
            bundleId,
            BundleMetadata({destinationChainId: 1, initiator: address(1), callCount: 1, totalValue: 1})
        );
        uint256 checkpointGasLeftAfter = gasleft();

        BundleMetadata memory bundleMetadataAfter = TransientInterop.getBundleMetadata(bundleId);
        assertEq(bundleMetadataAfter.initiator, address(1));
        assertEq(bundleMetadataAfter.callCount, 1);
        assertEq(bundleMetadataAfter.totalValue, 1);
        assert(checkpointGasLeftBefore - checkpointGasLeftAfter < 3000); // we are using tstore
    }

    function test_addCallToBundle() public {
        InteropCall memory interopCall = InteropCall({to: address(1), from: address(2), value: 1, data: "test"});
        TransientInterop.addCallToBundle(bundleId, interopCall);
        InteropCall memory bundleCall = TransientInterop.getBundleCall(bundleId, 0);
        assertEq(bundleCall.to, address(1));
        assertEq(bundleCall.from, address(2));
        assertEq(bundleCall.value, 1);
        assertEq(bundleCall.data, "test");

        BundleMetadata memory bundleMetadata = TransientInterop.getBundleMetadata(bundleId);
        assertEq(bundleMetadata.callCount, 1);
        assertEq(bundleMetadata.totalValue, 1);
    }

    function test_add2CallsToBundle() public {
        InteropCall memory interopCall = InteropCall({to: address(1), from: address(2), value: 1, data: "test"});
        TransientInterop.addCallToBundle(bundleId, interopCall);
        TransientInterop.addCallToBundle(bundleId, interopCall);
        InteropCall memory bundleCall = TransientInterop.getBundleCall(bundleId, 1);
        assertEq(bundleCall.to, address(1));
        assertEq(bundleCall.from, address(2));
        assertEq(bundleCall.value, 1);
        assertEq(bundleCall.data, "test");

        BundleMetadata memory bundleMetadata = TransientInterop.getBundleMetadata(bundleId);
        assertEq(bundleMetadata.callCount, 2);
        assertEq(bundleMetadata.totalValue, 2);
    }
}
