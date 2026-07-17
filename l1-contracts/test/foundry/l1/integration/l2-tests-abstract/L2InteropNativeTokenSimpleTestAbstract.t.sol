// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

// NOTE: the previous `test_requestNativeTokenTransferViaLibrary_SameBaseToken` was removed. A same-base-token
// native transfer resolves to a direct call carrying `interopCallValue` — a native-`value` leg, which atomic
// interop no longer supports (value legs cannot be reversed on timeout). That the InteropCenter now rejects
// such a leg with `AtomicBundleCallCarriesValue` is covered by {L2InteropIndirectCallValueRegressionTestAbstract}.
abstract contract L2InteropNativeTokenSimpleTestAbstract is L2InteropTestUtils {
    function test_supportsAttributes() public view {
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(IERC7786Attributes.indirectCall.selector),
            true,
            "InteropCenter should support indirectCall attribute"
        );
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(
                IERC7786GatewaySource.supportsAttribute.selector
            ),
            false,
            "InteropCenter should not support supportsAttribute as an attribute"
        );
    }
}
