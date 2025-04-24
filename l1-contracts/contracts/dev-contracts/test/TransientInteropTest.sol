// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteropCall, BundleMetadata} from "../../common/Messaging.sol";
import {TransientInterop} from "../../bridgehub/TransientInterop.sol";

contract TransientInteropTester {
    function getBundleMetadata(bytes32 _bundleId) public view returns (BundleMetadata memory) {
        return TransientInterop.getBundleMetadata(_bundleId);
    }

    function setBundleMetadata(bytes32 _bundleId, BundleMetadata memory _bundleMetadata) public {
        TransientInterop.setBundleMetadata(_bundleId, _bundleMetadata);
    }

    function getBundleCall(bytes32 _bundleId, uint256 _index) public view returns (InteropCall memory) {
        return TransientInterop.getBundleCall(_bundleId, _index);
    }

    function addCallToBundle(bytes32 _bundleId, InteropCall memory _interopCall) public {
        TransientInterop.addCallToBundle(_bundleId, _interopCall);
    }
}
